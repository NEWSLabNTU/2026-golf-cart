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

#ifndef GOLFCART_SPHERE_VIEW__CLOUD_LAYER_HPP_
#define GOLFCART_SPHERE_VIEW__CLOUD_LAYER_HPP_

#include <rclcpp/rclcpp.hpp>
#include <rviz_common/properties/bool_property.hpp>
#include <rviz_rendering/objects/point_cloud.hpp>

#include <sensor_msgs/msg/point_cloud2.hpp>

#include <memory>
#include <mutex>
#include <string>

#include "cloud_projection.hpp"

namespace rviz_common
{
class DisplayContext;
namespace properties
{
class ColorProperty;
class EnumProperty;
class FloatProperty;
class IntProperty;
class RosTopicProperty;
}  // namespace properties
}  // namespace rviz_common

namespace golfcart_sphere_view
{

/// One LiDAR on the sphere.
///
/// The placement property is the point of the whole display. Angular discards
/// range and keeps direction, which is the only thing a camera can be compared
/// against; Metric keeps range, which is what separates a translation error
/// from a wrong sphere radius.
class CloudLayer : public rviz_common::properties::BoolProperty
{
  Q_OBJECT

public:
  CloudLayer(
    const QString & name, const QString & topic, const QColor & flat_colour,
    rviz_common::properties::Property * parent);
  ~CloudLayer() override;

  void initialize(rviz_common::DisplayContext * context, Ogre::SceneNode * parent_scene_node);

  void subscribe();
  void unsubscribe();

  /// Re-place the points if a new cloud arrived, or if the sphere changed.
  void update(const std::string & centre_frame, double radius, bool sphere_changed);

  QString statusSummary() const;

private Q_SLOTS:
  void onTopicChanged();
  void onStyleChanged();
  void onEnableChanged();

private:
  enum ColourMode
  {
    ColourByIntensity = 0,
    ColourByRange = 1,
    ColourFlat = 2,
  };

  void rebuildPoints(const std::string & centre_frame, double radius);

  rviz_common::DisplayContext * context_{nullptr};
  std::unique_ptr<rviz_rendering::PointCloud> point_cloud_;
  Ogre::SceneNode * scene_node_{nullptr};

  rviz_common::properties::RosTopicProperty * topic_property_;
  rviz_common::properties::EnumProperty * placement_property_;
  rviz_common::properties::EnumProperty * colour_mode_property_;
  rviz_common::properties::ColorProperty * flat_colour_property_;
  rviz_common::properties::FloatProperty * point_size_property_;
  rviz_common::properties::FloatProperty * alpha_property_;
  rviz_common::properties::IntProperty * decimation_property_;
  rviz_common::properties::FloatProperty * intensity_max_property_;

  rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr subscription_;

  std::mutex cloud_mutex_;
  sensor_msgs::msg::PointCloud2::ConstSharedPtr cloud_;
  bool has_new_cloud_{false};

  std::size_t rendered_points_{0};
  std::string transform_error_;
  bool missing_intensity_{false};
};

}  // namespace golfcart_sphere_view

#endif  // GOLFCART_SPHERE_VIEW__CLOUD_LAYER_HPP_
