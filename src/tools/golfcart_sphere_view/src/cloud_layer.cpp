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

#include "cloud_layer.hpp"

#include <OgreSceneManager.h>
#include <OgreSceneNode.h>

#include <rviz_common/display_context.hpp>
#include <rviz_common/frame_manager_iface.hpp>
#include <rviz_common/properties/color_property.hpp>
#include <rviz_common/properties/enum_property.hpp>
#include <rviz_common/properties/float_property.hpp>
#include <rviz_common/properties/int_property.hpp>
#include <rviz_common/properties/ros_topic_property.hpp>
#include <rviz_common/ros_integration/ros_node_abstraction_iface.hpp>

#include <sensor_msgs/point_cloud2_iterator.hpp>

#include <algorithm>
#include <string>
#include <vector>

namespace golfcart_sphere_view
{

CloudLayer::CloudLayer(
  const QString & name, const QString & topic, const QColor & flat_colour,
  rviz_common::properties::Property * parent)
: rviz_common::properties::BoolProperty(name, true, "Draw this LiDAR.", parent)
{
  connect(this, SIGNAL(changed()), this, SLOT(onEnableChanged()));

  topic_property_ = new rviz_common::properties::RosTopicProperty(
    "Topic", topic, "sensor_msgs/msg/PointCloud2", "Point cloud for this sensor.", this,
    SLOT(onTopicChanged()));

  placement_property_ = new rviz_common::properties::EnumProperty(
    "Placement", "Angular",
    "Angular snaps returns to the sphere radius, which discards range and leaves the "
    "direction -- the only thing a camera can be compared against. Metric leaves them "
    "where they were measured, which is what tells a translation error apart from a "
    "wrong radius.",
    this, SLOT(onStyleChanged()));
  placement_property_->addOption("Angular", static_cast<int>(CloudPlacement::Angular));
  placement_property_->addOption("Metric", static_cast<int>(CloudPlacement::Metric));

  colour_mode_property_ = new rviz_common::properties::EnumProperty(
    "Colour By", "Intensity", "How each return is coloured.", this, SLOT(onStyleChanged()));
  colour_mode_property_->addOption("Intensity", ColourByIntensity);
  colour_mode_property_->addOption("Range", ColourByRange);
  colour_mode_property_->addOption("Flat", ColourFlat);

  flat_colour_property_ = new rviz_common::properties::ColorProperty(
    "Flat Colour", flat_colour,
    "Colour when Colour By is Flat. One colour per sensor is what makes two LiDARs "
    "legible in the same overlap.",
    this, SLOT(onStyleChanged()));

  intensity_max_property_ = new rviz_common::properties::FloatProperty(
    "Intensity Max", 255.0f,
    "Intensity mapped to the top of the colour scale. VLP-32C reports 0-255, with "
    "101-255 reserved for retroreflectors.",
    this, SLOT(onStyleChanged()));
  intensity_max_property_->setMin(1.0f);

  point_size_property_ = new rviz_common::properties::FloatProperty(
    "Point Size", 0.05f, "Rendered size of a return, in metres.", this, SLOT(onStyleChanged()));
  point_size_property_->setMin(0.001f);

  alpha_property_ = new rviz_common::properties::FloatProperty(
    "Alpha", 1.0f, "Point transparency.", this, SLOT(onStyleChanged()));
  alpha_property_->setMin(0.0f);
  alpha_property_->setMax(1.0f);

  decimation_property_ = new rviz_common::properties::IntProperty(
    "Decimation", 1,
    "Keep one return in N. A 32-plane cloud will otherwise bury the image it is meant "
    "to be checked against.",
    this, SLOT(onStyleChanged()));
  decimation_property_->setMin(1);
}

CloudLayer::~CloudLayer()
{
  unsubscribe();
  if (point_cloud_ && scene_node_) {
    scene_node_->detachObject(point_cloud_.get());
    context_->getSceneManager()->destroySceneNode(scene_node_);
  }
}

void CloudLayer::initialize(
  rviz_common::DisplayContext * context, Ogre::SceneNode * parent_scene_node)
{
  context_ = context;
  point_cloud_ = std::make_unique<rviz_rendering::PointCloud>();
  point_cloud_->setRenderMode(rviz_rendering::PointCloud::RM_SQUARES);
  point_cloud_->setDimensions(
    point_size_property_->getFloat(), point_size_property_->getFloat(),
    point_size_property_->getFloat());
  scene_node_ = parent_scene_node->createChildSceneNode();
  scene_node_->attachObject(point_cloud_.get());
}

void CloudLayer::subscribe()
{
  if (!context_ || !getBool()) {
    return;
  }
  auto node = context_->getRosNodeAbstraction().lock();
  if (!node) {
    return;
  }
  // Same reason as the camera layer: a blank topic is an unconfigured layer,
  // and subscribing to it throws out of rclcpp mid config load.
  const std::string topic = topic_property_->getTopicStd();
  if (topic.empty()) {
    return;
  }
  subscription_ = node->get_raw_node()->create_subscription<sensor_msgs::msg::PointCloud2>(
    topic, rclcpp::SensorDataQoS(),
    [this](sensor_msgs::msg::PointCloud2::ConstSharedPtr message) {
      // Keep the message and do the work on the render thread. Transforming
      // here would need FrameManager from a subscription thread, and the cost
      // is bounded anyway: this runs once per cloud, not once per frame.
      std::lock_guard<std::mutex> lock(cloud_mutex_);
      cloud_ = message;
      has_new_cloud_ = true;
    });
}

void CloudLayer::unsubscribe()
{
  subscription_.reset();
  std::lock_guard<std::mutex> lock(cloud_mutex_);
  cloud_.reset();
  has_new_cloud_ = false;
}

void CloudLayer::onTopicChanged()
{
  unsubscribe();
  if (point_cloud_) {
    point_cloud_->clear();
  }
  rendered_points_ = 0;
  subscribe();
}

void CloudLayer::onStyleChanged()
{
  if (point_cloud_) {
    point_cloud_->setDimensions(
      point_size_property_->getFloat(), point_size_property_->getFloat(),
      point_size_property_->getFloat());
    point_cloud_->setAlpha(alpha_property_->getFloat());
  }
  // Colour, placement and decimation all change what the points are, not just
  // how they are drawn, so the cloud has to be walked again.
  std::lock_guard<std::mutex> lock(cloud_mutex_);
  if (cloud_) {
    has_new_cloud_ = true;
  }
}

void CloudLayer::onEnableChanged()
{
  const bool enabled = getBool();
  if (scene_node_) {
    scene_node_->setVisible(enabled);
  }
  if (enabled) {
    subscribe();
  } else {
    unsubscribe();
  }
}

void CloudLayer::update(const std::string & centre_frame, double radius, bool sphere_changed)
{
  if (!getBool() || !point_cloud_) {
    return;
  }
  bool work_to_do = sphere_changed;
  {
    std::lock_guard<std::mutex> lock(cloud_mutex_);
    work_to_do = work_to_do || has_new_cloud_;
    has_new_cloud_ = false;
  }
  if (work_to_do) {
    rebuildPoints(centre_frame, radius);
  }
}

void CloudLayer::rebuildPoints(const std::string & centre_frame, double radius)
{
  sensor_msgs::msg::PointCloud2::ConstSharedPtr cloud;
  {
    std::lock_guard<std::mutex> lock(cloud_mutex_);
    cloud = cloud_;
  }
  if (!cloud) {
    return;
  }

  // The sensor is bolted on, so the transform is static and asking at time zero
  // avoids failing in the window before tf_static arrives.
  Ogre::Vector3 centre_position;
  Ogre::Quaternion centre_orientation;
  Ogre::Vector3 sensor_position;
  Ogre::Quaternion sensor_orientation;
  auto * frame_manager = context_->getFrameManager();
  const rclcpp::Time latest(0, 0, RCL_ROS_TIME);
  if (!frame_manager->getTransform(centre_frame, latest, centre_position, centre_orientation) ||
    !frame_manager->getTransform(
      cloud->header.frame_id, latest, sensor_position, sensor_orientation))
  {
    transform_error_ = "no transform " + centre_frame + " -> " + cloud->header.frame_id;
    point_cloud_->clear();
    rendered_points_ = 0;
    return;
  }
  transform_error_.clear();

  const Ogre::Quaternion centre_inverse = centre_orientation.Inverse();
  const Ogre::Quaternion sensor_to_centre = centre_inverse * sensor_orientation;
  const Ogre::Vector3 sensor_origin_in_centre = centre_inverse * (sensor_position - centre_position);

  const auto placement = static_cast<CloudPlacement>(placement_property_->getOptionInt());
  const int colour_mode = colour_mode_property_->getOptionInt();
  const auto flat = flat_colour_property_->getOgreColor();
  const int decimation = decimation_property_->getInt();
  const double intensity_max = intensity_max_property_->getFloat();

  const bool has_intensity = std::any_of(
    cloud->fields.begin(), cloud->fields.end(),
    [](const sensor_msgs::msg::PointField & field) { return field.name == "intensity"; });
  missing_intensity_ = (colour_mode == ColourByIntensity) && !has_intensity;

  std::vector<rviz_rendering::PointCloud::Point> points;
  points.reserve(cloud->width * cloud->height / static_cast<std::size_t>(decimation) + 1u);

  sensor_msgs::PointCloud2ConstIterator<float> iter_x(*cloud, "x");
  sensor_msgs::PointCloud2ConstIterator<float> iter_y(*cloud, "y");
  sensor_msgs::PointCloud2ConstIterator<float> iter_z(*cloud, "z");
  std::unique_ptr<sensor_msgs::PointCloud2ConstIterator<float>> iter_intensity;
  if (has_intensity) {
    iter_intensity =
      std::make_unique<sensor_msgs::PointCloud2ConstIterator<float>>(*cloud, "intensity");
  }

  std::size_t index = 0;
  for (; iter_x != iter_x.end(); ++iter_x, ++iter_y, ++iter_z, ++index) {
    const float intensity = iter_intensity ? **iter_intensity : 0.0f;
    if (iter_intensity) {
      ++(*iter_intensity);
    }
    if (decimation > 1 && (index % static_cast<std::size_t>(decimation)) != 0u) {
      continue;
    }
    if (!std::isfinite(*iter_x) || !std::isfinite(*iter_y) || !std::isfinite(*iter_z)) {
      continue;
    }

    const Ogre::Vector3 in_sensor(*iter_x, *iter_y, *iter_z);
    const Ogre::Vector3 in_centre = sensor_to_centre * in_sensor + sensor_origin_in_centre;

    rviz_rendering::PointCloud::Point point;
    point.position = placePoint(in_centre, radius, placement);
    switch (colour_mode) {
      case ColourByIntensity:
        point.color = rainbow(static_cast<double>(intensity) / intensity_max);
        break;
      case ColourByRange:
        // Scaled against the sphere, so the colours mean the same thing in
        // Angular mode -- where every point is at the radius -- as in Metric.
        point.color = rainbow(in_centre.length() / (2.0 * radius));
        break;
      default:
        point.color = flat;
        break;
    }
    points.push_back(point);
  }

  point_cloud_->clear();
  if (!points.empty()) {
    point_cloud_->addPoints(points.begin(), points.end());
  }
  point_cloud_->setAlpha(alpha_property_->getFloat());
  rendered_points_ = points.size();
}

QString CloudLayer::statusSummary() const
{
  if (!getBool()) {
    return getName() + ": off";
  }
  if (!transform_error_.empty()) {
    return getName() + ": " + QString::fromStdString(transform_error_);
  }
  if (rendered_points_ == 0) {
    return getName() + ": no points";
  }
  QString summary = getName() + ": " + QString::number(rendered_points_) + " points";
  if (missing_intensity_) {
    summary += ", no intensity field";
  }
  return summary;
}

}  // namespace golfcart_sphere_view
