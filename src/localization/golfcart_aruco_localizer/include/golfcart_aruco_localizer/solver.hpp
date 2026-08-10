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

#ifndef GOLFCART_ARUCO_LOCALIZER__SOLVER_HPP_
#define GOLFCART_ARUCO_LOCALIZER__SOLVER_HPP_

#include <golfcart_aruco_localizer/observation.hpp>

#include <Eigen/Core>
#include <Eigen/Geometry>

#include <cstdint>
#include <map>
#include <vector>

namespace golfcart::aruco_localizer
{

// ── stage one: flip consensus ───────────────────────────────────────────────

struct ConsensusOptions
{
  double position_tolerance{0.5};       // [m]
  double rotation_tolerance_deg{10.0};  // [deg]
  /// Reject a lone board whose two solutions fit about equally well.
  double ambiguity_ratio_max{0.2};
};

struct ConsensusResult
{
  bool ok{false};
  /// Two clusters of equal size. Expected when the visible boards are
  /// coplanar — their flips agree with each other as well as the correct
  /// solutions do — so publishing either would be a coin flip with a confident
  /// covariance attached.
  bool tie{false};
  Eigen::Isometry3d seed{Eigen::Isometry3d::Identity()};
  /// Index into the input vector, and which solution (0 or 1) won for it.
  std::vector<std::pair<std::size_t, int>> members;
  /// Boards whose neither solution joined the winning cluster.
  std::vector<std::uint32_t> outliers;
  std::string reason;
};

/// Resolve each board's two-fold ambiguity by agreement across boards.
///
/// Every board watches the same vehicle, so the correct solutions land on one
/// pose and pile up, while the wrong ones scatter — each board's flip reflects
/// about a plane through its own line of sight, a different transformation per
/// board.
///
/// No prior pose enters this, which is what makes cold start possible. Never
/// resolve the flip by picking the candidate nearest a prior: that is how an
/// estimator ends up confirming what the filter already believes.
ConsensusResult resolveFlips(
  const std::vector<BoardObservation> & boards, const ConsensusOptions & options = {});

// ── stage two: the joint solve ──────────────────────────────────────────────

struct SolveOptions
{
  double corner_sigma_px{0.3};
  double huber_delta_px{2.0};
  int max_iterations{30};
  double convergence_tolerance{1.0e-8};
  /// Caps for directions the geometry cannot see.
  double max_position_variance{100.0};  // [m^2]
  double max_rotation_variance{1.0};    // [rad^2]
  /// 6 solves the full pose; 3 solves position only, holding orientation at
  /// the seed. The 3-DoF path exists for a lone board, whose orientation
  /// carries about 12 degrees of jitter and must not be believed.
  int dof{6};
};

struct SolveResult
{
  bool ok{false};
  Eigen::Isometry3d pose{Eigen::Isometry3d::Identity()};
  Eigen::Matrix<double, 6, 6> covariance{Eigen::Matrix<double, 6, 6>::Identity()};
  /// Normalized residual per degree of freedom -- a check on the noise model,
  /// not a scale factor on the covariance. Near 1 means the assumed corner
  /// noise matches reality; far above means it is optimistic or a board is
  /// wrong.
  double sigma_hat_sq{0.0};
  int iterations{0};
  Observability observability;
  /// Worst-corner reprojection residual per board, pixels. This is what the
  /// integrity monitor watches: a board that has moved or been mistyped shows
  /// a persistently large value while its neighbours stay small.
  std::map<std::uint32_t, double> board_residual_px;
  std::string reason;
};

/// Joint least squares for the vehicle pose over every corner of every board
/// of every camera.
///
/// Solving on corners rather than averaging per-board poses is the whole point:
/// corner error is close to independent and isotropic in pixels, so least
/// squares on corners is the maximum-likelihood estimate, and the range
/// anisotropy falls out of the Jacobian rather than needing a model. Averaging
/// poses instead would need a correct 6x6 weight per board, which is exactly
/// what no good model exists for.
///
/// `flips` selects which of each board's two solutions to believe, as returned
/// by `resolveFlips`. `seed` is the starting estimate.
SolveResult solvePose(
  const std::vector<BoardObservation> & boards,
  const std::vector<std::pair<std::size_t, int>> & flips,
  const Eigen::Isometry3d & seed, const SolveOptions & options = {});

// ── exposed for testing ─────────────────────────────────────────────────────

/// Skew-symmetric matrix, so that a x b == skew(a) * b.
Eigen::Matrix3d skew(const Eigen::Vector3d & v);

/// Exponential map from a 6-vector increment (translation, rotation) to SE(3).
Eigen::Isometry3d expSe3(const Eigen::Matrix<double, 6, 1> & xi);

/// Invert J^T W J per eigendirection, capping unobservable ones.
///
/// A near-singular information matrix is a RESULT, not an error: it is what an
/// unobservable direction looks like. Inverting it whole either throws or
/// explodes, and emitting a zero variance is worse than either, because
/// downstream reads zero as "exact" and nothing here can contradict it.
/// `scale` is 1.0 in normal use, because the weight matrix already carries the
/// measurement noise; it is a parameter only so the saturation behaviour can be
/// tested directly.
Eigen::Matrix<double, 6, 6> saturatedCovariance(
  const Eigen::Matrix<double, 6, 6> & information, double scale,
  double max_position_variance, double max_rotation_variance);

}  // namespace golfcart::aruco_localizer

#endif  // GOLFCART_ARUCO_LOCALIZER__SOLVER_HPP_
