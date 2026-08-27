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

#include <rviz_common/config.hpp>
#include <rviz_common/display_context.hpp>
#include <rviz_common/frame_manager_iface.hpp>
#include <rviz_common/properties/bool_property.hpp>
#include <rviz_common/properties/float_property.hpp>
#include <rviz_common/properties/string_property.hpp>
#include <rviz_common/properties/tf_frame_property.hpp>

#include <QStringList>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace golfcart_sphere_view
{

SphereViewDisplay::SphereViewDisplay()
{
  centre_frame_property_ = new rviz_common::properties::TfFrameProperty(
    "Centre Frame", "base_link",
    "Frame the sphere is centred on. base_link is the vehicle's own view of the world.",
    this, nullptr, false, SLOT(updateGeometryProperties()));

  radius_property_ = new rviz_common::properties::FloatProperty(
    "Radius", 10.0f,
    "Distance at which image rays are painted. Features at this range land in the right "
    "place; nearer and farther ones do not, which is what opens a seam between two "
    "cameras. Sweeping it is a crude depth read-out.",
    this, SLOT(updateGeometryProperties()));
  radius_property_->setMin(0.1f);

  resolution_property_ = new rviz_common::properties::FloatProperty(
    "Grid Step", 1.0f,
    "Sphere tessellation in degrees. Smaller is smoother and slower to rebuild; it does "
    "not affect the per-frame cost.",
    this, SLOT(updateGeometryProperties()));
  resolution_property_->setMin(0.1f);
  resolution_property_->setMax(10.0f);

  add_camera_property_ = new rviz_common::properties::BoolProperty(
    "Add Camera", false, "Tick to append another camera layer.", this, SLOT(addCamera()));
  remove_camera_property_ = new rviz_common::properties::BoolProperty(
    "Remove Last Camera", false, "Tick to drop the last camera layer.", this,
    SLOT(removeLastCamera()));
  // A row rather than a status child, because the question it answers is asked
  // while watching the thing, and a status child has to be expanded first.
  timing_property_ = new rviz_common::properties::StringProperty(
    "Frame Cost", "measuring",
    "Milliseconds per rendered frame in each stage, averaged. Geometry should be zero "
    "once the calibration settles; textures and clouds are the ongoing cost.",
    this);
  timing_property_->setReadOnly(true);

  add_cloud_property_ = new rviz_common::properties::BoolProperty(
    "Add LiDAR", false, "Tick to append another point cloud layer.", this, SLOT(addCloud()));
  remove_cloud_property_ = new rviz_common::properties::BoolProperty(
    "Remove Last LiDAR", false, "Tick to drop the last point cloud layer.", this,
    SLOT(removeLastCloud()));
}

SphereViewDisplay::~SphereViewDisplay() = default;

void SphereViewDisplay::onInitialize()
{
  Display::onInitialize();
  centre_frame_property_->setFrameManager(context_->getFrameManager());
  context_ready_ = true;

  // load() runs before this, so a saved config has already created its layers
  // and they are waiting for a scene node. Give them one, and only fall back to
  // the vehicle's own sensors when nothing was loaded.
  for (auto * camera : cameras_) {
    camera->initialize(context_, scene_node_);
  }
  for (auto * cloud : clouds_) {
    cloud->initialize(context_, scene_node_);
  }
  if (!cameras_.isEmpty() || !clouds_.isEmpty()) {
    return;
  }

  // The vehicle's three GMSL cameras. Defaults rather than hardcoding: every
  // topic is editable, and layers can be added or removed, so the same display
  // serves the ZED on the orin or a bag with different names.
  appendCamera(
    "camera_left", "/sensing/camera/left/image_raw/compressed",
    "/sensing/camera/left/camera_info");
  appendCamera(
    "camera_right", "/sensing/camera/right/image_raw/compressed",
    "/sensing/camera/right/camera_info");
  appendCamera(
    "camera_rear", "/sensing/camera/rear/image_raw/compressed",
    "/sensing/camera/rear/camera_info");

  // The vehicle's two LiDARs, with distinct flat colours so their overlap is
  // legible when Colour By is set to Flat.
  appendCloud("vlp32c", "/sensing/lidar/vlp32/velodyne_points", QColor(255, 255, 255));
  appendCloud("falcon", "/sensing/lidar/falcon/iv_points", QColor(255, 160, 60));
}

CloudLayer * SphereViewDisplay::appendCloud(
  const QString & name, const QString & topic, const QColor & colour)
{
  auto * layer = new CloudLayer(name, topic, colour, this);
  if (context_ready_) {
    layer->initialize(context_, scene_node_);
  }
  clouds_.append(layer);
  if (isEnabled()) {
    layer->subscribe();
  }
  return layer;
}

void SphereViewDisplay::addCloud()
{
  if (!add_cloud_property_->getBool()) {
    return;
  }
  add_cloud_property_->setBool(false);
  appendCloud(QString("lidar_%1").arg(++unnamed_cloud_count_), "", QColor(200, 200, 200));
}

void SphereViewDisplay::removeLastCloud()
{
  if (!remove_cloud_property_->getBool()) {
    return;
  }
  remove_cloud_property_->setBool(false);
  if (clouds_.isEmpty()) {
    return;
  }
  delete clouds_.takeLast();
}

CameraLayer * SphereViewDisplay::appendCamera(
  const QString & name, const QString & image_topic, const QString & camera_info_topic)
{
  auto * layer = new CameraLayer(name, image_topic, camera_info_topic, this);
  if (context_ready_) {
    layer->initialize(context_, scene_node_);
  }
  cameras_.append(layer);
  if (isEnabled()) {
    layer->subscribe();
  }
  geometry_dirty_ = true;
  return layer;
}

void SphereViewDisplay::addCamera()
{
  if (!add_camera_property_->getBool()) {
    return;
  }
  add_camera_property_->setBool(false);
  appendCamera(
    QString("camera_%1").arg(++unnamed_camera_count_), "", "");
}

void SphereViewDisplay::removeLastCamera()
{
  if (!remove_camera_property_->getBool()) {
    return;
  }
  remove_camera_property_->setBool(false);
  if (cameras_.isEmpty()) {
    return;
  }
  auto * layer = cameras_.takeLast();
  // Deleting the property detaches it from the tree and takes its Ogre objects
  // with it through the destructor.
  delete layer;
}

void SphereViewDisplay::load(const rviz_common::Config & config)
{
  // A camera entry carries an image topic; a LiDAR entry carries a placement.
  // Matching on the fields rather than on a saved type string keeps
  // hand-written configs working, which is how these are actually produced.
  for (auto iter = config.mapIterator(); iter.isValid(); iter.advance()) {
    const QString name = iter.currentKey();
    const rviz_common::Config child = config.mapGetChild(name);
    if (!child.isValid() || child.getType() != rviz_common::Config::Map) {
      continue;
    }

    const bool is_camera = child.mapGetChild("Image Topic").isValid();
    const bool is_cloud = child.mapGetChild("Placement").isValid();
    if (!is_camera && !is_cloud) {
      continue;
    }

    bool exists = false;
    for (int i = 0; i < numChildren(); ++i) {
      if (childAt(i)->getName() == name) {
        exists = true;
        break;
      }
    }
    if (exists) {
      continue;
    }

    if (is_camera) {
      appendCamera(name, "", "");
    } else {
      appendCloud(name, "", QColor(200, 200, 200));
    }
  }

  Display::load(config);
}

void SphereViewDisplay::fixedFrameChanged()
{
  // The patches themselves do not change -- they are expressed in the centre
  // frame, and the relationship between a camera and the frame it is bolted to
  // is not affected by which frame RViz happens to be drawing in. Only where
  // the sphere sits changes, and update() handles that.
  updateCentreTransform();
}

void SphereViewDisplay::onEnable()
{
  scene_node_->setVisible(true);
  for (auto * camera : cameras_) {
    camera->subscribe();
  }
  for (auto * cloud : clouds_) {
    cloud->subscribe();
  }
  geometry_dirty_ = true;
}

void SphereViewDisplay::onDisable()
{
  for (auto * camera : cameras_) {
    camera->unsubscribe();
  }
  for (auto * cloud : clouds_) {
    cloud->unsubscribe();
  }
  scene_node_->setVisible(false);
}

void SphereViewDisplay::reset()
{
  Display::reset();
  for (auto * camera : cameras_) {
    camera->unsubscribe();
    if (isEnabled()) {
      camera->subscribe();
    }
  }
  for (auto * cloud : clouds_) {
    cloud->unsubscribe();
    if (isEnabled()) {
      cloud->subscribe();
    }
  }
  geometry_dirty_ = true;
}

void SphereViewDisplay::updateGeometryProperties() { geometry_dirty_ = true; }

bool SphereViewDisplay::updateCentreTransform()
{
  const std::string centre_frame = centre_frame_property_->getFrameStd();
  Ogre::Vector3 position;
  Ogre::Quaternion orientation;
  if (!context_->getFrameManager()->getTransform(
      centre_frame, rclcpp::Time(0, 0, RCL_ROS_TIME), position, orientation))
  {
    setStatusStd(
      rviz_common::properties::StatusProperty::Warn, "Transform",
      "No transform to " + centre_frame);
    return false;
  }
  // Everything a camera layer builds is expressed in the centre frame, so the
  // whole sphere moves by placing this one node.
  scene_node_->setPosition(position);
  scene_node_->setOrientation(orientation);
  setStatus(rviz_common::properties::StatusProperty::Ok, "Transform", "OK");
  return true;
}

void SphereViewDisplay::refreshStatus()
{
  QStringList camera_lines;
  int rendering = 0;
  for (auto * camera : cameras_) {
    camera_lines << camera->statusSummary();
    if (camera->isRendering()) {
      ++rendering;
    }
  }
  setStatus(
    rendering > 0 ? rviz_common::properties::StatusProperty::Ok
    : rviz_common::properties::StatusProperty::Warn,
    "Cameras", camera_lines.join("; "));

  QStringList cloud_lines;
  for (auto * cloud : clouds_) {
    cloud_lines << cloud->statusSummary();
  }
  if (!cloud_lines.isEmpty()) {
    setStatus(
      rviz_common::properties::StatusProperty::Ok, "LiDARs", cloud_lines.join("; "));
  }
}

void SphereViewDisplay::update(float /*wall_dt*/, float /*ros_dt*/)
{
  // Every frame, not only when something was rebuilt. The sphere is built once
  // in the centre frame's own coordinates and then placed by this one node, so
  // following the centre frame is entirely a matter of keeping the node's pose
  // current: whenever the vehicle moves under a fixed frame of map or odom, and
  // whenever the user picks a different fixed frame in Global Options. Doing it
  // only on rebuild left the sphere behind at a stale pose.
  if (!updateCentreTransform()) {
    return;
  }

  using Clock = std::chrono::steady_clock;
  const auto elapsed_ms = [](Clock::time_point from) {
      return std::chrono::duration<double, std::milli>(Clock::now() - from).count();
    };

  const auto geometry_started = Clock::now();
  const bool rebuild = geometry_dirty_;
  if (rebuild) {
    SphereResolution resolution;
    resolution.latitude_step_deg = resolution_property_->getFloat();
    resolution.longitude_step_deg = resolution_property_->getFloat();
    const std::string centre_frame = centre_frame_property_->getFrameStd();
    for (auto * camera : cameras_) {
      camera->updateGeometry(centre_frame, radius_property_->getFloat(), resolution, true);
    }
    geometry_dirty_ = false;
    refreshStatus();
  } else {
    // A camera whose CameraInfo arrived late marks itself dirty; this picks it
    // up without rebuilding the layers that are already correct.
    SphereResolution resolution;
    resolution.latitude_step_deg = resolution_property_->getFloat();
    resolution.longitude_step_deg = resolution_property_->getFloat();
    const std::string centre_frame = centre_frame_property_->getFrameStd();
    for (auto * camera : cameras_) {
      camera->updateGeometry(centre_frame, radius_property_->getFloat(), resolution, false);
    }
  }

  timing_.blend(timing_.geometry_ms, elapsed_ms(geometry_started));

  const auto textures_started = Clock::now();
  for (auto * camera : cameras_) {
    camera->updateTexture();
  }
  timing_.blend(timing_.textures_ms, elapsed_ms(textures_started));

  // Clouds are re-placed when a new one arrives, and also when the sphere
  // itself changed -- in Angular mode the radius is where the points go.
  const auto clouds_started = Clock::now();
  const std::string centre_frame = centre_frame_property_->getFrameStd();
  for (auto * cloud : clouds_) {
    cloud->update(centre_frame, radius_property_->getFloat(), rebuild);
  }
  timing_.blend(timing_.clouds_ms, elapsed_ms(clouds_started));

  // Compact because the property column is narrow. geom/tex/cloud, milliseconds.
  timing_property_->setStdString(
    (QString("%1 / %2 / %3 ms")
    .arg(timing_.geometry_ms, 0, 'f', 2)
    .arg(timing_.textures_ms, 0, 'f', 2)
    .arg(timing_.clouds_ms, 0, 'f', 2)).toStdString());

  // The same numbers on stderr for a headless measurement, which is how they
  // will be taken on the vehicle: ssh in, set the variable, read the log.
  static const bool log_timing = std::getenv("GOLFCART_SPHERE_VIEW_TIMING") != nullptr;
  if (log_timing) {
    const auto now = Clock::now();
    if (now - last_timing_log_ > std::chrono::seconds(2)) {
      last_timing_log_ = now;
      std::fprintf(
        stderr, "[sphere_view] geometry %.2f ms, textures %.2f ms, clouds %.2f ms\n",
        timing_.geometry_ms, timing_.textures_ms, timing_.clouds_ms);
    }
  }

  if (rebuild) {
    refreshStatus();
  }
}

}  // namespace golfcart_sphere_view

#include <pluginlib/class_list_macros.hpp>
PLUGINLIB_EXPORT_CLASS(golfcart_sphere_view::SphereViewDisplay, rviz_common::Display)
