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

#include <golfcart_aruco_localizer/health.hpp>

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace golfcart::aruco_localizer
{

// ── integrity ───────────────────────────────────────────────────────────────

IntegrityReport IntegrityMonitor::update(const std::map<std::uint32_t, double> & residual_px)
{
  IntegrityReport report;

  // Two boards is the minimum for any cross-check at all, and even then
  // excluding one leaves an unchecked solve. Below that there is nothing to
  // compare against, so report unchecked rather than inventing a verdict.
  report.checked = residual_px.size() >= 3;
  if (residual_px.size() < 2) {
    report.flagged = flagged_;
    report.isolation_failed = flagged_.size() > options_.max_excluded;
    return report;
  }

  std::vector<double> values;
  values.reserve(residual_px.size());
  for (const auto & [id, r] : residual_px) {
    values.push_back(r);
  }
  std::sort(values.begin(), values.end());
  const double median = values[values.size() / 2];
  const double reference = std::max(median, options_.median_floor_px);

  for (const auto & [id, r] : residual_px) {
    const double ratio = r / reference;
    // Both tests must fire: many times the median, AND far enough above it in
    // absolute pixels to be a fault rather than ordinary geometry.
    const bool excessive = ratio > options_.flag_ratio &&
      (r - median) > options_.flag_margin_px;
    const auto it = ewma_.find(id);
    ewma_[id] = (it == ewma_.end())
      ? ratio
      : (1.0 - options_.ewma_alpha) * it->second + options_.ewma_alpha * ratio;
    report.ratio[id] = ewma_[id];

    if (excessive && ewma_[id] > options_.flag_ratio) {
      strikes_[id] += 1;
    } else {
      // Decay rather than reset: a board that is intermittently wrong should
      // still accumulate toward a flag.
      strikes_[id] = std::max(0, strikes_[id] - 1);
    }

    const bool already = std::find(flagged_.begin(), flagged_.end(), id) != flagged_.end();
    if (strikes_[id] >= options_.flag_count && !already) {
      flagged_.push_back(id);
    }
  }

  report.flagged = flagged_;
  report.isolation_failed = flagged_.size() > options_.max_excluded;
  return report;
}

void IntegrityMonitor::noteConsensusOutlier(std::uint32_t id)
{
  // Counted on the same ladder as a residual outlier, so one disagreeing frame
  // is still noise and a persistent one still becomes a maintenance event.
  //
  // Note this is a RATIO test, not a count: a board must be an outlier more
  // often than not. Counting up without ever counting down means any board that
  // is occasionally rejected -- which is every board, at the edge of its view
  // window -- reaches the threshold given a long enough drive, and the monitor
  // slowly flags the entire map. That is what happened on the first corridor
  // run, where two healthy boards were excluded after a couple of minutes.
  seen_[id] += 1;
  strikes_[id] += 1;
  if (strikes_[id] * 2 < static_cast<int>(seen_[id])) {
    // A minority of frames: noise at a view-window edge, not a fault.
    strikes_[id] = std::max(0, strikes_[id] - 1);
  }
  const bool already = std::find(flagged_.begin(), flagged_.end(), id) != flagged_.end();
  if (strikes_[id] >= options_.flag_count && !already) {
    flagged_.push_back(id);
  }
}

bool IntegrityMonitor::isFlagged(std::uint32_t id) const
{
  return std::find(flagged_.begin(), flagged_.end(), id) != flagged_.end();
}

void IntegrityMonitor::clear(std::uint32_t id)
{
  ewma_.erase(id);
  strikes_.erase(id);
  flagged_.erase(std::remove(flagged_.begin(), flagged_.end(), id), flagged_.end());
}

// ── state machine ───────────────────────────────────────────────────────────

std::string toString(LocalizationState state)
{
  switch (state) {
    case LocalizationState::Uninitialized: return "UNINITIALIZED";
    case LocalizationState::Nominal: return "NOMINAL";
    case LocalizationState::Degraded: return "DEGRADED";
    case LocalizationState::DeadReckoning: return "DEAD_RECKONING";
    case LocalizationState::Fault: return "FAULT";
  }
  return "UNKNOWN";
}

StateReport LocalizationStateMachine::update(double now_s, const WindowOutcome & outcome)
{
  StateReport report;

  const double dt = have_time_ ? std::max(0.0, now_s - last_time_s_) : 0.0;
  last_time_s_ = now_s;
  have_time_ = true;

  if (state_ == LocalizationState::Fault) {
    report.state = state_;
    report.request_mrm = true;
    report.reason = "fault latched; needs an explicit reset";
    return report;
  }

  // An integrity failure is not a matter of degree. A board has been shown to
  // disagree with its peers persistently, which means the map or the field no
  // longer match, and no amount of waiting improves that.
  if (outcome.integrity_failed) {
    state_ = LocalizationState::Fault;
    report.state = state_;
    report.request_mrm = true;
    report.reason = "integrity check failed: a board is persistently inconsistent";
    return report;
  }

  const bool nominal = outcome.solved &&
    outcome.boards_used >= static_cast<std::size_t>(options_.min_boards_nominal) &&
    outcome.normal_spread_deg >= options_.min_normal_spread_deg;

  if (nominal) {
    state_ = LocalizationState::Nominal;
    since_good_s_ = 0.0;
    report.state = state_;
    report.reason = "boards agree with sufficient spread";
    return report;
  }

  // Before the first fix there is nothing to dead-reckon FROM, so the budget
  // cannot be counting down. It used to: from UNINITIALIZED an empty window
  // fell straight through to DEAD_RECKONING, the clock ran while the graph was
  // still coming up, and the vehicle latched FAULT and requested an MRM a few
  // seconds after launch -- before it had ever localized once.
  //
  // Staying UNINITIALIZED is also the more honest report: "I do not know where
  // I am yet" and "I knew, and have been losing it for N seconds" are different
  // conditions and downstream should be able to tell them apart.
  if (state_ == LocalizationState::Uninitialized && !outcome.solved) {
    report.state = state_;
    report.reason = "waiting for a first usable fix";
    return report;
  }

  since_good_s_ += dt;

  // Hold the previous state through a brief EMPTY gap: the window timer runs
  // free of the cameras, so a short window with nothing in it means the timer
  // ticked between frames, not that the boards went away.
  //
  // The grace deliberately does not cover a window that did solve. A fix from
  // one board, or from boards too alike to constrain heading, is a real
  // observation about the geometry and must be reported at once.
  if (!outcome.solved && since_good_s_ <= options_.grace_s &&
    state_ != LocalizationState::Uninitialized)
  {
    report.state = state_;
    report.elapsed_s = since_good_s_;
    report.reason = "brief gap, holding previous state";
    return report;
  }

  if (outcome.solved) {
    // A fix, but from one board or from boards too alike to constrain heading.
    // Position is corrected; yaw is running on the gyro.
    state_ = LocalizationState::Degraded;
    report.budget_s = options_.degraded_budget_s;
    report.reason = (outcome.boards_used < static_cast<std::size_t>(options_.min_boards_nominal))
      ? "one usable board: position only, heading on the gyro"
      : "boards too alike to constrain heading";
  } else {
    state_ = LocalizationState::DeadReckoning;
    report.budget_s = options_.dead_reckoning_budget_s;
    report.reason = "no usable boards: gyro and odometry only, error unbounded";
  }

  report.elapsed_s = since_good_s_;
  if (since_good_s_ > report.budget_s) {
    state_ = LocalizationState::Fault;
    report.request_mrm = true;
    report.reason = "ran " + std::to_string(since_good_s_) + " s without a trustworthy fix, "
      "past the " + std::to_string(report.budget_s) + " s budget";
  }
  report.state = state_;
  return report;
}

void LocalizationStateMachine::reset()
{
  state_ = LocalizationState::Uninitialized;
  since_good_s_ = 0.0;
  have_time_ = false;
}

}  // namespace golfcart::aruco_localizer
