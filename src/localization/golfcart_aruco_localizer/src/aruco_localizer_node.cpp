// Copyright 2026 Golf Cart Team
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
//
// Phase 3D-1 skeleton. Declares and validates the full parameter set, loads and
// validates the tag map, and publishes it for RViz. No detections are consumed
// and no pose is produced -- that is phase 3D-4.

#include <golfcart_aruco_localizer/tag_map.hpp>

#include <rclcpp/rclcpp.hpp>
#include <visualization_msgs/msg/marker_array.hpp>

#include <Eigen/Geometry>

#include <memory>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

class ArucoLocalizerNode : public rclcpp::Node
{
public:
  explicit ArucoLocalizerNode(const rclcpp::NodeOptions & options)
  : rclcpp::Node("aruco_localizer", options)
  {
    declareParameters();
    logConfiguration();

    // Latched, so RViz shows the map whenever it connects rather than only if
    // it happened to be listening at startup.
    map_publisher_ = create_publisher<visualization_msgs::msg::MarkerArray>(
      "~/debug/mapped_tags", rclcpp::QoS(1).transient_local().reliable());

    loadTagMap();

    RCLCPP_INFO(
      get_logger(),
      "phase 3D-1 skeleton: tag map loaded and published, no solve running yet");
  }

private:
  struct Parameters
  {
    std::string tag_map_path;
    TagMapOptions map_options;
    std::vector<std::string> camera_names;
    double corner_sigma_px{};
    double corner_sigma_px_moving{};
    double window_duration{};
    bool motion_compensation{};
    double max_future_stamp{};
    double max_range{};
    double min_view_angle_deg{};
    double max_view_angle_deg{};
    double ambiguity_ratio_max{};
    double consensus_position_tolerance{};
    double consensus_rotation_tolerance_deg{};
    int min_markers_for_6dof{};
    double min_normal_spread_deg{};
    double max_condition_number{};
    double huber_delta_px{};
    int max_iterations{};
    double convergence_tolerance{};
    double max_position_variance{};
    double max_rotation_variance{};
    double residual_ewma_alpha{};
    double residual_flag_sigma{};
    int residual_flag_count{};
    double degraded_budget_s{};
    double dead_reckoning_budget_s{};
  };

  /// Every parameter is declared and range-checked here, at startup, so a
  /// misconfiguration fails immediately and by name. The alternative -- finding
  /// out at the first solve, or worse, not finding out -- is how a threshold
  /// set below the sensor noise floor can sit unnoticed for months.
  void declareParameters()
  {
    params_.tag_map_path = declare_parameter<std::string>("tag_map_path", "");

    params_.map_options.coplanarity_tolerance =
      requirePositive("coplanarity_tolerance", declare_parameter<double>("coplanarity_tolerance", 0.01));
    params_.map_options.proximity_warn =
      requirePositive("proximity_warn", declare_parameter<double>("proximity_warn", 0.10));
    params_.map_options.size_mismatch_warn =
      requirePositive("size_mismatch_warn", declare_parameter<double>("size_mismatch_warn", 0.05));

    params_.camera_names =
      declare_parameter<std::vector<std::string>>("camera_names", {"left", "right", "rear"});
    if (params_.camera_names.empty()) {
      throw std::runtime_error("camera_names is empty: the localizer would have no input");
    }

    params_.corner_sigma_px =
      requirePositive("corner_sigma_px", declare_parameter<double>("corner_sigma_px", 0.3));
    params_.corner_sigma_px_moving = requirePositive(
      "corner_sigma_px_moving", declare_parameter<double>("corner_sigma_px_moving", 0.6));

    params_.window_duration =
      requirePositive("window_duration", declare_parameter<double>("window_duration", 0.033));
    params_.motion_compensation = declare_parameter<bool>("motion_compensation", true);
    params_.max_future_stamp =
      requirePositive("max_future_stamp", declare_parameter<double>("max_future_stamp", 0.1));

    params_.max_range = requirePositive("max_range", declare_parameter<double>("max_range", 13.0));
    params_.min_view_angle_deg = declare_parameter<double>("min_view_angle_deg", 25.0);
    params_.max_view_angle_deg = declare_parameter<double>("max_view_angle_deg", 75.0);
    if (params_.min_view_angle_deg >= params_.max_view_angle_deg) {
      throw std::runtime_error(
        "min_view_angle_deg must be below max_view_angle_deg: the usable window is bounded "
        "below by pose ambiguity and above by detection failure");
    }

    params_.ambiguity_ratio_max =
      declare_parameter<double>("ambiguity_ratio_max", 0.2);
    if (params_.ambiguity_ratio_max <= 0.0 || params_.ambiguity_ratio_max > 1.0) {
      throw std::runtime_error(
        "ambiguity_ratio_max must be in (0, 1]: it is error_1 / error_2 with "
        "error_1 <= error_2, so it cannot exceed 1");
    }

    params_.consensus_position_tolerance = requirePositive(
      "consensus_position_tolerance", declare_parameter<double>("consensus_position_tolerance", 0.5));
    params_.consensus_rotation_tolerance_deg = requirePositive(
      "consensus_rotation_tolerance_deg",
      declare_parameter<double>("consensus_rotation_tolerance_deg", 10.0));

    params_.min_markers_for_6dof = declare_parameter<int>("min_markers_for_6dof", 2);
    if (params_.min_markers_for_6dof < 2) {
      throw std::runtime_error(
        "min_markers_for_6dof must be at least 2: a single board cannot resolve its own "
        "flip, and its orientation carries roughly 12 degrees of jitter");
    }

    params_.min_normal_spread_deg = requirePositive(
      "min_normal_spread_deg", declare_parameter<double>("min_normal_spread_deg", 20.0));
    params_.max_condition_number = requirePositive(
      "max_condition_number", declare_parameter<double>("max_condition_number", 1.0e4));

    params_.huber_delta_px =
      requirePositive("huber_delta_px", declare_parameter<double>("huber_delta_px", 2.0));
    params_.max_iterations = declare_parameter<int>("max_iterations", 30);
    if (params_.max_iterations < 1) {
      throw std::runtime_error("max_iterations must be at least 1");
    }
    params_.convergence_tolerance = requirePositive(
      "convergence_tolerance", declare_parameter<double>("convergence_tolerance", 1.0e-8));

    params_.max_position_variance = requirePositive(
      "max_position_variance", declare_parameter<double>("max_position_variance", 100.0));
    params_.max_rotation_variance = requirePositive(
      "max_rotation_variance", declare_parameter<double>("max_rotation_variance", 1.0));

    params_.residual_ewma_alpha = declare_parameter<double>("residual_ewma_alpha", 0.1);
    if (params_.residual_ewma_alpha <= 0.0 || params_.residual_ewma_alpha > 1.0) {
      throw std::runtime_error("residual_ewma_alpha must be in (0, 1]");
    }
    params_.residual_flag_sigma =
      requirePositive("residual_flag_sigma", declare_parameter<double>("residual_flag_sigma", 3.0));
    params_.residual_flag_count = declare_parameter<int>("residual_flag_count", 10);
    if (params_.residual_flag_count < 1) {
      throw std::runtime_error("residual_flag_count must be at least 1");
    }

    params_.degraded_budget_s =
      requirePositive("degraded_budget_s", declare_parameter<double>("degraded_budget_s", 10.0));
    params_.dead_reckoning_budget_s = requirePositive(
      "dead_reckoning_budget_s", declare_parameter<double>("dead_reckoning_budget_s", 3.0));

    // Initialization gates, declared now so the full contract is visible even
    // though 3D-1 does not act on them.
    declare_parameter<int>("initialization.min_markers", 2);
    declare_parameter<double>("initialization.min_normal_spread_deg", 20.0);
    declare_parameter<double>("initialization.max_range", 8.0);
    declare_parameter<double>("initialization.max_view_angle_deg", 50.0);
    declare_parameter<int>("initialization.consecutive_solves", 5);
    declare_parameter<double>("initialization.agreement_radius", 0.5);
    declare_parameter<double>("initialization.max_condition_number", 1.0e4);
    declare_parameter<double>("initialization.republish_cooldown", 10.0);
  }

  double requirePositive(const std::string & name, const double value) const
  {
    if (!(value > 0.0)) {
      throw std::runtime_error(name + " must be positive, got " + std::to_string(value));
    }
    return value;
  }

  void logConfiguration() const
  {
    RCLCPP_INFO(get_logger(), "ArUco localizer configuration:");
    RCLCPP_INFO(get_logger(), "  tag_map_path            : %s", params_.tag_map_path.c_str());
    RCLCPP_INFO(get_logger(), "  cameras                 : %zu", params_.camera_names.size());
    RCLCPP_INFO(get_logger(), "  corner_sigma_px         : %.3f  (INFERRED, not measured)",
      params_.corner_sigma_px);
    RCLCPP_INFO(get_logger(), "  window_duration         : %.3f s", params_.window_duration);
    RCLCPP_INFO(get_logger(), "  motion_compensation     : %s",
      params_.motion_compensation ? "on" : "off");
    RCLCPP_INFO(get_logger(), "  usable view angle       : %.1f .. %.1f deg off the board normal",
      params_.min_view_angle_deg, params_.max_view_angle_deg);
    RCLCPP_INFO(get_logger(), "  ambiguity_ratio_max     : %.2f", params_.ambiguity_ratio_max);
    RCLCPP_INFO(get_logger(), "  min_markers_for_6dof    : %d", params_.min_markers_for_6dof);
    RCLCPP_INFO(get_logger(), "  dead_reckoning_budget_s : %.1f s  (PLACEHOLDER, must be measured)",
      params_.dead_reckoning_budget_s);
  }

  void loadTagMap()
  {
    if (params_.tag_map_path.empty()) {
      throw std::runtime_error(
        "tag_map_path is not set. This localizer is the sole pose source, so it "
        "refuses to start without a map rather than run silently.");
    }

    const TagMapLoadResult loaded =
      loadTagMapFromFile(params_.tag_map_path, params_.map_options);
    map_ = loaded.map;

    for (const auto & warning : loaded.warnings) {
      RCLCPP_WARN(get_logger(), "tag map: %s", warning.c_str());
    }

    RCLCPP_INFO(
      get_logger(), "tag map: %zu boards in frame '%s', dictionary '%s'", map_.tags.size(),
      map_.frame_id.c_str(), map_.dictionary.c_str());
    RCLCPP_INFO(
      get_logger(),
      "tag map: survey %s by '%s', stated accuracy %.3f m -- this is the ceiling on the "
      "accuracy of everything downstream",
      map_.survey.date.empty() ? "(undated)" : map_.survey.date.c_str(),
      map_.survey.method.empty() ? "(unspecified)" : map_.survey.method.c_str(),
      map_.survey.stated_accuracy);

    map_publisher_->publish(buildMapMarkers());
  }

  visualization_msgs::msg::MarkerArray buildMapMarkers() const
  {
    visualization_msgs::msg::MarkerArray array;
    int id = 0;

    for (const auto & [tag_id, tag] : map_.tags) {
      const auto corners = tagCornersInMap(tag.pose, tag.marker_size);

      visualization_msgs::msg::Marker outline;
      outline.header.frame_id = map_.frame_id;
      outline.ns = "aruco_boards";
      outline.id = id++;
      outline.type = visualization_msgs::msg::Marker::LINE_STRIP;
      outline.action = visualization_msgs::msg::Marker::ADD;
      outline.pose.orientation.w = 1.0;
      outline.scale.x = 0.02;
      outline.color.r = 0.05;
      outline.color.g = 0.49;
      outline.color.b = 0.53;
      outline.color.a = 1.0;
      for (std::size_t i = 0; i <= kNumCorners; ++i) {
        geometry_msgs::msg::Point p;
        const Eigen::Vector3d & c = corners[i % kNumCorners];
        p.x = c.x();
        p.y = c.y();
        p.z = c.z();
        outline.points.push_back(p);
      }
      array.markers.push_back(outline);

      visualization_msgs::msg::Marker label;
      label.header.frame_id = map_.frame_id;
      label.ns = "aruco_board_ids";
      label.id = id++;
      label.type = visualization_msgs::msg::Marker::TEXT_VIEW_FACING;
      label.action = visualization_msgs::msg::Marker::ADD;
      label.pose.position.x = tag.pose.translation().x();
      label.pose.position.y = tag.pose.translation().y();
      label.pose.position.z = tag.pose.translation().z() + 0.5 * tag.marker_size + 0.08;
      label.pose.orientation.w = 1.0;
      label.scale.z = 0.15;
      label.color.r = 1.0;
      label.color.g = 1.0;
      label.color.b = 1.0;
      label.color.a = 1.0;
      label.text = std::to_string(tag_id);
      array.markers.push_back(label);
    }

    return array;
  }

  Parameters params_;
  TagMap map_;
  rclcpp::Publisher<visualization_msgs::msg::MarkerArray>::SharedPtr map_publisher_;
};

}  // namespace golfcart::aruco_localizer

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);

  try {
    auto node = std::make_shared<golfcart::aruco_localizer::ArucoLocalizerNode>(
      rclcpp::NodeOptions{});
    rclcpp::spin(node);
  } catch (const std::exception & e) {
    RCLCPP_FATAL(rclcpp::get_logger("aruco_localizer"), "startup failed: %s", e.what());
    rclcpp::shutdown();
    return 1;
  }

  rclcpp::shutdown();
  return 0;
}
