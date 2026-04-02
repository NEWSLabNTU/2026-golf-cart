# Golf Cart Documentation

## Roadblocks

- [Known Roadblocks](roadblocks.md) — Open issues blocking setup, build, or test workflows

## Guides

- [LiDAR Integration](guides/lidar_integration.md) — Velodyne VLP-32C driver setup and network configuration
- [MRM Configuration](guides/mrm_configuration.md) — Minimal Risk Maneuver (emergency stop) parameter configuration
- [MRM Troubleshooting](guides/mrm_troubleshooting.md) — MRM diagnostics and troubleshooting procedures

## Research

Background research and technology surveys (some carry historical AutoSDV-era context).

- [NDT Parameter Tuning](research/localization/ndt_parameter_tuning_coss_map.md) — NDT scan matcher tuning for VLP-32C on COSS map
- [Indoor Localization](research/indoor_localization.md) — ROS 2 indoor localization solutions survey (historical)
- [NVIDIA Isaac ROS](research/nvidia_isaac_ros.md) — Isaac ROS Visual SLAM analysis (historical)
- [LiDAR Marker Localization](research/lidar_marker_localization.md) — LiDAR-based landmark localization (historical)

## Archived Roadmaps

Completed or superseded planning documents.

- [Migration Plan](roadmaps/migration.md) — Original 11-phase migration from AutoSDV/Golf Cart to golf cart (superseded by [ROADMAP.md](../ROADMAP.md))
- [Phase 1 Track A Cleanup](roadmaps/phase1_track_a.md) — Sensor cleanup (done), VLP-32C & u-blox (software ready), Tamagawa IMU (blocked)
- [Phase 1 Track B Status](roadmaps/phase1_track_b.md) — Tooling & infrastructure progress (setup, justfile, version control, vehicle description)
- [AutoSDV to Golf Cart Rename](roadmaps/autosdv_to_golfcart_rename.md) — Naming cleanup status (completed)

---

**Quick Reference:** See [../CLAUDE.md](../CLAUDE.md) for project overview and common commands.
