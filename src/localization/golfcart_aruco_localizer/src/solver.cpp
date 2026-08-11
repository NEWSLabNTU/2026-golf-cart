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

#include <golfcart_aruco_localizer/solver.hpp>

#include <Eigen/Eigenvalues>

#include <algorithm>
#include <cmath>
#include <limits>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace golfcart::aruco_localizer
{

// ── small helpers ───────────────────────────────────────────────────────────

Eigen::Matrix3d skew(const Eigen::Vector3d & v)
{
  Eigen::Matrix3d m;
  m << 0.0, -v.z(), v.y(),
    v.z(), 0.0, -v.x(),
    -v.y(), v.x(), 0.0;
  return m;
}

Eigen::Isometry3d expSe3(const Eigen::Matrix<double, 6, 1> & xi)
{
  const Eigen::Vector3d translation = xi.head<3>();
  const Eigen::Vector3d rotation = xi.tail<3>();
  const double angle = rotation.norm();

  Eigen::Isometry3d out = Eigen::Isometry3d::Identity();
  out.linear() = (angle < 1e-12)
    ? Eigen::Matrix3d::Identity()
    : Eigen::AngleAxisd(angle, rotation / angle).toRotationMatrix();
  // Small increments only, so the translation is applied directly rather than
  // through the left Jacobian. The optimizer re-linearizes each iteration, so
  // the approximation costs a fraction of an iteration, not accuracy.
  out.translation() = translation;
  return out;
}

/// Mean distance from camera to board. Used as the characteristic lever that
/// makes the information matrix dimensionally consistent.
double meanRange(const std::vector<BoardObservation> & used)
{
  if (used.empty()) {
    return 0.0;
  }
  double sum = 0.0;
  for (const auto & b : used) {
    sum += b.cam_to_tag_1.translation().norm();
  }
  return sum / static_cast<double>(used.size());
}


double normalSpreadDeg(const std::vector<BoardObservation> & boards)
{
  double worst = 0.0;
  for (std::size_t i = 0; i < boards.size(); ++i) {
    for (std::size_t j = i + 1; j < boards.size(); ++j) {
      // SIGNED, not |dot|. Two boards on facing walls have opposite normals,
      // and that is the most informative geometry available -- a yaw error
      // swings them in opposite senses, which is exactly what makes heading
      // observable. Taking the absolute value scored that case as ZERO spread,
      // identical to two boards side by side on one wall, and the effect was
      // not academic: a corridor with facing pairs could not cold-start,
      // because every solve reported 0.0 deg against a 20 deg requirement.
      //
      // The abs() was there to guard the flip degeneracy of parallel planes.
      // That is a real concern, but it is not this function's job and this
      // function cannot do it: resolveFlips already detects a tied consensus
      // between two equal clusters and refuses to publish. Conditioning is
      // measured separately by the condition number. Three problems, three
      // mechanisms.
      const double d = boards[i].normalInMap().dot(boards[j].normalInMap());
      worst = std::max(worst, std::acos(std::clamp(d, -1.0, 1.0)));
    }
  }
  return worst * 180.0 / M_PI;
}

double depthRange(const std::vector<BoardObservation> & boards)
{
  if (boards.empty()) {
    return 0.0;
  }
  double lo = std::numeric_limits<double>::max();
  double hi = 0.0;
  for (const auto & b : boards) {
    lo = std::min(lo, b.range());
    hi = std::max(hi, b.range());
  }
  return hi - lo;
}

// ── stage one: consensus ────────────────────────────────────────────────────

ConsensusResult resolveFlips(
  const std::vector<BoardObservation> & boards, const ConsensusOptions & options)
{
  ConsensusResult out;
  if (boards.empty()) {
    out.reason = "no boards";
    return out;
  }

  if (boards.size() == 1) {
    // Nothing to agree with. The only defence is the board's own ambiguity
    // metric; there is no threshold that rescues a lone board's orientation.
    const double ratio = boards[0].ambiguityRatio();
    if (ratio > options.ambiguity_ratio_max) {
      out.reason = "single board, ambiguous (ratio " + std::to_string(ratio) + ")";
      return out;
    }
    out.ok = true;
    out.members = {{0, 0}};
    out.seed = boards[0].impliedVehiclePose(0);
    return out;
  }

  // Every (board, solution) pair votes for a complete vehicle pose.
  struct Candidate
  {
    std::size_t board;
    int solution;
    Eigen::Isometry3d pose;
  };
  std::vector<Candidate> candidates;
  candidates.reserve(boards.size() * 2);
  for (std::size_t i = 0; i < boards.size(); ++i) {
    candidates.push_back({i, 0, boards[i].impliedVehiclePose(0)});
    candidates.push_back({i, 1, boards[i].impliedVehiclePose(1)});
  }

  const double rotation_tolerance = options.rotation_tolerance_deg * M_PI / 180.0;

  // These tolerances look loose for a gate whose job is to separate a true pose
  // from its flip, and they are not. Measured over the view-angle window this
  // node admits, two boards at 5.5 m disagree by 0.27 m and 2.8 deg at the 99th
  // percentile under 0.3 px of corner noise; a flip puts them tens of metres and
  // tens of degrees apart. There is a wide gap between the two, and the gate
  // sits in it.
  //
  // Do NOT widen these to chase intermittent "no two boards agree". That symptom
  // comes from too few boards surviving the ambiguity gate, not from good boards
  // failing to agree, and widening trades a stalled fix for a confidently wrong
  // one. See max_range.
  auto agrees = [&](const Candidate & a, const Candidate & b) {
      if ((a.pose.translation() - b.pose.translation()).norm() > options.position_tolerance) {
        return false;
      }
      return Eigen::AngleAxisd(a.pose.linear().transpose() * b.pose.linear()).angle() <
             rotation_tolerance;
    };

  // Grow a cluster about each candidate, at most one solution per board: a
  // board cannot corroborate itself.
  std::vector<std::vector<std::size_t>> clusters(candidates.size());
  for (std::size_t seed = 0; seed < candidates.size(); ++seed) {
    std::vector<bool> board_used(boards.size(), false);
    for (std::size_t j = 0; j < candidates.size(); ++j) {
      if (board_used[candidates[j].board]) {
        continue;
      }
      if (agrees(candidates[seed], candidates[j])) {
        clusters[seed].push_back(j);
        board_used[candidates[j].board] = true;
      }
    }
  }

  std::size_t best = 0;
  for (std::size_t i = 1; i < clusters.size(); ++i) {
    if (clusters[i].size() > clusters[best].size()) {
      best = i;
    }
  }
  const std::size_t best_size = clusters[best].size();

  if (best_size < 2) {
    out.reason = "no two boards agree";
    return out;
  }

  // A rival cluster of the same size, made of different boards, means the
  // geometry cannot distinguish. Coplanar boards flip together, so their wrong
  // solutions agree with each other exactly as well as the right ones do.
  for (std::size_t i = 0; i < clusters.size(); ++i) {
    if (clusters[i].size() != best_size || i == best) {
      continue;
    }
    if (!agrees(candidates[i], candidates[best])) {
      out.tie = true;
      out.reason =
        "flip consensus tied between two equal clusters — the visible boards are "
        "probably coplanar, so their flips agree; publishing either would be a guess";
      return out;
    }
  }

  Eigen::Vector3d centroid = Eigen::Vector3d::Zero();
  std::vector<bool> in_cluster(boards.size(), false);
  for (const auto idx : clusters[best]) {
    out.members.emplace_back(candidates[idx].board, candidates[idx].solution);
    centroid += candidates[idx].pose.translation();
    in_cluster[candidates[idx].board] = true;
  }
  centroid /= static_cast<double>(clusters[best].size());

  for (std::size_t i = 0; i < boards.size(); ++i) {
    if (!in_cluster[i]) {
      out.outliers.push_back(boards[i].id);
    }
  }

  out.seed = candidates[clusters[best].front()].pose;
  out.seed.translation() = centroid;
  out.ok = true;
  return out;
}

// ── stage two: the joint solve ──────────────────────────────────────────────

namespace
{

/// One corner's contribution: residual and its 2x6 Jacobian block.
struct CornerTerm
{
  Eigen::Vector2d residual;
  Eigen::Matrix<double, 2, 6> jacobian;
  bool valid{false};
};

CornerTerm cornerTerm(
  const BoardObservation & board, std::size_t corner, const Eigen::Isometry3d & map_to_base)
{
  CornerTerm term;

  const Eigen::Vector3d point_map =
    board.map_to_tag * tagLocalCorners(board.marker_size)[corner];
  const Eigen::Vector3d y = map_to_base.inverse() * point_map;   // base_link
  const Eigen::Vector3d x = board.base_to_cam.inverse() * y;     // camera optical

  if (x.z() <= 1e-6) {
    return term;  // behind the camera
  }

  const double fx = board.k(0, 0);
  const double fy = board.k(1, 1);
  const double cx = board.k(0, 2);
  const double cy = board.k(1, 2);

  term.residual = Eigen::Vector2d{
    fx * x.x() / x.z() + cx - board.pixels[corner].x(),
    fy * x.y() / x.z() + cy - board.pixels[corner].y()};

  // Chain rule, three links (see the design document, section 6.3):
  //   d pi / d X          projection
  //   d X  / d Y  = R_cb  a fixed rotation
  //   d Y  / d xi = [-I3, [Y]x]
  Eigen::Matrix<double, 2, 3> d_pi;
  d_pi << fx / x.z(), 0.0, -fx * x.x() / (x.z() * x.z()),
    0.0, fy / x.z(), -fy * x.y() / (x.z() * x.z());

  Eigen::Matrix<double, 3, 6> d_y;
  d_y.leftCols<3>() = -Eigen::Matrix3d::Identity();
  d_y.rightCols<3>() = skew(y);

  term.jacobian = d_pi * board.base_to_cam.linear().transpose() * d_y;
  term.valid = true;
  return term;
}

}  // namespace

Eigen::Matrix<double, 6, 6> saturatedCovariance(
  const Eigen::Matrix<double, 6, 6> & information, double scale,
  double max_position_variance, double max_rotation_variance)
{
  Eigen::SelfAdjointEigenSolver<Eigen::Matrix<double, 6, 6>> solver(information);
  const Eigen::Matrix<double, 6, 6> v = solver.eigenvectors();
  const Eigen::Matrix<double, 6, 1> lambda = solver.eigenvalues();

  Eigen::Matrix<double, 6, 1> variance;
  for (int k = 0; k < 6; ++k) {
    // An eigenvector mixes translation and rotation, so the cap is blended by
    // how much of each it carries. Using one cap for all six would either let
    // a rotation variance run to 100 rad^2 or clamp position at 1 m^2.
    const double translation_weight = v.col(k).head<3>().squaredNorm();
    const double cap = translation_weight * max_position_variance +
      (1.0 - translation_weight) * max_rotation_variance;
    const double raw = (lambda(k) > 1e-12)
      ? scale / lambda(k)
      : std::numeric_limits<double>::infinity();
    // Never zero: downstream reads a zero variance as "exact", and with one
    // pose source nothing contradicts it.
    variance(k) = std::min(std::max(raw, 1e-12), cap);
  }
  return v * variance.asDiagonal() * v.transpose();
}

SolveResult solvePose(
  const std::vector<BoardObservation> & boards,
  const std::vector<std::pair<std::size_t, int>> & flips,
  const Eigen::Isometry3d & seed, const SolveOptions & options)
{
  SolveResult out;
  if (flips.empty()) {
    out.reason = "no boards selected";
    return out;
  }

  // Only the boards the consensus accepted, each with its chosen flip already
  // baked into cam_to_tag_1 for the residual. The residual does not use
  // cam_to_tag at all, but the flip decides which boards are trusted.
  std::vector<BoardObservation> used;
  used.reserve(flips.size());
  for (const auto & [index, solution] : flips) {
    BoardObservation b = boards.at(index);
    if (solution == 1) {
      std::swap(b.cam_to_tag_1, b.cam_to_tag_2);
      std::swap(b.error_1, b.error_2);
    }
    used.push_back(b);
  }

  const std::size_t corner_count = used.size() * kNumCorners;
  const int parameters = (options.dof == 3) ? 3 : 6;
  const int residual_count = static_cast<int>(2 * corner_count);
  if (residual_count <= parameters) {
    out.reason = "under-determined";
    return out;
  }

  Eigen::Isometry3d pose = seed;
  const double inv_variance = 1.0 / (options.corner_sigma_px * options.corner_sigma_px);

  double last_cost = std::numeric_limits<double>::max();
  double lambda = 1e-4;
  Eigen::Matrix<double, 6, 6> information = Eigen::Matrix<double, 6, 6>::Zero();
  double sum_squared = 0.0;           // pixels^2, for the reported RMS
  double sum_normalized = 0.0;        // weighted, for the noise-model check

  for (int iteration = 0; iteration < options.max_iterations; ++iteration) {
    Eigen::Matrix<double, 6, 6> jtj = Eigen::Matrix<double, 6, 6>::Zero();
    Eigen::Matrix<double, 6, 1> jtr = Eigen::Matrix<double, 6, 1>::Zero();
    double cost = 0.0;
    sum_squared = 0.0;
    sum_normalized = 0.0;
    out.board_residual_px.clear();

    for (const auto & board : used) {
      // Survey uncertainty, propagated to pixels: a board whose measured pose
      // is uncertain should count for less. This treats the four corners as
      // independent, which slightly over-trusts a badly surveyed board — they
      // actually share one pose and their map errors are perfectly correlated.
      // Approximation, deliberately, and noted in the design.
      const double range = std::max(board.range(), 1e-3);
      const double map_px = board.k(0, 0) * board.position_stddev / range;
      const double weight = 1.0 / (1.0 / inv_variance + map_px * map_px);

      std::array<CornerTerm, kNumCorners> terms;
      double board_squared = 0.0;
      double board_worst = 0.0;
      bool board_ok = true;
      for (std::size_t c = 0; c < kNumCorners; ++c) {
        terms[c] = cornerTerm(board, c, pose);
        if (!terms[c].valid) {
          board_ok = false;
          break;
        }
        board_squared += terms[c].residual.squaredNorm();
        board_worst = std::max(board_worst, terms[c].residual.norm());
      }
      if (!board_ok) {
        continue;
      }
      out.board_residual_px[board.id] = board_worst;
      sum_squared += board_squared;

      // Huber applied PER BOARD, over the sum of its four corners. A board
      // that has moved, or whose map entry is wrong, makes all four corners
      // wrong together; down-weighting per corner would let three bad corners
      // hide behind the fourth.
      const double board_error = std::sqrt(board_squared);
      const double delta = options.huber_delta_px * 2.0;  // 4 corners' worth
      const double robust = (board_error <= delta) ? 1.0 : delta / board_error;

      for (const auto & term : terms) {
        const double w = weight * robust;
        jtj += w * term.jacobian.transpose() * term.jacobian;
        jtr += w * term.jacobian.transpose() * term.residual;
        cost += w * term.residual.squaredNorm();
        sum_normalized += w * term.residual.squaredNorm();
      }
    }

    if (out.board_residual_px.empty()) {
      out.reason = "all boards projected behind the camera";
      return out;
    }
    information = jtj;

    // Levenberg-Marquardt damping, so a bad linearization cannot take a wild
    // step.
    Eigen::Matrix<double, 6, 6> damped = jtj;
    for (int i = 0; i < 6; ++i) {
      damped(i, i) += lambda * std::max(jtj(i, i), 1e-9);
    }

    Eigen::Matrix<double, 6, 1> step = Eigen::Matrix<double, 6, 1>::Zero();
    if (parameters == 6) {
      step = damped.ldlt().solve(-jtr);
    } else {
      // Position only: orientation stays at the seed. For a lone board that is
      // the honest choice, since its orientation carries about 12 degrees of
      // jitter and the prior is better than that.
      const Eigen::Matrix3d a = damped.topLeftCorner<3, 3>();
      step.head<3>() = a.ldlt().solve(-jtr.head<3>());
    }

    if (!step.allFinite()) {
      out.reason = "solve diverged";
      return out;
    }

    pose = pose * expSe3(step);
    out.iterations = iteration + 1;

    lambda = (cost < last_cost) ? std::max(lambda * 0.5, 1e-9) : std::min(lambda * 4.0, 1e6);
    last_cost = cost;
    if (step.norm() < options.convergence_tolerance) {
      break;
    }
  }

  const int dof_count = residual_count - parameters;

  // The weight matrix already carries the measurement noise -- 1/sigma_px^2
  // plus the board's survey uncertainty -- so the covariance is (J^T W J)^-1
  // directly. Scaling that by a variance re-estimated from the residuals as
  // well would count the noise twice, and worse, it collapses to zero whenever
  // the data happens to fit well. A handful of boards fitting cleanly is not
  // evidence that the pose is known to within nothing.
  //
  // sigma_hat_sq is kept as a DIAGNOSTIC: it is the normalized residual sum
  // per degree of freedom, so it sits near 1 when the assumed corner noise
  // matches reality. Far above 1 means corner_sigma_px is optimistic or a
  // board is wrong; far below means it is pessimistic. It does not scale the
  // covariance.
  out.sigma_hat_sq = sum_normalized / static_cast<double>(dof_count);
  out.covariance = saturatedCovariance(
    information, 1.0, options.max_position_variance, options.max_rotation_variance);

  // The condition number has to be taken on a NON-DIMENSIONALIZED information
  // matrix, and this is easy to get wrong in a way that produces a number which
  // looks fine and means nothing.
  //
  // The increment is xi = (dt, dtheta): three metres and three radians. A
  // condition number of a matrix whose blocks carry different units is not a
  // property of the geometry at all -- it changes if the translation is
  // expressed in centimetres, and no fixed threshold on it is meaningful. The
  // first version of this code compared the raw value against 1e4 and reported
  // "ill-conditioned" on nearly every window of a perfectly healthy fixture.
  //
  // Substituting dtheta = dtheta' / L, for a characteristic lever L, puts the
  // rotation block in metres of arc as well. The natural L is how far away the
  // boards are: that is exactly the lever by which an angular error becomes a
  // positional one.
  const double lever = std::max(meanRange(used), 1e-3);
  Eigen::Matrix<double, 6, 1> scale;
  scale << 1.0, 1.0, 1.0, 1.0 / lever, 1.0 / lever, 1.0 / lever;
  const Eigen::Matrix<double, 6, 6> scaled =
    scale.asDiagonal() * information * scale.asDiagonal();

  Eigen::SelfAdjointEigenSolver<Eigen::Matrix<double, 6, 6>> eigen(scaled);
  const double smallest = eigen.eigenvalues()(0);
  const double largest = eigen.eigenvalues()(5);
  out.observability.condition_number = (smallest > 1e-12)
    ? largest / smallest
    : std::numeric_limits<double>::infinity();
  out.observability.boards = used.size();
  out.observability.normal_spread_deg = normalSpreadDeg(used);
  out.observability.depth_range_m = depthRange(used);
  out.observability.reprojection_rms_px =
    std::sqrt(sum_squared / static_cast<double>(corner_count));

  out.pose = pose;
  out.ok = true;
  return out;
}

}  // namespace golfcart::aruco_localizer
