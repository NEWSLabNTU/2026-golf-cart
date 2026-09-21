# Golf Cart Documentation

## Handover

- [CUDA NDT on the Orin](handover/2026-08-30-cuda-ndt-on-orin.md) — measured on the target: why the CUDA build failed everywhere and how the floor is pinned now, the harness fault that made empty replays look like non-convergence, and the A/B against Autoware's NDT that traced 94% of the frame to a redundant CPU NVTL pass
- [CUDA pipeline to the Orin](handover/2026-08-30-cuda-pipeline-to-orin.md) — checkpoint at parent `228e6f0`: what is validated, what is not, the libcuda symbol to check before running cuda_ndt there, and the traps that cost time
- [F9P and NTRIP brought into this repo](handover/2026-09-21-f9p-ntrip-bringup.md) — the four things in the way (a `gh` token, an unbumped submodule pointer, a broken check script, an account living outside the repo), what verified indoors, why a position-less GGA makes the VRS caster hang up, and the GGA-drop caveat that did not reproduce

## Roadblocks

- [Known Roadblocks](roadblocks.md) — Open issues blocking setup, build, or test workflows
- [Known Configuration Defects](known-config-defects.md) — wrong in a config file rather than in hardware or code, so wrong on every run; the source of most of the permanent red in the diagnostic graph

## Guides

- [LiDAR Integration](guides/lidar_integration.md) — Velodyne VLP-32C driver setup and network configuration
- [MRM Configuration](guides/mrm_configuration.md) — Minimal Risk Maneuver (emergency stop) parameter configuration
- [MRM Troubleshooting](guides/mrm_troubleshooting.md) — MRM diagnostics and troubleshooting procedures

## Research

Background research and technology surveys (some carry historical AutoSDV-era context).

- [Where the Orin's CPU Actually Goes](research/system/where-the-orin-cpu-goes.md) — the 2026-08-25 capture re-read for what else it holds: a 4.9%-per-process floor paid by 45 standalone nodes, a GNSS node respawning every 4 s, and why no run record has ever carried a GPU number
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
- [Phase 5 — Upstream CUDA Preprocessor](roadmaps/5-upstream-cuda-preprocessor.md) — status of the contribution: extraction done, publication held for a go-ahead
- [Upstreaming the CUDA Preprocessor](design/upstreaming-cuda-preprocessor.md) — repository shape under jerry73204, what is worth contributing, the per-node files Autoware requires, and what must change in the code first
- [CUDA Pipeline Data Flow](design/cuda-pipeline-data-flow.md) — the three GPU switches, what runs in which process, where the two copies are, and why one container is load-bearing
- [GPU Localization Preprocessing](roadmaps/5-gpu-localization-preprocessing.md) — moving the NDT input chain off the CPU: what Autoware already ships, the two filters that must be written, and the measurement that gates whether to start

---

**Quick Reference:** See [../CLAUDE.md](../CLAUDE.md) for project overview and common commands.
