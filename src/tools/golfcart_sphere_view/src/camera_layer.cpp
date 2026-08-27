// Copyright 2026 NEWSLab, National Taiwan University
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "camera_layer.hpp"

#include "jpeg_decode.hpp"
#include "raw_image.hpp"

#include <OgreSceneNode.h>

#include <rviz_common/display_context.hpp>
#include <rviz_common/frame_manager_iface.hpp>
#include <rviz_common/properties/enum_property.hpp>
#include <rviz_common/properties/float_property.hpp>
#include <rviz_common/properties/int_property.hpp>
#include <rviz_common/properties/ros_topic_property.hpp>
#include <rviz_common/properties/tf_frame_property.hpp>
#include <rviz_common/ros_integration/ros_node_abstraction_iface.hpp>

#include <chrono>
#include <string>
#include <utility>
#include <vector>

namespace golfcart_sphere_view
{

CameraLayer::CameraLayer(
  const QString & name, const QString & image_topic, const QString & camera_info_topic,
  rviz_common::properties::Property * parent)
: rviz_common::properties::BoolProperty(name, true, "Draw this camera.", parent)
{
  connect(this, SIGNAL(changed()), this, SLOT(onEnableChanged()));

  image_topic_property_ = new rviz_common::properties::RosTopicProperty(
    "Image Topic", image_topic, "sensor_msgs/msg/CompressedImage",
    "Compressed image for this camera.", this, SLOT(onTopicsChanged()));

  // Compressed by default because that is what this vehicle publishes, but
  // public datasets frequently ship raw Image -- Autoware's own Leo Drive bags
  // among them -- and republishing them just to look at them is a poor trade.
  image_type_property_ = new rviz_common::properties::EnumProperty(
    "Image Type", "Compressed",
    "Message type on the image topic. Compressed is sensor_msgs/CompressedImage, "
    "Raw is sensor_msgs/Image.",
    this, SLOT(onTopicsChanged()));
  image_type_property_->addOption("Compressed", 0);
  image_type_property_->addOption("Raw", 1);

  camera_info_topic_property_ = new rviz_common::properties::RosTopicProperty(
    "Camera Info Topic", camera_info_topic, "sensor_msgs/msg/CameraInfo",
    "Intrinsics for the same camera. Without it there is no patch to draw on.", this,
    SLOT(onTopicsChanged()));

  // REP-103 says CameraInfo names the optical frame, and the default here is to
  // believe it. The override exists for publishers that do not, but reach for it
  // only after checking where the axes point: a frame called *_optical_link is
  // not necessarily the optical one, and Autoware's Leo Drive bags are a case
  // where it is not -- their camera_link is the optical frame and their
  // camera_optical_link is that rolled ninety degrees. Guessing from the name
  // there produces a tilted picture that looks like a calibration fault.
  //
  // The check is three lines of arithmetic: transform the optical axes into the
  // vehicle frame and confirm that image-down points down and that the view
  // direction points out of the side the camera is on.
  optical_frame_property_ = new rviz_common::properties::TfFrameProperty(
    "Optical Frame Override", "",
    "Frame to project in, for publishers whose CameraInfo names the wrong frame. "
    "Leave blank to use CameraInfo, which is correct far more often than not. Verify "
    "before setting this: a frame named *_optical_link is not always the optical one.",
    this, nullptr, true, SLOT(onTopicsChanged()));

  // Decoding is what this display costs, and it is the one cost that scales
  // with frame rate: a 1920x1280 JPEG takes about 10 ms on a workstation core
  // and two to three times that on an Orin, so three cameras at 30 Hz would
  // spend two to three cores decoding pictures nobody can read that fast. A
  // calibration check is something you look at; ten a second is already more
  // than the eye uses. Frames above the limit are dropped before they reach the
  // worker, so the saving is the whole decode and not just the upload.
  max_rate_property_ = new rviz_common::properties::FloatProperty(
    "Max Update Rate", 10.0f,
    "Frames per second to decode, at most. Raise it for a moving vehicle, lower it "
    "when the Orin is busy; zero means every frame.",
    this, SLOT(onAlphaChanged()));
  max_rate_property_->setMin(0.0f);

  // A sphere patch at a one degree grid does not resolve 1920 wide, and libjpeg
  // can skip the inverse DCT work for coefficients a smaller output never uses.
  // Half size is four times fewer pixels to decode, convert, upload and store,
  // for a picture still far sharper than the seam judgement it supports.
  decode_width_property_ = new rviz_common::properties::IntProperty(
    "Decode Width Limit", 960,
    "Decode JPEG no wider than this, using libjpeg's scaled decode. Zero decodes at "
    "full size. Raw images are unaffected.",
    this, SLOT(onAlphaChanged()));
  decode_width_property_->setMin(0);

  alpha_property_ = new rviz_common::properties::FloatProperty(
    "Alpha", 1.0f, "Transparency for this camera alone, for looking through an overlap.",
    this, SLOT(onAlphaChanged()));
  alpha_property_->setMin(0.0f);
  alpha_property_->setMax(1.0f);
}

CameraLayer::~CameraLayer()
{
  stopWorker();
  unsubscribe();
  patch_.reset();
}

std::string CameraLayer::opticalFrame(const sensor_msgs::msg::CameraInfo & camera_info) const
{
  const std::string override_frame = optical_frame_property_->getFrameStd();
  if (!override_frame.empty() && override_frame != rviz_common::properties::TfFrameProperty::
    FIXED_FRAME_STRING.toStdString())
  {
    return override_frame;
  }
  return camera_info.header.frame_id;
}

void CameraLayer::initialize(
  rviz_common::DisplayContext * context, Ogre::SceneNode * parent_scene_node)
{
  context_ = context;
  optical_frame_property_->setFrameManager(context_->getFrameManager());
  patch_ = std::make_unique<TexturedPatch>(
    context_->getSceneManager(), parent_scene_node, getName().toStdString());
  patch_->setAlpha(alpha_property_->getFloat());
}

void CameraLayer::startWorker()
{
  if (worker_running_.exchange(true)) {
    return;
  }
  worker_ = std::thread(&CameraLayer::workerLoop, this);
}

void CameraLayer::stopWorker()
{
  if (!worker_running_.exchange(false)) {
    return;
  }
  encoded_available_.notify_all();
  if (worker_.joinable()) {
    worker_.join();
  }
}

void CameraLayer::workerLoop()
{
  // JPEG decode is the expensive part of this display, and RViz renders on the
  // thread that would otherwise carry it. Three cameras at 30 Hz decoded inline
  // would show up as a stalled frame loop rather than as a slow camera, so each
  // camera decodes on its own thread and hands over only the result.
  while (worker_running_) {
    PendingFrame frame;
    {
      std::unique_lock<std::mutex> lock(encoded_mutex_);
      encoded_available_.wait(lock, [this] { return has_encoded_frame_ || !worker_running_; });
      if (!worker_running_) {
        return;
      }
      frame = std::move(encoded_frame_);
      has_encoded_frame_ = false;
    }

    QImage decoded;
    if (frame.compressed) {
      // libjpeg first, for the scaled decode. Anything it will not take -- a
      // CompressedImage may carry PNG -- falls back to Qt rather than being
      // refused, since drawing the frame is the point.
      std::string reason;
      decoded = decodeJpeg(frame.bytes, frame.decode_width_limit, reason);
      if (decoded.isNull() &&
        !decoded.loadFromData(frame.bytes.data(), static_cast<int>(frame.bytes.size())))
      {
        std::lock_guard<std::mutex> lock(decoded_mutex_);
        ++decode_failures_;
        decode_error_ = reason.empty() ? "undecodable compressed frame" : reason;
        continue;
      }
    } else {
      std::string reason;
      decoded = rawImageToQImage(
        frame.bytes, frame.width, frame.height, frame.step, frame.encoding, reason);
      if (decoded.isNull()) {
        std::lock_guard<std::mutex> lock(decoded_mutex_);
        ++decode_failures_;
        decode_error_ = reason;
        continue;
      }
    }
    // Converting here rather than in the upload keeps the render thread's share
    // of each frame down to the blit itself.
    if (decoded.format() != QImage::Format_RGB888) {
      decoded = decoded.convertToFormat(QImage::Format_RGB888);
    }

    std::lock_guard<std::mutex> lock(decoded_mutex_);
    decoded_frame_ = std::move(decoded);
    has_decoded_frame_ = true;
  }
}

bool CameraLayer::acceptFrameNow()
{
  const float rate = max_rate_property_->getFloat();
  if (rate <= 0.0f) {
    return true;
  }
  const auto now = std::chrono::steady_clock::now();
  const auto interval = std::chrono::duration<double>(1.0 / static_cast<double>(rate));
  if (last_accepted_.time_since_epoch().count() != 0 && now - last_accepted_ < interval) {
    ++dropped_by_rate_;
    return false;
  }
  last_accepted_ = now;
  return true;
}

void CameraLayer::subscribe()
{
  if (!context_ || !getBool()) {
    return;
  }
  auto node = context_->getRosNodeAbstraction().lock();
  if (!node) {
    return;
  }
  auto raw_node = node->get_raw_node();

  // An empty topic is not a mistake, it is a layer nobody has pointed anywhere
  // yet -- which is exactly the state a layer is in while a saved config is
  // still being applied to it. Subscribing anyway throws "topic name must not
  // be empty string" out of rclcpp, and RViz abandons the whole config load.
  const std::string image_topic = image_topic_property_->getTopicStd();
  const std::string camera_info_topic = camera_info_topic_property_->getTopicStd();
  if (image_topic.empty() || camera_info_topic.empty()) {
    return;
  }

  startWorker();

  // Sensor QoS on all of them: a reliable subscription matches nothing against
  // a best-effort sensor stream, and says nothing about it while it does so.
  if (image_type_property_->getOptionInt() == 0) {
    compressed_subscription_ = raw_node->create_subscription<sensor_msgs::msg::CompressedImage>(
      image_topic, rclcpp::SensorDataQoS(),
      [this](sensor_msgs::msg::CompressedImage::ConstSharedPtr message) {
        if (!acceptFrameNow()) {
          return;
        }
        {
          std::lock_guard<std::mutex> lock(encoded_mutex_);
          encoded_frame_.bytes = message->data;
          encoded_frame_.compressed = true;
          encoded_frame_.decode_width_limit = decode_width_property_->getInt();
          has_encoded_frame_ = true;
        }
        encoded_available_.notify_one();
      });
  } else {
    raw_subscription_ = raw_node->create_subscription<sensor_msgs::msg::Image>(
      image_topic, rclcpp::SensorDataQoS(),
      [this](sensor_msgs::msg::Image::ConstSharedPtr message) {
        if (!acceptFrameNow()) {
          return;
        }
        {
          std::lock_guard<std::mutex> lock(encoded_mutex_);
          encoded_frame_.bytes = message->data;
          encoded_frame_.width = message->width;
          encoded_frame_.height = message->height;
          encoded_frame_.step = message->step;
          encoded_frame_.encoding = message->encoding;
          encoded_frame_.compressed = false;
          has_encoded_frame_ = true;
        }
        encoded_available_.notify_one();
      });
  }

  camera_info_subscription_ = raw_node->create_subscription<sensor_msgs::msg::CameraInfo>(
    camera_info_topic, rclcpp::SensorDataQoS(),
    [this](sensor_msgs::msg::CameraInfo::ConstSharedPtr message) {
      std::lock_guard<std::mutex> lock(camera_info_mutex_);
      const bool changed = !has_camera_info_ || camera_info_.k != message->k ||
      camera_info_.d != message->d || camera_info_.width != message->width ||
      camera_info_.height != message->height ||
      camera_info_.header.frame_id != message->header.frame_id;
      camera_info_ = *message;
      has_camera_info_ = true;
      if (changed) {
        geometry_dirty_ = true;
      }
    });
}

void CameraLayer::unsubscribe()
{
  compressed_subscription_.reset();
  raw_subscription_.reset();
  camera_info_subscription_.reset();
  stopWorker();
  {
    std::lock_guard<std::mutex> lock(decoded_mutex_);
    decoded_frame_ = QImage();
    has_decoded_frame_ = false;
  }
  {
    std::lock_guard<std::mutex> lock(encoded_mutex_);
    encoded_frame_ = PendingFrame{};
    has_encoded_frame_ = false;
  }
}

void CameraLayer::onTopicsChanged()
{
  unsubscribe();
  {
    std::lock_guard<std::mutex> lock(camera_info_mutex_);
    has_camera_info_ = false;
  }
  geometry_dirty_ = true;
  subscribe();
}

void CameraLayer::onAlphaChanged()
{
  if (patch_) {
    patch_->setAlpha(alpha_property_->getFloat());
  }
}

void CameraLayer::onEnableChanged()
{
  if (!patch_) {
    return;
  }
  const bool enabled = getBool();
  patch_->setVisible(enabled);
  if (enabled) {
    subscribe();
  } else {
    unsubscribe();
  }
}

void CameraLayer::updateGeometry(
  const std::string & centre_frame, double radius, const SphereResolution & resolution, bool force)
{
  if (!patch_ || !getBool()) {
    return;
  }
  if (!geometry_dirty_ && !force) {
    return;
  }

  sensor_msgs::msg::CameraInfo camera_info;
  {
    std::lock_guard<std::mutex> lock(camera_info_mutex_);
    if (!has_camera_info_) {
      return;
    }
    camera_info = camera_info_;
  }

  const std::string camera_frame = opticalFrame(camera_info);
  if (camera_frame.empty()) {
    transform_error_ = "CameraInfo carries no frame_id";
    return;
  }

  // FrameManager reports poses relative to the fixed frame, so the transform
  // wanted here is composed from two of them. Both are asked for at time zero:
  // these are static mounts, and asking at the image stamp fails during the
  // window before tf_static arrives.
  Ogre::Vector3 centre_position;
  Ogre::Quaternion centre_orientation;
  Ogre::Vector3 camera_position;
  Ogre::Quaternion camera_orientation;
  auto * frame_manager = context_->getFrameManager();
  const rclcpp::Time latest(0, 0, RCL_ROS_TIME);
  if (!frame_manager->getTransform(centre_frame, latest, centre_position, centre_orientation) ||
    !frame_manager->getTransform(camera_frame, latest, camera_position, camera_orientation))
  {
    transform_error_ = "no transform " + centre_frame + " -> " + camera_frame;
    has_geometry_ = false;
    patch_->setGeometry({});
    return;
  }
  transform_error_.clear();

  const Ogre::Quaternion centre_inverse = centre_orientation.Inverse();
  CameraPose pose;
  pose.position = centre_inverse * (camera_position - centre_position);
  pose.orientation = centre_inverse * camera_orientation;

  const auto triangles = buildCameraPatch(camera_info, pose, radius, resolution);
  patch_->setGeometry(triangles);
  triangle_count_ = triangles.size() / 3;
  has_geometry_ = !triangles.empty();
  geometry_dirty_ = false;
}

void CameraLayer::updateTexture()
{
  if (!patch_ || !getBool() || !has_geometry_) {
    return;
  }
  QImage frame;
  {
    std::lock_guard<std::mutex> lock(decoded_mutex_);
    if (!has_decoded_frame_) {
      return;
    }
    frame = decoded_frame_;
    has_decoded_frame_ = false;
  }
  patch_->updateImage(frame);
}

bool CameraLayer::isRendering() const { return getBool() && has_geometry_; }

QString CameraLayer::statusSummary() const
{
  if (!getBool()) {
    return getName() + ": off";
  }
  if (!transform_error_.empty()) {
    return getName() + ": " + QString::fromStdString(transform_error_);
  }
  if (!has_geometry_) {
    return getName() + ": waiting for CameraInfo";
  }
  QString summary = getName() + ": " + QString::number(triangle_count_) + " triangles";
  if (decode_failures_ > 0) {
    summary += ", " + QString::number(decode_failures_) + " dropped (" +
      QString::fromStdString(decode_error_) + ")";
  }
  return summary;
}

}  // namespace golfcart_sphere_view
