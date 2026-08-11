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

#ifndef GOLFCART_ARUCO_LOCALIZER__OBSERVATION_HPP_
#define GOLFCART_ARUCO_LOCALIZER__OBSERVATION_HPP_

#include <golfcart_aruco_localizer/tag_frame.hpp>

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <cmath>

#include <array>
#include <cstdint>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

/// One board seen by one camera in one window.
///
/// Everything needed to form a residual is here, so the solver never reaches
/// back into the map or TF. That keeps it a pure function of its input, which
/// is what makes it testable without a running system.
struct BoardObservation
{
  std::uint32_t id{0};
  std::string camera;

  /// Board pose in the map, from the survey.
  Eigen::Isometry3d map_to_tag{Eigen::Isometry3d::Identity()};
  double marker_size{0.0};
  /// 1-sigma position uncertainty of the surveyed pose, metres.
  double position_stddev{0.0};

  /// Camera optical frame in base_link, from TF.
  Eigen::Isometry3d base_to_cam{Eigen::Isometry3d::Identity()};
  Eigen::Matrix3d k{Eigen::Matrix3d::Identity()};

  /// Measured corners in the rectified frame, in `Corner` order.
  std::array<Eigen::Vector2d, kNumCorners> pixels{};

  /// The two candidate board poses in the camera frame, best first.
  Eigen::Isometry3d cam_to_tag_1{Eigen::Isometry3d::Identity()};
  Eigen::Isometry3d cam_to_tag_2{Eigen::Isometry3d::Identity()};
  double error_1{0.0};
  double error_2{0.0};

  /// Ambiguity metric in (0, 1]. Near 1 the board cannot resolve its own
  /// orientation. Infinite `error_2` means only one distinct solution existed,
  /// which is unambiguous, so the ratio is zero.
  double ambiguityRatio() const
  {
    if (!std::isfinite(error_2) || error_2 <= 0.0) {
      return 0.0;
    }
    return error_1 / error_2;
  }

  /// Vehicle pose implied by this board and one of its two solutions:
  ///   T_map_base = T_map_tag * (T_base_cam * T_cam_tag)^-1
  Eigen::Isometry3d impliedVehiclePose(int solution) const
  {
    const Eigen::Isometry3d & cam_to_tag = (solution == 0) ? cam_to_tag_1 : cam_to_tag_2;
    return map_to_tag * (base_to_cam * cam_to_tag).inverse();
  }

  /// Outward normal of the board in the map frame. Its spread across the
  /// visible boards is the statistic that actually predicts solve quality.
  Eigen::Vector3d normalInMap() const {return map_to_tag.linear().col(2);}

  /// Range from the camera to the board centre.
  double range() const {return cam_to_tag_1.translation().norm();}

  /// Angle between the line of sight and the board normal, in degrees.
  ///
  /// 0 is fronto-parallel — looking straight at the board — and that is the
  /// WORST case for orientation, not the best. The two planar pose solutions
  /// merge there, and phase 3D-5 measured single-marker rotation error peaking
  /// at fronto-parallel and improving monotonically with tilt.
  ///
  /// Returns 180 for a board facing away from the camera, so such a board fails
  /// any upper gate rather than sneaking through with a small angle.
  double viewAngleDeg() const
  {
    const Eigen::Vector3d normal_in_cam = cam_to_tag_1.linear().col(2);
    const Eigen::Vector3d line_of_sight = cam_to_tag_1.translation().normalized();
    const double cos_phi = -normal_in_cam.dot(line_of_sight);
    if (cos_phi <= 0.0) {
      return 180.0;
    }
    return std::acos(std::min(1.0, cos_phi)) * 180.0 / M_PI;
  }
};

/// How well the visible constellation constrains the pose.
///
/// Reported every solve. Note what is deliberately not here: a quality ranking
/// based on reprojection RMS. That statistic inverts — degenerate captures
/// score better on it than usable ones — so it is reported for diagnosis and
/// never ranked on. Normal spread is the one that separates on real data, and
/// the only one that tells an operator what to physically change.
struct Observability
{
  std::size_t boards{0};
  double normal_spread_deg{0.0};
  double depth_range_m{0.0};
  double condition_number{0.0};
  double reprojection_rms_px{0.0};
};

/// Largest pairwise angle between board normals, degrees.
///
/// Uses |dot| so a board whose normal happens to point away does not read as
/// 180 degrees of spread when it is really parallel.
double normalSpreadDeg(const std::vector<BoardObservation> & boards);

/// Spread of camera-to-board ranges, metres.
double depthRange(const std::vector<BoardObservation> & boards);

}  // namespace golfcart::aruco_localizer

#endif  // GOLFCART_ARUCO_LOCALIZER__OBSERVATION_HPP_
