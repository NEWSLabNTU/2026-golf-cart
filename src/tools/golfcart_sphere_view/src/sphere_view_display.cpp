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

#include "sphere_view_display.hpp"

#include <OgreSceneManager.h>
#include <OgreSceneNode.h>

#include <rviz_common/display_context.hpp>
#include <rviz_common/frame_manager_iface.hpp>
#include <rviz_common/properties/float_property.hpp>
#include <rviz_common/properties/ros_topic_property.hpp>
#include <rviz_common/properties/tf_frame_property.hpp>
#include <rviz_common/ros_integration/ros_node_abstraction_iface.hpp>

#include <QString>
#include <memory>
#include <string>
#include <vector>

namespace golfcart_sphere_view
{

SphereViewDisplay::SphereViewDisplay()
{
  image_topic_property_ = new rviz_common::properties::RosTopicProperty(
    "Image Topic", "/sensing/camera/left/image_raw/compressed",
    "sensor_msgs/msg/CompressedImage", "Compressed image to paint onto the sphere.", this,
    SLOT(updateTopics()));

  camera_info_topic_property_ = new rviz_common::properties::RosTopicProperty(
    "Camera Info Topic", "/sensing/camera/left/camera_info", "sensor_msgs/msg/CameraInfo",
    "Intrinsics for the same camera. The patch cannot be built without it.", this,
    SLOT(updateTopics()));

  centre_frame_property_ = new rviz_common::properties::TfFrameProperty(
    "Centre Frame", "base_link",
    "Frame the sphere is centred on. base_link is the vehicle's own view of the world.",
    this, nullptr, false, SLOT(updateGeometryProperties()));

  radius_property_ = new rviz_common::properties::FloatProperty(
    "Radius", 10.0f,
    "Distance at which image rays are painted. Features at this range land in the right "
    "place; nearer and farther ones do not, which is what opens a seam between cameras.",
    this, SLOT(updateGeometryProperties()));
  radius_property_->setMin(0.1f);

  resolution_property_ = new rviz_common::properties::FloatProperty(
    "Grid Step", 1.0f,
    "Sphere tessellation in degrees. Smaller is smoother and slower to rebuild; it does "
    "not affect the per-frame cost.",
    this, SLOT(updateGeometryProperties()));
  resolution_property_->setMin(0.1f);
  resolution_property_->setMax(10.0f);

  alpha_property_ = new rviz_common::properties::FloatProperty(
    "Alpha", 1.0f, "Patch transparency.", this, SLOT(updateAlpha()));
  alpha_property_->setMin(0.0f);
  alpha_property_->setMax(1.0f);
}

SphereViewDisplay::~SphereViewDisplay()
{
  unsubscribe();
  patch_.reset();
}

void SphereViewDisplay::onInitialize()
{
  Display::onInitialize();
  centre_frame_property_->setFrameManager(context_->getFrameManager());
  patch_ = std::make_unique<TexturedPatch>(
    context_->getSceneManager(), scene_node_, "SphereView/" + std::to_string(
      reinterpret_cast<std::uintptr_t>(this)));
  patch_->setAlpha(alpha_property_->getFloat());
}

void SphereViewDisplay::onEnable()
{
  scene_node_->setVisible(true);
  subscribe();
}

void SphereViewDisplay::onDisable()
{
  unsubscribe();
  scene_node_->setVisible(false);
}

void SphereViewDisplay::reset()
{
  Display::reset();
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    pending_frame_ = QImage();
    has_pending_frame_ = false;
  }
  has_camera_info_ = false;
  geometry_dirty_ = true;
}

void SphereViewDisplay::subscribe()
{
  if (!isEnabled()) {
    return;
  }
  auto node = context_->getRosNodeAbstraction().lock();
  if (!node) {
    setStatus(rviz_common::properties::StatusProperty::Error, "Topic", "No ROS node");
    return;
  }
  auto raw_node = node->get_raw_node();

  // Sensor QoS on both: these are best-effort sensor streams, and a reliable
  // subscription silently matches nothing against them.
  image_subscription_ = raw_node->create_subscription<sensor_msgs::msg::CompressedImage>(
    image_topic_property_->getTopicStd(), rclcpp::SensorDataQoS(),
    [this](sensor_msgs::msg::CompressedImage::ConstSharedPtr message) {
      QImage decoded;
      // Decoding here rather than in update() keeps it off the render thread.
      // S2 moves it to a worker per camera; with one camera the executor
      // thread carries it.
      if (!decoded.loadFromData(message->data.data(), static_cast<int>(message->data.size()))) {
        setStatusStd(
          rviz_common::properties::StatusProperty::Warn, "Image",
          "Could not decode frame, format is '" + message->format + "'");
        return;
      }
      setStatus(rviz_common::properties::StatusProperty::Ok, "Image", "OK");
      std::lock_guard<std::mutex> lock(frame_mutex_);
      // Newest wins. This is a monitor: a dropped frame costs nothing, a
      // growing queue costs everything.
      pending_frame_ = decoded;
      has_pending_frame_ = true;
    });

  camera_info_subscription_ = raw_node->create_subscription<sensor_msgs::msg::CameraInfo>(
    camera_info_topic_property_->getTopicStd(), rclcpp::SensorDataQoS(),
    [this](sensor_msgs::msg::CameraInfo::ConstSharedPtr message) {
      const bool changed = !has_camera_info_ ||
      camera_info_.k != message->k || camera_info_.d != message->d ||
      camera_info_.width != message->width || camera_info_.height != message->height ||
      camera_info_.header.frame_id != message->header.frame_id;
      camera_info_ = *message;
      has_camera_info_ = true;
      if (changed) {
        geometry_dirty_ = true;
      }
    });
}

void SphereViewDisplay::unsubscribe()
{
  image_subscription_.reset();
  camera_info_subscription_.reset();
}

void SphereViewDisplay::updateTopics()
{
  unsubscribe();
  reset();
  subscribe();
}

void SphereViewDisplay::updateGeometryProperties() { geometry_dirty_ = true; }

void SphereViewDisplay::updateAlpha()
{
  if (patch_) {
    patch_->setAlpha(alpha_property_->getFloat());
  }
}

bool SphereViewDisplay::lookUpCameraPose(CameraPose & pose)
{
  const std::string centre_frame = centre_frame_property_->getFrameStd();
  const std::string camera_frame = camera_info_.header.frame_id;
  if (camera_frame.empty()) {
    setStatus(
      rviz_common::properties::StatusProperty::Warn, "Transform",
      "CameraInfo carries no frame_id");
    return false;
  }

  // FrameManager reports poses relative to the fixed frame, so the transform
  // this display needs is composed from two of them. Both are looked up at time
  // zero: these are static mounts, and asking at the image stamp would fail
  // during the gap before tf_static arrives.
  Ogre::Vector3 centre_position;
  Ogre::Quaternion centre_orientation;
  Ogre::Vector3 camera_position;
  Ogre::Quaternion camera_orientation;
  auto * frame_manager = context_->getFrameManager();
  if (!frame_manager->getTransform(centre_frame, rclcpp::Time(0, 0, RCL_ROS_TIME),
    centre_position, centre_orientation) ||
    !frame_manager->getTransform(camera_frame, rclcpp::Time(0, 0, RCL_ROS_TIME),
    camera_position, camera_orientation))
  {
    setStatusStd(
      rviz_common::properties::StatusProperty::Warn, "Transform",
      "No transform between " + centre_frame + " and " + camera_frame);
    return false;
  }

  const Ogre::Quaternion centre_inverse = centre_orientation.Inverse();
  pose.position = centre_inverse * (camera_position - centre_position);
  pose.orientation = centre_inverse * camera_orientation;

  // The sphere itself is drawn where the centre frame is.
  scene_node_->setPosition(centre_position);
  scene_node_->setOrientation(centre_orientation);

  setStatus(rviz_common::properties::StatusProperty::Ok, "Transform", "OK");
  return true;
}

void SphereViewDisplay::rebuildGeometry()
{
  if (!has_camera_info_) {
    setStatus(
      rviz_common::properties::StatusProperty::Warn, "Camera Info",
      "Waiting for CameraInfo");
    return;
  }
  setStatus(rviz_common::properties::StatusProperty::Ok, "Camera Info", "OK");

  CameraPose pose;
  if (!lookUpCameraPose(pose)) {
    return;
  }

  SphereResolution resolution;
  resolution.latitude_step_deg = resolution_property_->getFloat();
  resolution.longitude_step_deg = resolution_property_->getFloat();

  const auto triangles = buildCameraPatch(
    camera_info_, pose, radius_property_->getFloat(), resolution);
  patch_->setGeometry(triangles);
  geometry_dirty_ = false;

  if (triangles.empty()) {
    setStatus(
      rviz_common::properties::StatusProperty::Warn, "Geometry",
      "No part of the sphere projects into this image. Check the camera's frame and "
      "its intrinsics.");
  } else {
    setStatusStd(
      rviz_common::properties::StatusProperty::Ok, "Geometry",
      std::to_string(triangles.size() / 3) + " triangles");
  }
}

void SphereViewDisplay::update(float /*wall_dt*/, float /*ros_dt*/)
{
  if (geometry_dirty_) {
    rebuildGeometry();
  }

  QImage frame;
  {
    std::lock_guard<std::mutex> lock(frame_mutex_);
    if (!has_pending_frame_) {
      return;
    }
    frame = pending_frame_;
    has_pending_frame_ = false;
  }
  if (patch_ && patch_->hasGeometry()) {
    patch_->updateImage(frame);
  }
}

}  // namespace golfcart_sphere_view

#include <pluginlib/class_list_macros.hpp>
PLUGINLIB_EXPORT_CLASS(golfcart_sphere_view::SphereViewDisplay, rviz_common::Display)
