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
// Everything that decides whether a fix can be trusted. Phase 3D-4, stage two.

#ifndef GOLFCART_ARUCO_LOCALIZER__HEALTH_HPP_
#define GOLFCART_ARUCO_LOCALIZER__HEALTH_HPP_

#include <cstdint>
#include <map>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

// ── integrity: boards checked against each other ────────────────────────────

struct IntegrityOptions
{
  /// Smoothing on each board's residual ratio. Low values need a fault to
  /// persist before it shows.
  double ewma_alpha{0.2};
  /// How many times the cohort median a board may sit at before it counts as
  /// inconsistent.
  double flag_ratio{4.0};
  /// Consecutive inconsistent windows before the board is actually excluded.
  /// One bad frame is noise; ten in a row is a board that has moved.
  int flag_count{10};
  /// Floor on the cohort median, pixels. Without it a solve where everything
  /// fits perfectly would make ordinary sub-pixel scatter look like a fault.
  double median_floor_px{0.5};
  /// A board must ALSO exceed the cohort median by this many pixels in absolute
  /// terms before the ratio counts against it.
  ///
  /// The ratio alone is not enough, and the failure is not hypothetical: on a
  /// clean fixture with no fault injected, boards were being excluded and the
  /// vehicle sent to FAULT. Residuals legitimately differ between boards for
  /// reasons that are geometry, not health -- a board further away or seen more
  /// obliquely fits worse -- and when every residual is sub-pixel, one board at
  /// four times the median is still sub-pixel and still fine. Requiring a real
  /// number of pixels of disagreement separates "worse than its neighbours" from
  /// "wrong", which is the distinction the monitor exists to make.
  double flag_margin_px{1.5};
  /// How many boards may be excluded before the exclusions stop being credible
  /// as individual board faults. Past this the likelier explanation is
  /// something common to all of them -- extrinsics, marker size, map frame --
  /// and excluding boards one at a time is no longer a remedy.
  std::size_t max_excluded{2};
};

struct IntegrityReport
{
  /// Boards excluded from the solve because they are persistently inconsistent
  /// with their peers. Each of these is a maintenance event: go and look at
  /// that physical board.
  std::vector<std::uint32_t> flagged;
  /// False when there were too few boards to cross-check. An unchecked fix is
  /// a different thing from a checked one even when both look fine, and
  /// downstream is entitled to know which it received.
  bool checked{false};
  /// True when the monitor can no longer isolate the problem to particular
  /// boards, which is the condition that should stop the vehicle.
  ///
  /// Detecting a bad board and excluding it is a SUCCESS, not a failure: it is
  /// the whole point of having redundancy, and the solve continues on the
  /// remaining boards with the offender gone. Treating the first exclusion as a
  /// fault -- which this node did at first -- stops the vehicle at exactly the
  /// moment its integrity monitoring started working.
  bool isolation_failed{false};
  std::map<std::uint32_t, double> ratio;
};

/// Per-board residual monitoring, structured after GNSS RAIM.
///
/// The redundancy is *between boards*: with two or more visible the solve is
/// over-determined, so each board's post-solve residual is a statement about
/// whether it agrees with the others.
///
/// Boards are judged against the cohort median rather than an absolute
/// threshold. That distinction matters: if the whole solve is bad — wrong
/// calibration, wrong marker size, a map frame offset — every residual rises
/// together, and an absolute threshold would flag every board and exclude the
/// lot. Those are systematic faults that board-versus-board comparison cannot
/// see, and pretending otherwise would turn a calibration problem into a
/// cascade of spurious exclusions.
class IntegrityMonitor
{
public:
  explicit IntegrityMonitor(IntegrityOptions options = {})
  : options_(options) {}

  /// Feed one solve's per-board residuals. Returns which boards to exclude
  /// from the next solve.
  IntegrityReport update(const std::map<std::uint32_t, double> & residual_px);

  /// Record that a board was thrown out of the flip consensus.
  ///
  /// Such a board never reaches the solve, so it never produces a residual and
  /// `update()` never sees it. Without this it can disagree with its neighbours
  /// on every single frame and still be reported as healthy -- silently
  /// dropped, never named, and nobody is ever sent to look at it. Which is
  /// exactly what a board knocked off its mount looks like.
  void noteConsensusOutlier(std::uint32_t id);

  bool isFlagged(std::uint32_t id) const;
  /// Clear a board's history, for when someone has been out to fix it.
  void clear(std::uint32_t id);

private:
  IntegrityOptions options_;
  std::map<std::uint32_t, double> ewma_;
  std::map<std::uint32_t, int> strikes_;
  /// How many times each board has been offered to the outlier path, so a
  /// strike count can be judged as a proportion rather than a total.
  std::map<std::uint32_t, int> seen_;
  std::vector<std::uint32_t> flagged_;
};

// ── localization state ──────────────────────────────────────────────────────

enum class LocalizationState
{
  Uninitialized = 0,
  Nominal = 1,
  Degraded = 2,
  DeadReckoning = 3,
  Fault = 4,
};

std::string toString(LocalizationState state);

struct StateOptions
{
  int min_boards_nominal{2};
  double min_normal_spread_deg{20.0};
  /// A window with no detections is not automatically a coverage gap. The
  /// solve window free-runs on a timer, so it can tick between camera frames
  /// and see nothing simply because nothing arrived. Below this grace period
  /// the previous state is held rather than transitioning, which stops the
  /// reported state flapping every time the timer and the camera disagree.
  /// Above it, the boards really are gone.
  double grace_s{0.25};
  /// How long the vehicle may run on one board, heading uncorrected.
  double degraded_budget_s{10.0};
  /// How long it may run on no boards at all, position and heading both
  /// drifting. Both budgets must follow from MEASURED gyro drift and odometry
  /// error against an allowable position error; the defaults are deliberately
  /// short placeholders.
  double dead_reckoning_budget_s{3.0};
};

/// What one solve window produced, as far as health is concerned.
struct WindowOutcome
{
  bool solved{false};
  std::size_t boards_used{0};
  double normal_spread_deg{0.0};
  bool integrity_checked{false};
  bool integrity_failed{false};
};

struct StateReport
{
  LocalizationState state{LocalizationState::Uninitialized};
  double elapsed_s{0.0};
  double budget_s{0.0};
  bool request_mrm{false};
  std::string reason;
};

/// Tracks how long the vehicle has been running without a trustworthy fix.
///
/// Fault is sticky. Recovery from a degraded or dead-reckoning state is fine —
/// boards come back — but once the budget has actually expired the estimate has
/// drifted by an unknown amount, and silently resuming as if nothing happened
/// would hide exactly the event the budget exists to catch.
class LocalizationStateMachine
{
public:
  explicit LocalizationStateMachine(StateOptions options = {})
  : options_(options) {}

  StateReport update(double now_s, const WindowOutcome & outcome);
  LocalizationState state() const {return state_;}
  /// Explicit operator acknowledgement, the only way out of Fault.
  void reset();

private:
  StateOptions options_;
  LocalizationState state_{LocalizationState::Uninitialized};
  double since_good_s_{0.0};
  bool have_time_{false};
  double last_time_s_{0.0};
};

}  // namespace golfcart::aruco_localizer

#endif  // GOLFCART_ARUCO_LOCALIZER__HEALTH_HPP_
