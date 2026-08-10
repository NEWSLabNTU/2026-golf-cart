# Localization health, published every solve window.
#
# This exists because ArUco boards are the SOLE pose source: there is no NDT to
# fall back on, so "no boards visible" is not a benign state and has to be
# reported rather than inferred from a gap in the pose stream.

std_msgs/Header header

uint8 STATE_UNINITIALIZED = 0
uint8 STATE_NOMINAL = 1        # >=2 boards in consensus, normal spread OK
uint8 STATE_DEGRADED = 2       # 1 board, or >=2 with poor spread. Time-limited.
uint8 STATE_DEAD_RECKONING = 3 # 0 boards. Error grows without bound.
uint8 STATE_FAULT = 4          # budget expired or integrity failed -> request MRM
uint8 state

# Degrees of freedom actually solved this window: 6, 3 (position only, with
# orientation clamped to the prior), or 0 when the observation was rejected.
uint8 dof_solved

# False when redundancy was insufficient to cross-check the boards against each
# other. An unchecked fix is a different thing from a checked one even when
# both look fine, and downstream is entitled to know which it received.
bool integrity_checked

# Boards that contributed to this solve.
uint32[] markers_used

# Boards excluded because their residual is persistently inconsistent with the
# others. This is a maintenance signal, not a tuning signal: the named board has
# probably moved, or its map entry is wrong.
uint32[] markers_flagged

# Boards detected but absent from the tag map. Never used to synthesize a pose.
uint32[] markers_unmapped

# Observability of the constellation used. Normal spread is the statistic that
# separates cleanly on real data and the only one that tells an operator what to
# physically change; reprojection RMS is reported but must not be ranked on,
# because degenerate geometry scores better on it than usable geometry does.
float64 normal_spread_deg
float64 depth_range_m
float64 condition_number
float64 reprojection_rms_px

# Dead-reckoning budget. When elapsed reaches budget, state becomes FAULT.
float64 dead_reckoning_elapsed_s
float64 dead_reckoning_budget_s
