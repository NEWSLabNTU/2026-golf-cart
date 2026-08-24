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
#include <rviz_common/properties/bool_property.hpp>
#include <rviz_common/properties/float_property.hpp>
#include <rviz_common/properties/tf_frame_property.hpp>

#include <QStringList>
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
}

SphereViewDisplay::~SphereViewDisplay() = default;

void SphereViewDisplay::onInitialize()
{
  Display::onInitialize();
  centre_frame_property_->setFrameManager(context_->getFrameManager());

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
}

CameraLayer * SphereViewDisplay::appendCamera(
  const QString & name, const QString & image_topic, const QString & camera_info_topic)
{
  auto * layer = new CameraLayer(name, image_topic, camera_info_topic, this);
  layer->initialize(context_, scene_node_);
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

void SphereViewDisplay::onEnable()
{
  scene_node_->setVisible(true);
  for (auto * camera : cameras_) {
    camera->subscribe();
  }
  geometry_dirty_ = true;
}

void SphereViewDisplay::onDisable()
{
  for (auto * camera : cameras_) {
    camera->unsubscribe();
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
  QStringList lines;
  int rendering = 0;
  for (auto * camera : cameras_) {
    lines << camera->statusSummary();
    if (camera->isRendering()) {
      ++rendering;
    }
  }
  setStatus(
    rendering > 0 ? rviz_common::properties::StatusProperty::Ok
    : rviz_common::properties::StatusProperty::Warn,
    "Cameras", lines.join("; "));
}

void SphereViewDisplay::update(float /*wall_dt*/, float /*ros_dt*/)
{
  const bool rebuild = geometry_dirty_;
  if (rebuild) {
    if (!updateCentreTransform()) {
      return;
    }
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

  for (auto * camera : cameras_) {
    camera->updateTexture();
  }
}

}  // namespace golfcart_sphere_view

#include <pluginlib/class_list_macros.hpp>
PLUGINLIB_EXPORT_CLASS(golfcart_sphere_view::SphereViewDisplay, rviz_common::Display)
