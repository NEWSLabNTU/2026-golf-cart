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

#include <sensor_msgs/msg/camera_info.hpp>
#include <sensor_msgs/msg/compressed_image.hpp>

#include <QImage>
#include <memory>
#include <mutex>
#include <string>

#include "sphere_mesh.hpp"
#include "textured_patch.hpp"

namespace rviz_common
{
namespace properties
{
class FloatProperty;
class RosTopicProperty;
class StringProperty;
class TfFrameProperty;
}  // namespace properties
}  // namespace rviz_common

namespace golfcart_sphere_view
{

/// Paints one camera onto a sphere centred on the vehicle.
///
/// S1 of the phase, so one camera and no point clouds. The split that matters
/// is already in place: patch geometry is rebuilt only when the CameraInfo or
/// the transform changes, and each frame does nothing but upload a texture.
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
  void updateTopics();
  void updateGeometryProperties();
  void updateAlpha();

private:
  void subscribe();
  void unsubscribe();
  void rebuildGeometry();
  bool lookUpCameraPose(CameraPose & pose);

  std::unique_ptr<TexturedPatch> patch_;

  rclcpp::Subscription<sensor_msgs::msg::CompressedImage>::SharedPtr image_subscription_;
  rclcpp::Subscription<sensor_msgs::msg::CameraInfo>::SharedPtr camera_info_subscription_;

  std::mutex frame_mutex_;
  QImage pending_frame_;
  bool has_pending_frame_{false};

  sensor_msgs::msg::CameraInfo camera_info_;
  bool has_camera_info_{false};
  bool geometry_dirty_{false};

  rviz_common::properties::RosTopicProperty * image_topic_property_;
  rviz_common::properties::RosTopicProperty * camera_info_topic_property_;
  rviz_common::properties::TfFrameProperty * centre_frame_property_;
  rviz_common::properties::FloatProperty * radius_property_;
  rviz_common::properties::FloatProperty * alpha_property_;
  rviz_common::properties::FloatProperty * resolution_property_;
};

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__SPHERE_VIEW_DISPLAY_HPP_
