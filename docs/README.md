# Golf Cart Documentation

## Roadblocks

- [Known Roadblocks](roadblocks.md) — Open issues blocking setup, build, or test workflows
- [Known Configuration Defects](known-config-defects.md) — wrong in a config file rather than in hardware or code, so wrong on every run; the source of most of the permanent red in the diagnostic graph

## Guides

- [LiDAR Integration](guides/lidar_integration.md) — Velodyne VLP-32C driver setup and network configuration
- [MRM Configuration](guides/mrm_configuration.md) — Minimal Risk Maneuver (emergency stop) parameter configuration
- [MRM Troubleshooting](guides/mrm_troubleshooting.md) — MRM diagnostics and troubleshooting procedures

## Research

Background research and technology surveys (some carry historical AutoSDV-era context).

- [Autoware CUDA Point Cloud Chain](research/sensing/autoware-cuda-pointcloud-chain.md) — the four pipeline modes, why a CPU chain cannot feed the CUDA concatenator, and the per-sensor preprocessing this repo is missing entirely
- [LiDAR Pipeline Starvation](research/sensing/lidar-pipeline-starvation.md) — why NDT gets ~4 Hz of half-empty cloud and why the Velodyne is missing from RViz; two unrelated faults, a QoS mismatch and a 200 ms sync window
- [NDT Parameter Tuning](research/localization/ndt_parameter_tuning_coss_map.md) — NDT scan matcher tuning for VLP-32C on COSS map
- [Indoor Localization](research/indoor_localization.md) — ROS 2 indoor localization solutions survey (historical)
- [NVIDIA Isaac ROS](research/nvidia_isaac_ros.md) — Isaac ROS Visual SLAM analysis (historical)
- [LiDAR Marker Localization](research/lidar_marker_localization.md) — LiDAR-based landmark localization (historical)

## Archived Roadmaps

Completed or superseded planning documents.

- [Migration Plan](roadmaps/0-migration.md) — Original 11-phase migration from AutoSDV/Golf Cart to golf cart (superseded by [ROADMAP.md](../ROADMAP.md))
- [Phase 1 Track A Cleanup](roadmaps/1-track-a.md) — Sensor cleanup (done), VLP-32C & u-blox (software ready), Tamagawa IMU (blocked)
- [Phase 1 Track B Status](roadmaps/1-track-b.md) — Tooling & infrastructure progress (setup, justfile, version control, vehicle description)
- [AutoSDV to Golf Cart Rename](roadmaps/0-autosdv-to-golfcart-rename.md) — Naming cleanup status (completed)
- [Vehicle Interface Hardening](roadmaps/2-vehicle-interface-hardening.md) — golfcart_vehicle_interface fixes vs Autoware pacmod_interface reference
- [Vehicle Interface Fault Handling](roadmaps/2-vehicle-interface-fault-handling.md) — ROS-sub / CAN-msg drop handling
- [Standalone Vehicle-Interface Refactor](roadmaps/2-vehicle-interface-standalone-refactor.md) — one `just vehicle interface` recipe with `tx=` / `keyboard=` options ([design](design/vehicle_interface_standalone.md))
- [Xsens Driver Hardening](roadmaps/2-xsens-driver-hardening.md) — IMU CAN driver UB fixes, socket reopen, diagnostics

---

**Quick Reference:** See [../CLAUDE.md](../CLAUDE.md) for project overview and common commands.
