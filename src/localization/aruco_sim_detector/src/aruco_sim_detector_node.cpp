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
// Phase 3D-3. Ground-truth pose in, synthetic ArucoDetectionArray out.

#include <aruco_sim_detector/marker_pnp.hpp>
#include <aruco_sim_detector/sim_camera.hpp>
#include <golfcart_aruco_localizer/tag_frame.hpp>
#include <golfcart_aruco_localizer/tag_map.hpp>

#include <rclcpp/rclcpp.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <aruco_detection_msgs/msg/aruco_detection_array.hpp>

#include <opencv2/calib3d.hpp>
#include <opencv2/core.hpp>

#include <tf2_eigen/tf2_eigen.hpp>

#include <algorithm>
#include <memory>
#include <random>
#include <string>
#include <unordered_set>
#include <vector>

namespace golfcart::aruco_sim
{

using aruco_localizer::kNumCorners;
using aruco_localizer::TagMap;
using aruco_localizer::TagPose;

class ArucoSimDetectorNode : public rclcpp::Node
{
public:
  explicit ArucoSimDetectorNode(const rclcpp::NodeOptions & options)
  : rclcpp::Node("aruco_sim_detector", options)
  {
    declareParameters();
    loadTagMap();
    buildCameras();

    ground_truth_sub_ = create_subscription<nav_msgs::msg::Odometry>(
      "~/input/ground_truth", rclcpp::QoS(10),
      [this](nav_msgs::msg::Odometry::ConstSharedPtr msg) { onGroundTruth(*msg); });

    RCLCPP_INFO(
      get_logger(), "simulating %zu cameras against %zu boards, corner sigma %.2f px",
      cameras_.size(), map_.tags.size(), corner_sigma_px_);
    if (blackout_) {
      RCLCPP_WARN(get_logger(), "FAULT INJECTION: blackout active, no detections will be emitted");
    }
    if (displaced_id_ >= 0) {
      RCLCPP_WARN(
        get_logger(), "FAULT INJECTION: board %d displaced by [%.3f %.3f %.3f] from its map entry",
        displaced_id_, displacement_.x(), displacement_.y(), displacement_.z());
    }
    if (!visible_allowlist_.empty()) {
      RCLCPP_WARN(
        get_logger(), "FAULT INJECTION: only %zu board(s) allowed visible",
        visible_allowlist_.size());
    }
  }

private:
  void declareParameters()
  {
    tag_map_path_ = declare_parameter<std::string>("tag_map_path", "");
    if (tag_map_path_.empty()) {
      throw std::runtime_error("tag_map_path is required");
    }

    corner_sigma_px_ = declare_parameter<double>("corner_sigma_px", 0.3);
    if (corner_sigma_px_ < 0.0) {
      throw std::runtime_error("corner_sigma_px must not be negative");
    }
    max_range_ = declare_parameter<double>("max_range", 13.0);
    // Detection, not ambiguity. Boards seen closer to their normal than the
    // ambiguity cone are still *detected*; they are just hard to orient, and
    // emitting them is the point.
    max_detect_angle_deg_ = declare_parameter<double>("max_detect_angle_deg", 82.0);
    min_marker_px_ = declare_parameter<double>("min_marker_px", 20.0);

    // Deterministic by default: a fixture whose output changes run to run
    // cannot be used to bisect a regression.
    seed_ = static_cast<unsigned int>(declare_parameter<int>("seed", 42));
    rng_.seed(seed_);

    // ── fault injection ────────────────────────────────────────────────────
    blackout_ = declare_parameter<bool>("fault.blackout", false);
    displaced_id_ = declare_parameter<int>("fault.displaced_board_id", -1);
    const auto d = declare_parameter<std::vector<double>>(
      "fault.displacement", std::vector<double>{0.0, 0.0, 0.0});
    if (d.size() != 3) {
      throw std::runtime_error("fault.displacement must have 3 elements");
    }
    displacement_ = Eigen::Vector3d{d[0], d[1], d[2]};

    const auto allow = declare_parameter<std::vector<int64_t>>(
      "fault.visible_board_ids", std::vector<int64_t>{});
    for (const auto id : allow) {
      visible_allowlist_.insert(static_cast<std::uint32_t>(id));
    }

    max_future_stamp_ = declare_parameter<double>("fault.stamp_offset_s", 0.0);
  }

  void loadTagMap()
  {
    const auto loaded = aruco_localizer::loadTagMapFromFile(tag_map_path_);
    map_ = loaded.map;
    for (const auto & w : loaded.warnings) {
      RCLCPP_WARN(get_logger(), "tag map: %s", w.c_str());
    }
    if (map_.tags.empty()) {
      throw std::runtime_error("tag map is empty");
    }
  }

  void buildCameras()
  {
    const auto names = declare_parameter<std::vector<std::string>>(
      "camera_names", std::vector<std::string>{});
    if (names.empty()) {
      throw std::runtime_error("camera_names is empty");
    }

    for (const auto & name : names) {
      SimCamera cam;
      cam.name = name;
      const std::string p = "cameras." + name + ".";
      cam.optical_frame = declare_parameter<std::string>(p + "optical_frame", name + "_optical");
      cam.fx = declare_parameter<double>(p + "fx", 900.0);
      cam.fy = declare_parameter<double>(p + "fy", 900.0);
      cam.cx = declare_parameter<double>(p + "cx", 960.0);
      cam.cy = declare_parameter<double>(p + "cy", 640.0);
      cam.width = declare_parameter<int>(p + "width", 1920);
      cam.height = declare_parameter<int>(p + "height", 1280);
      cam.stamp_offset = declare_parameter<double>(p + "stamp_offset", 0.0);

      // Extrinsic given as translation plus roll/pitch/yaw of the OPTICAL frame
      // in base_link. Optical means z forward, x right, y down, so a camera
      // pointing straight ahead is not identity — it carries the standard
      // (-pi/2, 0, -pi/2) rotation. Writing that out here rather than hiding it
      // is deliberate: the vehicle URDF is currently missing exactly this
      // rotation, and that is the blocker the design calls out.
      const auto xyz = declare_parameter<std::vector<double>>(
        p + "xyz", std::vector<double>{0.0, 0.0, 0.0});
      const auto rpy = declare_parameter<std::vector<double>>(
        p + "rpy", std::vector<double>{-1.5707963, 0.0, -1.5707963});
      if (xyz.size() != 3 || rpy.size() != 3) {
        throw std::runtime_error("camera " + name + ": xyz and rpy must have 3 elements each");
      }
      Eigen::Isometry3d t = Eigen::Isometry3d::Identity();
      t.linear() = (Eigen::AngleAxisd(rpy[2], Eigen::Vector3d::UnitZ()) *
                    Eigen::AngleAxisd(rpy[1], Eigen::Vector3d::UnitY()) *
                    Eigen::AngleAxisd(rpy[0], Eigen::Vector3d::UnitX()))
                     .toRotationMatrix();
      t.translation() = Eigen::Vector3d{xyz[0], xyz[1], xyz[2]};
      cam.base_to_cam = t;

      publishers_[name] = create_publisher<aruco_detection_msgs::msg::ArucoDetectionArray>(
        "~/output/detections/" + name, rclcpp::QoS(10));
      cameras_.push_back(cam);
    }
  }

  /// Where a board actually is, which is not necessarily where the map says.
  Eigen::Isometry3d truePose(const TagPose & tag) const
  {
    Eigen::Isometry3d pose = tag.pose;
    if (displaced_id_ >= 0 && tag.id == static_cast<std::uint32_t>(displaced_id_)) {
      pose.translation() += displacement_;
    }
    return pose;
  }

  bool allowedVisible(std::uint32_t id) const
  {
    return visible_allowlist_.empty() || visible_allowlist_.count(id) != 0;
  }

  void onGroundTruth(const nav_msgs::msg::Odometry & msg)
  {
    Eigen::Isometry3d map_to_base;
    tf2::fromMsg(msg.pose.pose, map_to_base);

    for (const auto & cam : cameras_) {
      aruco_detection_msgs::msg::ArucoDetectionArray out;
      out.header.frame_id = cam.optical_frame;
      out.header.stamp = rclcpp::Time(msg.header.stamp) +
        rclcpp::Duration::from_seconds(cam.stamp_offset + max_future_stamp_);
      const Eigen::Matrix3d k = cam.intrinsics();
      out.k = {k(0, 0), k(0, 1), k(0, 2), k(1, 0), k(1, 1), k(1, 2), k(2, 0), k(2, 1), k(2, 2)};
      out.image_width = static_cast<std::uint32_t>(cam.width);
      out.image_height = static_cast<std::uint32_t>(cam.height);

      if (!blackout_) {
        for (const auto & [id, tag] : map_.tags) {
          if (!allowedVisible(id)) {
            continue;
          }
          if (auto det = simulate(cam, map_to_base, tag)) {
            out.detections.push_back(*det);
          }
        }
      }
      publishers_.at(cam.name)->publish(out);
    }
  }

  std::optional<aruco_detection_msgs::msg::ArucoDetection> simulate(
    const SimCamera & cam, const Eigen::Isometry3d & map_to_base, const TagPose & tag)
  {
    const Eigen::Isometry3d cam_to_tag =
      cam.base_to_cam.inverse() * map_to_base.inverse() * truePose(tag);

    const double range = cam_to_tag.translation().norm();
    if (range > max_range_) {
      return std::nullopt;
    }
    const auto phi = incidenceAngle(cam_to_tag);
    if (!phi || *phi > max_detect_angle_deg_ * M_PI / 180.0) {
      return std::nullopt;
    }

    const auto local = aruco_localizer::tagLocalCorners(tag.marker_size);
    std::vector<cv::Point2f> pixels;
    pixels.reserve(kNumCorners);
    for (const auto & p : local) {
      const auto uv = project(cam, cam_to_tag * p);
      if (!uv) {
        return std::nullopt;  // any corner off-image means no detection
      }
      pixels.emplace_back(static_cast<float>(uv->x()), static_cast<float>(uv->y()));
    }

    // Too small on the sensor to be decoded at all.
    const double edge_px = cv::norm(pixels[0] - pixels[1]);
    if (edge_px < min_marker_px_) {
      return std::nullopt;
    }

    std::normal_distribution<double> noise(0.0, corner_sigma_px_);
    for (auto & px : pixels) {
      px.x += static_cast<float>(noise(rng_));
      px.y += static_cast<float>(noise(rng_));
    }

    // Same routine the real detector must use. See marker_pnp.hpp: OpenCV
    // 4.5.4's IPPE_SQUARE alone returns poses that do not reproject, so the
    // candidates are refined and scored here.
    const MarkerPnpResult pnp = solveMarkerPose(pixels, tag.marker_size, cam.intrinsics());
    if (!pnp.valid) {
      return std::nullopt;
    }

    aruco_detection_msgs::msg::ArucoDetection det;
    det.id = tag.id;
    for (std::size_t i = 0; i < kNumCorners; ++i) {
      det.corners_rectified[2 * i] = pixels[i].x;
      det.corners_rectified[2 * i + 1] = pixels[i].y;
    }
    det.pose_1 = tf2::toMsg(pnp.pose_1);
    det.pose_2 = tf2::toMsg(pnp.pose_2);
    det.reprojection_error_1 = pnp.error_1;
    det.reprojection_error_2 = pnp.error_2;
    return det;
  }

  std::string tag_map_path_;
  TagMap map_;
  std::vector<SimCamera> cameras_;
  std::map<std::string,
    rclcpp::Publisher<aruco_detection_msgs::msg::ArucoDetectionArray>::SharedPtr> publishers_;
  rclcpp::Subscription<nav_msgs::msg::Odometry>::SharedPtr ground_truth_sub_;

  double corner_sigma_px_{};
  double max_range_{};
  double max_detect_angle_deg_{};
  double min_marker_px_{};
  unsigned int seed_{};
  std::mt19937 rng_;

  bool blackout_{false};
  int displaced_id_{-1};
  Eigen::Vector3d displacement_{Eigen::Vector3d::Zero()};
  std::unordered_set<std::uint32_t> visible_allowlist_;
  double max_future_stamp_{0.0};
};

}  // namespace golfcart::aruco_sim

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    rclcpp::spin(
      std::make_shared<golfcart::aruco_sim::ArucoSimDetectorNode>(rclcpp::NodeOptions{}));
  } catch (const std::exception & e) {
    RCLCPP_FATAL(rclcpp::get_logger("aruco_sim_detector"), "startup failed: %s", e.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}
