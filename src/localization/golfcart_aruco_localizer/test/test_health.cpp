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

#include <gtest/gtest.h>

#include <algorithm>
#include <map>

namespace golfcart::aruco_localizer
{
namespace
{

bool contains(const std::vector<std::uint32_t> & v, std::uint32_t id)
{
  return std::find(v.begin(), v.end(), id) != v.end();
}

}  // namespace

// ── integrity ───────────────────────────────────────────────────────────────

TEST(Integrity, FlagsTheInconsistentBoardAndOnlyThatOne)
{
  IntegrityMonitor monitor;
  IntegrityReport report;

  // Board 3 sits far off its peers, window after window.
  for (int i = 0; i < 40; ++i) {
    report = monitor.update({{1, 0.4}, {2, 0.5}, {3, 12.0}, {4, 0.45}});
  }

  EXPECT_TRUE(contains(report.flagged, 3)) << "the inconsistent board was not flagged";
  for (std::uint32_t id : {1U, 2U, 4U}) {
    EXPECT_FALSE(contains(report.flagged, id)) << "board " << id << " flagged unfairly";
  }
}

TEST(Integrity, OneBadWindowIsNotEnough)
{
  IntegrityMonitor monitor;
  const auto report = monitor.update({{1, 0.4}, {2, 0.5}, {3, 12.0}, {4, 0.45}});
  EXPECT_TRUE(report.flagged.empty())
    << "a single bad window must not exclude a board; that is noise, not a fault";
}

// The distinction that keeps a calibration problem from becoming a cascade of
// spurious exclusions.
TEST(Integrity, AGloballyBadSolveFlagsNobody)
{
  IntegrityMonitor monitor;
  IntegrityReport report;

  // Every board is far out, together — the signature of a wrong marker size, a
  // wrong extrinsic, or a map frame offset. Board-versus-board comparison
  // cannot see those, and an absolute threshold would exclude the lot.
  for (int i = 0; i < 60; ++i) {
    report = monitor.update({{1, 30.0}, {2, 31.0}, {3, 29.5}, {4, 30.5}});
  }

  EXPECT_TRUE(report.flagged.empty())
    << "a systematic fault must not be mistaken for several board faults";
}

TEST(Integrity, ReportsUncheckedWhenThereIsNoRedundancy)
{
  IntegrityMonitor monitor;
  EXPECT_FALSE(monitor.update({{1, 0.4}}).checked) << "one board cannot be cross-checked";
  EXPECT_FALSE(monitor.update({{1, 0.4}, {2, 0.5}}).checked)
    << "two boards leave an unchecked solve once one is excluded";
  EXPECT_TRUE(monitor.update({{1, 0.4}, {2, 0.5}, {3, 0.45}}).checked);
}

TEST(Integrity, ClearingABoardForgetsIt)
{
  IntegrityMonitor monitor;
  for (int i = 0; i < 40; ++i) {
    monitor.update({{1, 0.4}, {2, 0.5}, {3, 12.0}});
  }
  ASSERT_TRUE(monitor.isFlagged(3));
  monitor.clear(3);
  EXPECT_FALSE(monitor.isFlagged(3)) << "someone went and fixed the board";
}

// ── state machine ───────────────────────────────────────────────────────────

namespace
{
WindowOutcome good()
{
  WindowOutcome o;
  o.solved = true;
  o.boards_used = 3;
  o.normal_spread_deg = 45.0;
  o.integrity_checked = true;
  return o;
}
WindowOutcome oneBoard()
{
  WindowOutcome o;
  o.solved = true;
  o.boards_used = 1;
  o.normal_spread_deg = 0.0;
  return o;
}
WindowOutcome nothing() {return WindowOutcome{};}
}  // namespace

TEST(StateMachine, NominalNeedsBoardsAndSpread)
{
  LocalizationStateMachine sm;
  EXPECT_EQ(sm.update(0.0, good()).state, LocalizationState::Nominal);

  // Enough boards, but all facing the same way — the coplanar case. Position
  // is fine, heading is not constrained.
  WindowOutcome flat = good();
  flat.normal_spread_deg = 3.0;
  EXPECT_EQ(sm.update(0.1, flat).state, LocalizationState::Degraded);
}

TEST(StateMachine, DeadReckoningExpiresIntoFaultAndRequestsMrm)
{
  StateOptions options;
  options.dead_reckoning_budget_s = 3.0;
  LocalizationStateMachine sm(options);

  sm.update(0.0, good());
  EXPECT_EQ(sm.update(1.0, nothing()).state, LocalizationState::DeadReckoning);
  EXPECT_EQ(sm.update(2.0, nothing()).state, LocalizationState::DeadReckoning);

  const auto report = sm.update(5.0, nothing());
  EXPECT_EQ(report.state, LocalizationState::Fault);
  EXPECT_TRUE(report.request_mrm) << "an expired budget must actually stop the vehicle";
}

TEST(StateMachine, BoardsComingBackInTimeRecovers)
{
  StateOptions options;
  options.dead_reckoning_budget_s = 5.0;
  LocalizationStateMachine sm(options);

  sm.update(0.0, good());
  EXPECT_EQ(sm.update(1.0, nothing()).state, LocalizationState::DeadReckoning);
  EXPECT_EQ(sm.update(2.0, good()).state, LocalizationState::Nominal)
    << "recovery must be available before the budget expires";

  // And the clock must have been reset, not merely paused.
  EXPECT_EQ(sm.update(6.0, nothing()).state, LocalizationState::DeadReckoning);
}

TEST(StateMachine, DegradedHasItsOwnLongerBudget)
{
  StateOptions options;
  options.degraded_budget_s = 10.0;
  options.dead_reckoning_budget_s = 3.0;
  LocalizationStateMachine sm(options);

  sm.update(0.0, good());
  // Five seconds on one board: past the dead-reckoning budget, but position is
  // still being corrected, so this is not yet a fault.
  EXPECT_EQ(sm.update(5.0, oneBoard()).state, LocalizationState::Degraded);
  EXPECT_EQ(sm.update(12.0, oneBoard()).state, LocalizationState::Fault);
}

TEST(StateMachine, IntegrityFailureIsImmediateAndNotAMatterOfTime)
{
  LocalizationStateMachine sm;
  sm.update(0.0, good());

  WindowOutcome bad = good();
  bad.integrity_failed = true;
  const auto report = sm.update(0.1, bad);

  EXPECT_EQ(report.state, LocalizationState::Fault);
  EXPECT_TRUE(report.request_mrm);
  EXPECT_NE(report.reason.find("integrity"), std::string::npos) << report.reason;
}

TEST(StateMachine, FaultIsStickyUntilExplicitlyReset)
{
  LocalizationStateMachine sm;
  sm.update(0.0, good());
  WindowOutcome bad = good();
  bad.integrity_failed = true;
  sm.update(0.1, bad);
  ASSERT_EQ(sm.state(), LocalizationState::Fault);

  // Good windows must not quietly clear it: by now the estimate has drifted by
  // an unknown amount, and resuming as if nothing happened hides the event.
  EXPECT_EQ(sm.update(1.0, good()).state, LocalizationState::Fault);
  EXPECT_EQ(sm.update(2.0, good()).state, LocalizationState::Fault);

  sm.reset();
  EXPECT_EQ(sm.update(3.0, good()).state, LocalizationState::Nominal);
}

// Found by running the loop: the solve window is on a free-running timer, so it
// ticks between camera frames and sees nothing. Without a grace period the
// reported state flapped to DEAD_RECKONING several times a second while the
// boards were in full view the whole time.
TEST(StateMachine, ABriefEmptyWindowDoesNotFlapTheState)
{
  StateOptions options;
  options.grace_s = 0.25;
  LocalizationStateMachine sm(options);

  EXPECT_EQ(sm.update(0.00, good()).state, LocalizationState::Nominal);
  EXPECT_EQ(sm.update(0.03, nothing()).state, LocalizationState::Nominal)
    << "one empty 30 ms window is the timer ticking between frames, not a coverage gap";
  EXPECT_EQ(sm.update(0.06, nothing()).state, LocalizationState::Nominal);
  EXPECT_EQ(sm.update(0.09, good()).state, LocalizationState::Nominal);

  // A gap past the grace period is a real one and must be reported.
  EXPECT_EQ(sm.update(0.50, nothing()).state, LocalizationState::DeadReckoning);
}

TEST(StateMachine, GraceDoesNotCoverASolvedButDegradedWindow)
{
  StateOptions options;
  options.grace_s = 0.25;
  LocalizationStateMachine sm(options);

  sm.update(0.0, good());
  // Well inside the grace period, but this window DID solve — from one board.
  // That is a real statement about the geometry, not a missed camera frame.
  EXPECT_EQ(sm.update(0.05, oneBoard()).state, LocalizationState::Degraded)
    << "a degraded fix must be reported immediately, not hidden by the empty-window grace";
}

// Found on a clean fixture: healthy boards were being excluded and the vehicle
// sent to FAULT with no fault injected. Residuals differ between boards for
// reasons of geometry -- range, obliquity -- and a board at several times the
// cohort median is still healthy when every residual involved is sub-pixel.
TEST(Integrity, SubPixelScatterIsNotAFault)
{
  IntegrityMonitor monitor;
  IntegrityReport report;

  // Board 3 sits at six times the median, and every board is still well under a
  // pixel. This is a good solve, not a bad board.
  for (int i = 0; i < 80; ++i) {
    report = monitor.update({{1, 0.05}, {2, 0.06}, {3, 0.36}, {4, 0.055}});
  }

  EXPECT_TRUE(report.flagged.empty())
    << "a board was excluded for sub-pixel disagreement with its neighbours";
}

// Detection and exclusion is the remedy, not the failure. The node originally
// faulted on the first flagged board, which stopped the vehicle at the moment
// its integrity monitoring started working.
TEST(Integrity, ExcludingOneBadBoardIsNotAnIsolationFailure)
{
  IntegrityMonitor monitor;
  IntegrityReport report;
  for (int i = 0; i < 40; ++i) {
    report = monitor.update({{1, 0.4}, {2, 0.5}, {3, 12.0}, {4, 0.45}});
  }

  ASSERT_TRUE(contains(report.flagged, 3));
  EXPECT_FALSE(report.isolation_failed)
    << "excluding a single bad board must let the solve carry on without it";
}

TEST(Integrity, TooManyExclusionsMeansTheProblemIsNotTheBoards)
{
  IntegrityOptions options;
  options.max_excluded = 2;
  IntegrityMonitor monitor(options);
  IntegrityReport report;

  // Three boards drift out one after another. At some point "three bad boards"
  // stops being the likely story and something common to all of them -- the
  // extrinsics, the marker size, the map frame -- becomes the better one.
  for (int i = 0; i < 40; ++i) {
    report = monitor.update({{1, 0.4}, {2, 0.5}, {3, 12.0}, {4, 0.45}, {5, 0.5}});
  }
  for (int i = 0; i < 40; ++i) {
    report = monitor.update({{1, 0.4}, {2, 14.0}, {4, 0.45}, {5, 0.5}});
  }
  for (int i = 0; i < 40; ++i) {
    report = monitor.update({{1, 0.4}, {4, 16.0}, {5, 0.5}});
  }

  EXPECT_GT(report.flagged.size(), 2U);
  EXPECT_TRUE(report.isolation_failed)
    << "exclusions past the limit must stop the vehicle rather than continue";
}

}  // namespace golfcart::aruco_localizer
