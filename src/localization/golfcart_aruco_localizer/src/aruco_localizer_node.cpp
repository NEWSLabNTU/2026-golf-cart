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
// Detections from every camera in, one vehicle pose out. Phase 3D-4.

#include <golfcart_aruco_localizer/health.hpp>
#include <golfcart_aruco_localizer/solver.hpp>
#include <golfcart_aruco_localizer/tag_map.hpp>

#include <diagnostic_updater/diagnostic_updater.hpp>
#include <autoware_localization_msgs/srv/initialize_localization.hpp>
#include <rclcpp/rclcpp.hpp>
#include <geometry_msgs/msg/pose_with_covariance_stamped.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <visualization_msgs/msg/marker_array.hpp>
#include <aruco_detection_msgs/msg/aruco_detection_array.hpp>
#include <aruco_detection_msgs/msg/aruco_localizer_status.hpp>

#include <tf2_eigen/tf2_eigen.hpp>
#include <tf2_ros/buffer.h>
#include <tf2_ros/transform_listener.h>

#include <algorithm>
#include <deque>
#include <optional>
#include <set>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

using aruco_detection_msgs::msg::ArucoDetectionArray;
using aruco_detection_msgs::msg::ArucoLocalizerStatus;
using diagnostic_msgs::msg::DiagnosticStatus;

class ArucoLocalizerNode : public rclcpp::Node
{
public:
  explicit ArucoLocalizerNode(const rclcpp::NodeOptions & options)
  : rclcpp::Node("aruco_localizer", options),
    tf_buffer_(get_clock()),
    tf_listener_(tf_buffer_)
  {
    declareParameters();
    loadTagMap();

    map_publisher_ = create_publisher<visualization_msgs::msg::MarkerArray>(
      "~/debug/mapped_tags", rclcpp::QoS(1).transient_local().reliable());
    pose_publisher_ = create_publisher<geometry_msgs::msg::PoseWithCovarianceStamped>(
      "~/output/pose_with_covariance", rclcpp::QoS(10));
    // TRANSIENT_LOCAL, because this is published exactly once and the EKF is
    // not necessarily listening yet when it happens. With volatile durability
    // the one message goes out into an empty graph, the EKF waits forever for
    // an initial pose it already missed, and nothing downstream ever produces a
    // fused pose -- while the localizer log cheerfully reports that it
    // initialized. Latching it means a late subscriber still gets it.
    // Publishing /initialpose3d does NOT initialize Autoware, which is the
    // opposite of what the topic name suggests. pose_initializer PUBLISHES that
    // topic; it does not listen to it. Initialization arrives through this
    // service, and pose_initializer is what then triggers the EKF out of its
    // dormant state.
    //
    // Sending the topic alone meant the pose went out, nobody acted on it, and
    // the EKF waited forever for an initialization that had, from its point of
    // view, never been requested.
    initialize_client_ =
      create_client<autoware_localization_msgs::srv::InitializeLocalization>(
      "/localization/initialize");

    initial_pose_publisher_ = create_publisher<geometry_msgs::msg::PoseWithCovarianceStamped>(
      "~/output/initialpose", rclcpp::QoS(1).transient_local());
    status_publisher_ = create_publisher<ArucoLocalizerStatus>("~/status", rclcpp::QoS(10));

    // /diagnostics is the machine-readable half of ~/status, and the half that
    // can actually stop the vehicle: Autoware's diagnostic_graph_aggregator
    // consumes it and rolls it into HazardStatus, which is what drives an MRM.
    // Without this the state machine computes a FAULT, logs it, and nothing
    // downstream ever hears -- which is the worst of both worlds, because the
    // node looks like it has fault handling.
    diagnostics_ = std::make_unique<diagnostic_updater::Updater>(this);
    diagnostics_->setHardwareID("aruco_localizer");
    diagnostics_->add("aruco_localization_status", this, &ArucoLocalizerNode::diagnose);

    for (const auto & name : camera_names_) {
      detection_subs_.push_back(
        create_subscription<ArucoDetectionArray>(
          "~/input/detections/" + name, rclcpp::SensorDataQoS(),
          [this](ArucoDetectionArray::ConstSharedPtr msg) {onDetections(*msg);}));
    }
    kinematic_sub_ = create_subscription<nav_msgs::msg::Odometry>(
      "~/input/kinematic_state", rclcpp::QoS(10),
      [this](nav_msgs::msg::Odometry::ConstSharedPtr msg) {latest_odom_ = *msg;});

    window_timer_ = create_wall_timer(
      std::chrono::duration<double>(window_duration_), [this]() {processWindow();});

    map_publisher_->publish(buildMapMarkers());
    RCLCPP_INFO(
      get_logger(), "%zu boards, %zu cameras, %.0f ms window",
      map_.tags.size(), camera_names_.size(), window_duration_ * 1000.0);
  }

private:
  // ── configuration ─────────────────────────────────────────────────────────

  void declareParameters()
  {
    const std::string path = declare_parameter<std::string>("tag_map_path", "");
    if (path.empty()) {
      throw std::runtime_error(
        "tag_map_path is not set. This localizer is the sole pose source, so it "
        "refuses to start without a map rather than run silently.");
    }
    tag_map_path_ = path;

    map_options_.coplanarity_tolerance = declare_parameter<double>("coplanarity_tolerance", 0.01);
    map_options_.proximity_warn = declare_parameter<double>("proximity_warn", 0.10);
    map_options_.size_mismatch_warn = declare_parameter<double>("size_mismatch_warn", 0.05);

    camera_names_ = declare_parameter<std::vector<std::string>>(
      "camera_names", std::vector<std::string>{"left", "right", "rear"});
    if (camera_names_.empty()) {
      throw std::runtime_error("camera_names is empty: the localizer would have no input");
    }

    solve_options_.corner_sigma_px = require("corner_sigma_px", 0.3);
    corner_sigma_px_moving_ = require("corner_sigma_px_moving", 0.6);
    window_duration_ = require("window_duration", 0.033);
    motion_compensation_ = declare_parameter<bool>("motion_compensation", true);
    max_future_stamp_ = require("max_future_stamp", 0.1);

    max_range_ = require("max_range", 8.0);
    // The limit is set by where the ambiguity gate stops keeping flipped boards
    // out, not by where the detector stops seeing them. Measured for a 0.384 m
    // board at f=900 under 0.3 px corner noise, the share of gate-passing boards
    // that are still flipped is 0 % out to 7 m, 2.3 % at 9 m and 24 % at 13 m.
    // Past that a board is likelier to supply a confident wrong pose than a
    // missing one.
    if (max_range_ > 8.0) {
      RCLCPP_WARN(
        get_logger(),
        "max_range %.1f m is beyond where the ambiguity gate was measured to hold (8 m); "
        "expect flipped boards to reach consensus. Raise it only against a measurement "
        "for this board size, focal length and corner noise.",
        max_range_);
    }
    min_view_angle_deg_ = declare_parameter<double>("min_view_angle_deg", 25.0);
    max_view_angle_deg_ = declare_parameter<double>("max_view_angle_deg", 75.0);
    if (min_view_angle_deg_ >= max_view_angle_deg_) {
      throw std::runtime_error(
        "min_view_angle_deg must be below max_view_angle_deg: the usable window is "
        "bounded below by pose ambiguity and above by detection failure");
    }

    consensus_options_.ambiguity_ratio_max =
      declare_parameter<double>("ambiguity_ratio_max", 0.2);
    if (consensus_options_.ambiguity_ratio_max <= 0.0 ||
      consensus_options_.ambiguity_ratio_max > 1.0)
    {
      throw std::runtime_error(
        "ambiguity_ratio_max must be in (0, 1]: it is error_1 / error_2 with "
        "error_1 <= error_2, so it cannot exceed 1");
    }
    consensus_options_.position_tolerance = require("consensus_position_tolerance", 0.5);
    consensus_options_.rotation_tolerance_deg = require("consensus_rotation_tolerance_deg", 10.0);

    state_options_.min_boards_nominal = declare_parameter<int>("min_markers_for_6dof", 2);
    state_options_.min_normal_spread_deg = require("min_normal_spread_deg", 20.0);
    state_options_.degraded_budget_s = require("degraded_budget_s", 10.0);
    state_options_.dead_reckoning_budget_s = require("dead_reckoning_budget_s", 3.0);

    solve_options_.huber_delta_px = require("huber_delta_px", 2.0);
    solve_options_.max_iterations = declare_parameter<int>("max_iterations", 30);
    solve_options_.convergence_tolerance = require("convergence_tolerance", 1.0e-8);
    solve_options_.max_position_variance = require("max_position_variance", 100.0);
    solve_options_.max_rotation_variance = require("max_rotation_variance", 1.0);
    max_condition_number_ = require("max_condition_number", 1.0e4);

    integrity_options_.ewma_alpha = declare_parameter<double>("residual_ewma_alpha", 0.2);
    integrity_options_.flag_ratio = require("residual_flag_sigma", 4.0);
    integrity_options_.flag_count = declare_parameter<int>("residual_flag_count", 10);
    integrity_options_.flag_margin_px =
      declare_parameter<double>("residual_flag_margin_px", 1.5);
    integrity_options_.max_excluded = static_cast<std::size_t>(
      std::max<int64_t>(0, declare_parameter<int>("residual_max_excluded", 2)));

    init_min_boards_ = declare_parameter<int>("initialization.min_markers", 2);
    init_min_spread_deg_ = declare_parameter<double>("initialization.min_normal_spread_deg", 20.0);
    init_max_range_ = declare_parameter<double>("initialization.max_range", 8.0);
    init_max_view_angle_deg_ =
      declare_parameter<double>("initialization.max_view_angle_deg", 50.0);
    init_consecutive_ = declare_parameter<int>("initialization.consecutive_solves", 5);
    init_agreement_radius_ = declare_parameter<double>("initialization.agreement_radius", 0.5);
    init_max_speed_ = declare_parameter<double>("initialization.max_speed", 2.0);
    init_max_condition_ = declare_parameter<double>("initialization.max_condition_number", 1.0e4);
    init_cooldown_s_ = declare_parameter<double>("initialization.republish_cooldown", 10.0);

    integrity_ = IntegrityMonitor(integrity_options_);
    state_machine_ = LocalizationStateMachine(state_options_);
  }

  double require(const std::string & name, double fallback)
  {
    const double value = declare_parameter<double>(name, fallback);
    if (!(value > 0.0)) {
      throw std::runtime_error(name + " must be positive, got " + std::to_string(value));
    }
    return value;
  }

  void loadTagMap()
  {
    const auto loaded = loadTagMapFromFile(tag_map_path_, map_options_);
    map_ = loaded.map;
    for (const auto & warning : loaded.warnings) {
      RCLCPP_WARN(get_logger(), "tag map: %s", warning.c_str());
    }
    RCLCPP_INFO(
      get_logger(),
      "tag map: %zu boards, survey accuracy %.3f m — the ceiling on everything downstream",
      map_.tags.size(), map_.survey.stated_accuracy);
  }

  // ── windowing ─────────────────────────────────────────────────────────────

  void onDetections(const ArucoDetectionArray & msg)
  {
    const rclcpp::Time stamp(msg.header.stamp);
    // Clock skew, not physics. A stamp from the future cannot be
    // motion-compensated sensibly, so drop it rather than guess.
    if ((stamp - now()).seconds() > max_future_stamp_) {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 5000, "dropped a detection stamped %.3f s in the future",
        (stamp - now()).seconds());
      return;
    }
    pending_.push_back(msg);
  }

  void processWindow()
  {
    if (pending_.empty()) {
      report(WindowOutcome{}, SolveResult{}, IntegrityReport{});
      return;
    }

    std::vector<ArucoDetectionArray> window;
    window.swap(pending_);

    // Reference stamp for the window: the latest capture in it. Everything else
    // is rolled forward to here.
    rclcpp::Time reference(window.front().header.stamp);
    for (const auto & msg : window) {
      const rclcpp::Time t(msg.header.stamp);
      if (t > reference) {
        reference = t;
      }
    }

    std::vector<BoardObservation> boards;
    for (const auto & msg : window) {
      appendObservations(msg, reference, &boards);
    }

    if (boards.empty()) {
      report(WindowOutcome{}, SolveResult{}, IntegrityReport{});
      return;
    }

    // Boards already excluded by integrity monitoring stay out.
    boards.erase(
      std::remove_if(
        boards.begin(), boards.end(),
        [this](const BoardObservation & b) {return integrity_.isFlagged(b.id);}),
      boards.end());

    solveAndPublish(boards, reference);
  }

  void appendObservations(
    const ArucoDetectionArray & msg, const rclcpp::Time & reference,
    std::vector<BoardObservation> * out)
  {
    Eigen::Isometry3d base_to_cam;
    try {
      const auto tf = tf_buffer_.lookupTransform(
        "base_link", msg.header.frame_id, tf2::TimePointZero);
      base_to_cam = tf2::transformToEigen(tf);
    } catch (const tf2::TransformException & e) {
      // Named, not swallowed. The vehicle URDF is currently missing the
      // camera optical frames entirely, so this is the failure a fresh
      // deployment hits first.
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 5000,
        "no transform base_link <- %s, dropping its detections: %s",
        msg.header.frame_id.c_str(), e.what());
      return;
    }

    // Motion compensation: fold the vehicle's movement between this capture
    // and the window reference into the extrinsic, so every residual is
    // expressed against one pose.
    if (motion_compensation_ && latest_odom_) {
      const double dt = (reference - rclcpp::Time(msg.header.stamp)).seconds();
      base_to_cam = motionDelta(dt).inverse() * base_to_cam;
    }

    Eigen::Matrix3d k;
    k << msg.k[0], msg.k[1], msg.k[2], msg.k[3], msg.k[4], msg.k[5],
      msg.k[6], msg.k[7], msg.k[8];

    for (const auto & detection : msg.detections) {
      const auto entry = map_.tags.find(detection.id);
      if (entry == map_.tags.end()) {
        unmapped_.insert(detection.id);
        continue;  // never synthesize a pose for a board we do not know
      }

      BoardObservation board;
      board.id = detection.id;
      board.camera = msg.header.frame_id;
      board.map_to_tag = entry->second.pose;
      board.marker_size = entry->second.marker_size;
      board.position_stddev = entry->second.position_stddev;
      board.base_to_cam = base_to_cam;
      board.k = k;
      for (std::size_t c = 0; c < kNumCorners; ++c) {
        board.pixels[c] = Eigen::Vector2d{
          detection.corners_rectified[2 * c], detection.corners_rectified[2 * c + 1]};
      }
      tf2::fromMsg(detection.pose_1, board.cam_to_tag_1);
      tf2::fromMsg(detection.pose_2, board.cam_to_tag_2);
      board.error_1 = detection.reprojection_error_1;
      board.error_2 = detection.reprojection_error_2;

      if (board.range() > max_range_) {
        ++rejected_range_;
        continue;
      }

      // The view-angle window. Declared, cross-validated at startup, and then
      // never applied to a single observation until now -- so the gate the
      // design leans on hardest did not exist.
      //
      // It matters more than the ambiguity ratio, which is the intuitive
      // candidate for this job and cannot do it: phase 3D-5 measured the ratio
      // reporting maximum confidence at exactly the fronto-parallel geometry
      // where orientation is least reliable, because the twin solution is not
      // yet distinct enough to act as a rival. Only the geometry itself says
      // this board should not be trusted for orientation.
      const double view_angle = board.viewAngleDeg();
      if (view_angle < min_view_angle_deg_ || view_angle > max_view_angle_deg_) {
        ++rejected_view_angle_;
        RCLCPP_DEBUG(
          get_logger(), "board %u rejected: view angle %.1f deg outside [%.1f, %.1f]",
          board.id, view_angle, min_view_angle_deg_, max_view_angle_deg_);
        continue;
      }

      out->push_back(board);
    }
  }

  Eigen::Isometry3d motionDelta(double dt) const
  {
    Eigen::Isometry3d delta = Eigen::Isometry3d::Identity();
    if (!latest_odom_) {
      return delta;
    }
    const auto & twist = latest_odom_->twist.twist;
    delta.translation() = Eigen::Vector3d{twist.linear.x * dt, twist.linear.y * dt, 0.0};
    delta.linear() =
      Eigen::AngleAxisd(twist.angular.z * dt, Eigen::Vector3d::UnitZ()).toRotationMatrix();
    return delta;
  }

  // ── solve ─────────────────────────────────────────────────────────────────

  void solveAndPublish(
    const std::vector<BoardObservation> & boards, const rclcpp::Time & stamp)
  {
    const ConsensusResult consensus = resolveFlips(boards, consensus_options_);
    if (!consensus.ok) {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 2000, "no fix: %s", consensus.reason.c_str());
      report(WindowOutcome{}, SolveResult{}, IntegrityReport{});
      return;
    }

    SolveOptions options = solve_options_;
    if (isMoving()) {
      options.corner_sigma_px = corner_sigma_px_moving_;
    }
    // One board cannot be believed on orientation: about 12 degrees of jitter.
    // Hold the prior's heading and solve position only.
    options.dof = (consensus.members.size() >= 2) ? 6 : 3;

    SolveResult result = solvePose(boards, consensus.members, consensus.seed, options);
    if (!result.ok) {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 2000, "solve failed: %s", result.reason.c_str());
      report(WindowOutcome{}, result, IntegrityReport{});
      return;
    }

    // The number the integrity monitor actually judges. Worth having at hand:
    // "board N excluded" is not diagnosable without knowing what its residual
    // was and what its neighbours' were.
    {
      std::string line;
      for (const auto & [id, r] : result.board_residual_px) {
        line += " " + std::to_string(id) + "=" + std::to_string(r);
      }
      RCLCPP_DEBUG(get_logger(), "per-board residual px:%s", line.c_str());
    }
    // Boards consensus threw out never reach the solve, so they never appear
    // in board_residual_px. Tell the monitor about them separately or they stay
    // invisible however wrong they are.
    for (const auto id : consensus.outliers) {
      integrity_.noteConsensusOutlier(id);
    }
    const IntegrityReport integrity = integrity_.update(result.board_residual_px);
    for (const auto id : integrity.flagged) {
      if (announced_.insert(id).second) {
        RCLCPP_ERROR(
          get_logger(),
          "board %u is persistently inconsistent with its neighbours and has been "
          "excluded. Go and inspect that physical board: it has probably moved, or "
          "its map entry is wrong.", id);
      }
    }

    WindowOutcome outcome;
    outcome.solved = true;
    outcome.boards_used = result.observability.boards;
    outcome.normal_spread_deg = result.observability.normal_spread_deg;
    outcome.integrity_checked = integrity.checked;
    // Not `!flagged.empty()`. A flagged board has already been dropped from the
    // solve, and the fix continues without it -- that is redundancy working.
    // Faulting on it would stop the vehicle the first time the monitor
    // succeeded. What warrants a stop is being unable to isolate the problem.
    outcome.integrity_failed = integrity.isolation_failed;

    if (result.observability.condition_number > max_condition_number_) {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 2000,
        "constellation ill-conditioned (%.1e); publishing with saturated covariance",
        result.observability.condition_number);
    }

    publishPose(result, stamp);
    maybeInitialize(result, boards, stamp);
    report(outcome, result, integrity);
  }

  bool isMoving() const
  {
    if (!latest_odom_) {
      return false;
    }
    return std::abs(latest_odom_->twist.twist.linear.x) > 0.1;
  }

  void publishPose(const SolveResult & result, const rclcpp::Time & stamp)
  {
    geometry_msgs::msg::PoseWithCovarianceStamped msg;
    msg.header.stamp = stamp;   // the SENSOR stamp, not now()
    msg.header.frame_id = map_.frame_id;
    msg.pose.pose = tf2::toMsg(result.pose);
    for (int r = 0; r < 6; ++r) {
      for (int c = 0; c < 6; ++c) {
        msg.pose.covariance[6 * r + c] = result.covariance(r, c);
      }
    }
    pose_publisher_->publish(msg);
  }

  /// Cold start. Nothing NDT-refines the seed any more, so the first
  /// well-conditioned solve is the answer — but the gates are strict, because
  /// one bad initialization is worse than none.
  void maybeInitialize(
    const SolveResult & result, const std::vector<BoardObservation> & used,
    const rclcpp::Time & stamp)
  {
    // "Initialized" means the FILTER took it, not that we sent it.
    //
    // Publishing once and latching the flag is not enough, and transient-local
    // durability does not rescue it: a latched sample is only replayed to a
    // subscriber that also asks for transient-local, and the EKF's
    // subscription is volatile. So an initial pose sent before the EKF is
    // listening is simply lost, the filter waits forever for a pose that was
    // already sent, and every node in the graph reports healthy while nothing
    // downstream ever produces a fused pose.
    //
    // Evidence that it landed is odometry coming back from the filter. Until
    // that arrives, keep offering the pose at the cooldown interval.
    if (initialized_ && latest_odom_) {
      return;
    }
    if (initialized_ && !latest_odom_) {
      if (last_init_publish_ && (stamp - *last_init_publish_).seconds() < init_cooldown_s_) {
        return;
      }
      RCLCPP_WARN(
        get_logger(),
        "no odometry back from the filter %.0f s after sending the initial pose; "
        "re-sending. If this repeats, the EKF is not receiving /initialpose3d.",
        init_cooldown_s_);
      initialized_ = false;
    }

    // `initialization.max_range` and `initialization.max_view_angle_deg` were
    // declared and then never read: the config advertised a stricter cold-start
    // gate than the code applied, so initialization ran on the ordinary
    // tracking gates while appearing to be guarded. Applied here now.
    //
    // They are counted rather than used to filter, because a solve is a joint
    // fit over every board that went into it -- dropping one after the fact
    // would leave a pose that no longer corresponds to the boards being
    // checked. The question asked is "were there enough close, well-angled
    // boards in this solve", not "re-solve without the far ones".
    std::size_t close_and_square = 0;
    for (const auto & board : used) {
      if (board.range() <= init_max_range_ &&
        board.viewAngleDeg() <= init_max_view_angle_deg_)
      {
        ++close_and_square;
      }
    }

    const bool enough_boards =
      close_and_square >= static_cast<std::size_t>(init_min_boards_);
    const bool enough_spread = result.observability.normal_spread_deg >= init_min_spread_deg_;
    const bool conditioned = result.observability.condition_number <= init_max_condition_;

    if (!enough_boards || !enough_spread || !conditioned) {
      init_agreeing_.clear();
      // Say why. A cold start that silently never happens is the hardest kind
      // of failure to diagnose: every node is up, detections flow, and the only
      // symptom is that nothing downstream ever produces a pose.
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 5000,
        "not initializing yet: %zu of %zu boards within %.1f m and %.0f deg "
        "(need %d), spread %.1f deg (need %.1f), condition %.1e (limit %.1e)",
        close_and_square, used.size(), init_max_range_, init_max_view_angle_deg_,
        init_min_boards_, result.observability.normal_spread_deg, init_min_spread_deg_,
        result.observability.condition_number, init_max_condition_);
      return;
    }

    init_agreeing_.push_back({stamp, result.pose.translation()});
    if (static_cast<int>(init_agreeing_.size()) < init_consecutive_) {
      return;
    }
    while (static_cast<int>(init_agreeing_.size()) > init_consecutive_) {
      init_agreeing_.pop_front();
    }

    // Multi-frame agreement is the important gate: a single well-conditioned
    // solve can still be wrong, several in a row landing in the same place is
    // much harder to fake.
    Eigen::Vector3d mean = Eigen::Vector3d::Zero();
    for (const auto & sample : init_agreeing_) {
      mean += sample.position;
    }
    mean /= static_cast<double>(init_agreeing_.size());

    // The allowance has to grow with how long the samples span, because the
    // vehicle may be MOVING. A fixed radius applied to a moving vehicle
    // measures travel, not disagreement: at 1 m/s five windows cover half a
    // metre, which is the entire budget, so a perfectly consistent cold start
    // fails for driving forward. The gate is meant to catch solves that
    // disagree with each other, not solves taken at different places.
    const double span_s =
      (init_agreeing_.back().stamp - init_agreeing_.front().stamp).seconds();
    const double allowed = init_agreement_radius_ + init_max_speed_ * std::abs(span_s);
    for (const auto & sample : init_agreeing_) {
      if ((sample.position - mean).norm() > allowed) {
        RCLCPP_WARN_THROTTLE(
          get_logger(), *get_clock(), 5000,
          "not initializing yet: %d solves span %.2f m, above the %.2f m allowed "
          "over %.2f s", init_consecutive_, (sample.position - mean).norm(), allowed,
          span_s);
        return;
      }
    }

    if (last_init_publish_ && (stamp - *last_init_publish_).seconds() < init_cooldown_s_) {
      return;
    }

    geometry_msgs::msg::PoseWithCovarianceStamped msg;
    msg.header.stamp = stamp;
    msg.header.frame_id = map_.frame_id;
    msg.pose.pose = tf2::toMsg(result.pose);
    // Every diagonal entry, not just the three that seemed interesting.
    // Leaving z, roll and pitch at zero states them as EXACTLY known, and the
    // EKF will not activate on a pose it cannot invert -- which presents as an
    // initial pose that is published, accepted by nobody, and silently ignored
    // while the filter waits forever. It is the same rule the solver already
    // follows for its own covariance: never emit a zero variance.
    msg.pose.covariance[0] = 1.0;    // x   [m^2], honest and coarse
    msg.pose.covariance[7] = 1.0;    // y
    msg.pose.covariance[14] = 0.25;  // z, better constrained: the boards fix height
    msg.pose.covariance[21] = 0.05;  // roll  [rad^2]
    msg.pose.covariance[28] = 0.05;  // pitch
    msg.pose.covariance[35] = 0.1;   // yaw
    // Still published, for anything watching the estimator directly (rviz,
    // recordings, debugging). The service call is what actually initializes.
    initial_pose_publisher_->publish(msg);

    if (initialize_client_->service_is_ready()) {
      auto request =
        std::make_shared<autoware_localization_msgs::srv::InitializeLocalization::Request>();
      // DIRECT, not AUTO: AUTO asks the configured pose estimator to refine the
      // guess, and on this vehicle that estimator IS this node. Handing our own
      // answer back to ourselves for refinement is at best a no-op.
      request->method =
        autoware_localization_msgs::srv::InitializeLocalization::Request::DIRECT;
      request->pose_with_covariance.push_back(msg);
      initialize_client_->async_send_request(
        request,
        [this](rclcpp::Client<
          autoware_localization_msgs::srv::InitializeLocalization>::SharedFuture future) {
          const auto status = future.get()->status;
          if (!status.success) {
            RCLCPP_ERROR(
              get_logger(), "pose_initializer rejected our initial pose: %s",
              status.message.c_str());
          }
        });
    } else {
      RCLCPP_WARN_THROTTLE(
        get_logger(), *get_clock(), 5000,
        "/localization/initialize is not available; publishing the pose but nothing "
        "will act on it. Is pose_initializer running?");
    }

    last_init_publish_ = stamp;
    initialized_ = true;
    RCLCPP_INFO(
      get_logger(), "initialized from %zu boards, %.1f deg normal spread",
      result.observability.boards, result.observability.normal_spread_deg);
  }

  // ── reporting ─────────────────────────────────────────────────────────────

  /// Map the localization state onto diagnostic levels.
  ///
  /// DEGRADED is WARN rather than ERROR on purpose: position is still being
  /// corrected and only heading is running open-loop, so escalating it to ERROR
  /// would trip an MRM for a condition the vehicle is designed to drive
  /// through. DEAD_RECKONING is also WARN while inside its budget, and becomes
  /// ERROR when the budget expires -- the state machine has already made that
  /// decision, so this reads its verdict rather than re-deriving one.
  void diagnose(diagnostic_updater::DiagnosticStatusWrapper & status)
  {
    const auto & state = last_state_report_;

    std::uint8_t level = DiagnosticStatus::OK;
    if (state.request_mrm || state.state == LocalizationState::Fault) {
      level = DiagnosticStatus::ERROR;
    } else if (
      state.state == LocalizationState::Degraded ||
      state.state == LocalizationState::DeadReckoning)
    {
      level = DiagnosticStatus::WARN;
    } else if (state.state == LocalizationState::Uninitialized) {
      // Not an error: the vehicle has not been given an initial pose yet.
      level = DiagnosticStatus::WARN;
    }

    status.summary(level, toString(state.state) + ": " + state.reason);

    status.add("state", toString(state.state));
    status.add("boards_used", last_result_.observability.boards);
    status.add("normal_spread_deg", last_result_.observability.normal_spread_deg);
    status.add("condition_number", last_result_.observability.condition_number);
    status.add("reprojection_rms_px", last_result_.observability.reprojection_rms_px);
    status.add("integrity_checked", last_integrity_.checked);
    status.add("boards_excluded", last_integrity_.flagged.size());
    status.add("elapsed_without_fix_s", state.elapsed_s);
    status.add("budget_s", state.budget_s);
  }

  void report(
    const WindowOutcome & outcome, const SolveResult & result,
    const IntegrityReport & integrity)
  {
    const StateReport state = state_machine_.update(now().seconds(), outcome);
    // The diagnostic callback runs on the updater's own timer, not in this
    // window, so it needs the latest verdict rather than recomputing one.
    last_state_report_ = state;

    // A window can be empty simply because the timer ticked between camera
    // frames, and the state machine holds the previous state through that. If
    // we published zeroed metrics alongside a held NOMINAL, the status would
    // contradict itself -- "all good, zero boards, zero spread". Carry the last
    // real measurements instead, so the numbers always describe the fix the
    // state is talking about.
    const SolveResult & shown = outcome.solved ? result : last_result_;
    const IntegrityReport & shown_integrity = outcome.solved ? integrity : last_integrity_;
    if (outcome.solved) {
      last_result_ = result;
      last_integrity_ = integrity;
    }

    if (state.state != last_state_) {
      if (state.state == LocalizationState::Nominal) {
        RCLCPP_INFO(
          get_logger(), "localization %s: %s",
          toString(state.state).c_str(), state.reason.c_str());
      } else {
        RCLCPP_WARN(
          get_logger(), "localization %s: %s",
          toString(state.state).c_str(), state.reason.c_str());
      }
      last_state_ = state.state;
    }
    if (state.request_mrm && !mrm_requested_) {
      RCLCPP_ERROR(get_logger(), "requesting MRM stop: %s", state.reason.c_str());
      mrm_requested_ = true;
    }

    ArucoLocalizerStatus status;
    status.header.stamp = now();
    status.header.frame_id = map_.frame_id;
    status.state = static_cast<std::uint8_t>(state.state);
    status.dof_solved = shown.ok ? (shown.observability.boards >= 2 ? 6 : 3) : 0;
    status.integrity_checked = shown_integrity.checked;
    for (const auto & [id, residual] : shown.board_residual_px) {
      status.markers_used.push_back(id);
    }
    status.markers_flagged = shown_integrity.flagged;
    status.markers_unmapped.assign(unmapped_.begin(), unmapped_.end());
    status.normal_spread_deg = shown.observability.normal_spread_deg;
    status.depth_range_m = shown.observability.depth_range_m;
    status.condition_number = shown.observability.condition_number;
    status.reprojection_rms_px = shown.observability.reprojection_rms_px;
    status.dead_reckoning_elapsed_s = state.elapsed_s;
    status.dead_reckoning_budget_s = state.budget_s;
    status_publisher_->publish(status);
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
      outline.color.g = 0.6;
      outline.color.b = 0.6;
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
    }
    return array;
  }

  // ── state ─────────────────────────────────────────────────────────────────

  std::string tag_map_path_;
  TagMap map_;
  TagMapOptions map_options_;
  std::vector<std::string> camera_names_;

  SolveOptions solve_options_;
  ConsensusOptions consensus_options_;
  IntegrityOptions integrity_options_;
  StateOptions state_options_;

  double corner_sigma_px_moving_{};
  double window_duration_{};
  bool motion_compensation_{true};
  double max_future_stamp_{};
  double max_range_{};
  std::size_t rejected_range_{0};
  std::size_t rejected_view_angle_{0};
  double min_view_angle_deg_{};
  double max_view_angle_deg_{};
  double max_condition_number_{};

  int init_min_boards_{};
  double init_min_spread_deg_{};
  double init_max_range_{};
  double init_max_view_angle_deg_{};
  int init_consecutive_{};
  double init_agreement_radius_{};
  double init_max_speed_{};
  double init_max_condition_{};
  double init_cooldown_s_{};
  bool initialized_{false};
  /// A cold-start sample: where the solve put the vehicle, and when.
  ///
  /// The stamp is not decoration -- without it the agreement test cannot tell
  /// travel from disagreement.
  struct InitSample
  {
    rclcpp::Time stamp;
    Eigen::Vector3d position;
  };
  std::deque<InitSample> init_agreeing_;
  std::optional<rclcpp::Time> last_init_publish_;

  IntegrityMonitor integrity_;
  LocalizationStateMachine state_machine_;
  LocalizationState last_state_{LocalizationState::Uninitialized};
  SolveResult last_result_;
  IntegrityReport last_integrity_;
  bool mrm_requested_{false};
  std::set<std::uint32_t> unmapped_;
  std::set<std::uint32_t> announced_;

  std::vector<ArucoDetectionArray> pending_;
  std::optional<nav_msgs::msg::Odometry> latest_odom_;

  tf2_ros::Buffer tf_buffer_;
  tf2_ros::TransformListener tf_listener_;
  std::vector<rclcpp::Subscription<ArucoDetectionArray>::SharedPtr> detection_subs_;
  rclcpp::Subscription<nav_msgs::msg::Odometry>::SharedPtr kinematic_sub_;
  rclcpp::Publisher<visualization_msgs::msg::MarkerArray>::SharedPtr map_publisher_;
  rclcpp::Publisher<geometry_msgs::msg::PoseWithCovarianceStamped>::SharedPtr pose_publisher_;
  rclcpp::Publisher<geometry_msgs::msg::PoseWithCovarianceStamped>::SharedPtr
    initial_pose_publisher_;
  rclcpp::Client<autoware_localization_msgs::srv::InitializeLocalization>::SharedPtr
    initialize_client_;
  rclcpp::Publisher<ArucoLocalizerStatus>::SharedPtr status_publisher_;
  std::unique_ptr<diagnostic_updater::Updater> diagnostics_;
  StateReport last_state_report_;
  rclcpp::TimerBase::SharedPtr window_timer_;
};

}  // namespace golfcart::aruco_localizer

int main(int argc, char ** argv)
{
  rclcpp::init(argc, argv);
  try {
    rclcpp::spin(
      std::make_shared<golfcart::aruco_localizer::ArucoLocalizerNode>(rclcpp::NodeOptions{}));
  } catch (const std::exception & e) {
    RCLCPP_FATAL(rclcpp::get_logger("aruco_localizer"), "startup failed: %s", e.what());
    rclcpp::shutdown();
    return 1;
  }
  rclcpp::shutdown();
  return 0;
}
