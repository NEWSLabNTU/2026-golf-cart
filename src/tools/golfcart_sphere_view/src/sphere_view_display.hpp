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

#ifndef GOLFCART_SPHERE_VIEW__SPHERE_VIEW_DISPLAY_HPP_
#define GOLFCART_SPHERE_VIEW__SPHERE_VIEW_DISPLAY_HPP_

#include <rclcpp/rclcpp.hpp>
#include <rviz_common/display.hpp>

#include <QList>
#include <memory>
#include <string>

#include "camera_layer.hpp"
#include "sphere_mesh.hpp"

namespace rviz_common
{
namespace properties
{
class BoolProperty;
class FloatProperty;
class IntProperty;
class TfFrameProperty;
}  // namespace properties
}  // namespace rviz_common

namespace golfcart_sphere_view
{

/// Paints several cameras onto one sphere centred on the vehicle.
///
/// Each camera is a child property with its own topics, alpha and enable, so a
/// seam can be attributed by switching one side off. Patch geometry is rebuilt
/// only when the calibration, the transform or a sphere property changes; a
/// frame costs one texture upload per camera.
class SphereViewDisplay : public rviz_common::Display
{
  Q_OBJECT

public:
  SphereViewDisplay();
  ~SphereViewDisplay() override;

  void onInitialize() override;
  void reset() override;
  void update(float wall_dt, float ros_dt) override;

protected:
  void onEnable() override;
  void onDisable() override;

private Q_SLOTS:
  void updateGeometryProperties();
  void addCamera();
  void removeLastCamera();

private:
  CameraLayer * appendCamera(
    const QString & name, const QString & image_topic, const QString & camera_info_topic);
  void refreshStatus();
  bool updateCentreTransform();

  QList<CameraLayer *> cameras_;
  bool geometry_dirty_{true};
  int unnamed_camera_count_{0};

  rviz_common::properties::TfFrameProperty * centre_frame_property_;
  rviz_common::properties::FloatProperty * radius_property_;
  rviz_common::properties::FloatProperty * resolution_property_;
  rviz_common::properties::BoolProperty * add_camera_property_;
  rviz_common::properties::BoolProperty * remove_camera_property_;
};

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__SPHERE_VIEW_DISPLAY_HPP_
