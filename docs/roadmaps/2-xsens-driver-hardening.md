# Xsens MTi CAN Driver — Hardening

Findings from review of `src/sensor_component/external/xsens_mti_can_ros2_driver/`.
Driver was ported from a ROS 1 reference; needs hardening for production
robustness. Compared against Autoware's `tamagawa_imu_driver`.

Scope: `src/sensor_component/external/xsens_mti_can_ros2_driver/src/xsens_mti_can_ros_driver/`

Last updated: 2026-05-04

---

## Critical (correctness / UB / silent failure)

- [x] **X-1 `initialize()` silent failure** — `xscaninterface.cpp:61`. Returns `void`; on socket-open / bind / ioctl failure logs + sets `socket_=-1` then start() bails silently. Process spins ROS forever with no callbacks. Return `bool` from `initialize()`; main exits non-zero on failure. Publish diag when socket unhealthy.
- [x] **X-2 UB — signed shift overflow** — `xsens_parser.cpp:324` and other call sites. `frame.data[0]<<24` promotes uint8 to `int`, MSB byte → bit 31 of signed int → UB. Other functions already use `static_cast<uint32_t>(byte) << 24`. Make all unpack functions consistent.
- [x] **X-3 UB — unbounded shift exponent in DeltaVelocity** — `xsens_parser.cpp:177`. `1 << exponent` where `exponent = frame.data[6]` (uint8 from wire). Range 0-255 → UB if ≥ 31. Bound exponent ≤ 30; reject frame otherwise.
- [x] **X-4 Error / warning frames silently dropped** — Parser sets `containsXsError`, `containsXsWarning` from CAN IDs 0x01 / 0x02 but no consumer. CEI_OutputBufferOverflow surfaces nowhere. Emit diag ERROR/WARN on these.
- [x] **X-5 No CAN error-frame handling** — `processCANMessages` doesn't check `frame.can_id & CAN_ERR_FLAG`. Bus-off / controller errors fall to "unknown CAN ID" branch, throttled to once per 5s. Detect and log as bus error.

## Medium (operability)

- [x] **X-6 No socket reopen** — Same gap as vehicle_interface (now fixed there). Open once at init; never reopened on interface bounce.
- [x] **X-7 No SO_RCVTIMEO** — `read()` blocks forever; rely on `::shutdown()` to unblock. Add 100ms read timeout so the loop checks `running_` itself.
- [x] **X-8 Log spam on read failures** — `RCLCPP_ERROR` per failed read. Throttle (e.g. 1 Hz) and/or escalate to diag after threshold.
- [x] **X-9 No GroupCounter sample-integrity check** — `XsGroupCounter` parsed but unused. If start-frame is dropped, two cycles merge silently. Cross-check counter, drop sample on missing tick.
- [x] **X-10 Time-option silent fallback** — `mti_utc` falls back to wall clock when no GNSS fix; `mti_sampletime` falls back if SampleTimeFine output disabled. Log WARN throttled per path.
- [x] **X-11 `std::cerr` in parser bypasses ROS logger** — DLC errors print to stderr. Drop prints in favor of bad-frame counter surfaced via diagnostics.
- [x] **X-12 No QoS spec on publishers** — Autoware sensor consumers use BEST_EFFORT; mismatch silently drops. Use `rclcpp::SensorDataQoS()` for high-rate raw sensor topics.
- [x] **X-13 No frame-rate / bad-frame diagnostics** — No way to tell MTi is alive without `ros2 topic echo`. Add per-frame counters + diag.

## Low (cleanup)

- [x] **X-14 `start()` not idempotent** — Double-call leaks first thread. Guard with `joinable()` check.
- [x] **X-15 Spurious partial-read check** — `nbytes < sizeof(can_frame)` never happens on SOCK_RAW. Drop or replace with proper short-read handling.
- [x] **X-17 16-bit shifts use int promotion** — Defined behavior but inconsistent style with the 32-bit fixes from X-2. Unify on `uint16_t` casts.
- [x] **X-18 Parameter range validation** — `start_frame_id` (must fit CAN ID range), `publisher_queue_size` (positive), stddev array size. Validate at init.
- [x] **X-19 Build flags** — Add `-Wshadow -Wconversion -Wsign-conversion` to catch implicit narrowing. Optional.
- [x] **X-21 IMU covariance default semantics** — When stddev not provided, current code leaves zeros. Per `sensor_msgs/Imu`, `covariance[0] = -1` means "unknown". Fix to set sentinel.

## Won't fix / out of scope

- X-16 `frame.can_dlc` deprecated alias — works for classic CAN, no upgrade planned.
- X-20 `frame_id` for non-IMU publishers — single frame per device acceptable; Autoware downstream tolerates.
