# Phase 2 Track B — Turing Drive DBW & Map Acquisition

Tracks progress on the four Track B tasks from [ROADMAP.md](../../ROADMAP.md#track-b--turing-drive-dbw--map-acquisition).

Last updated: 2026-04-07 (verified on target machine)

---

## 1. Request Turing Drive DBW package

**Status: Not started — blocker for this entire track** (confirmed on target 2026-04-07)

### Current state
- Vehicle interface (`vehicle_interface.launch.xml`) launches two **stub nodes**:
  - `actuator.py` — accepts Autoware control commands but does nothing (explicit comment: "Will be replaced by Turing Drive DBW interface")
  - `velocity_report.py` — publishes zero-velocity reports (explicit comment: "Will be replaced by Turing Drive DBW interface")
- No Turing Drive package exists anywhere in the codebase
- No apt package name, no GitHub repo, no documentation on the DBW protocol
- **Target machine note**: 2× CAN bus interfaces (`can0`, `can1`) are available but DOWN. These are likely needed for the Turing Drive DBW interface.

### Not done
- [ ] **Contact Turing Drive** to request the drive-by-wire interface package
- [ ] Confirm package format (apt, source, binary) and ROS 2 Humble compatibility
- [ ] Confirm expected topic interfaces and message types
- [ ] Document CAN bus or serial protocol details if applicable

### Can do before real machine
- [ ] **Request the package** — this is a communication task, not a hardware task

> **Critical-path blocker**: Without Turing Drive DBW, there is no wheel velocity or steering feedback, which means NDT localization (Phase 3) cannot function.

---

## 2. Integrate DBW interface

**Status: Not started — blocked by task 1**

### Current state
- `vehicle_interface.launch.xml` exists and launches the stub nodes
- Stub actuator runs at 20 Hz control loop (`actuator.yaml`)
- Stub velocity report publishes at 20 Hz (`velocity_report.yaml`)
- `vehicle_info.param.yaml` has all dimensions filled (verified on target 2026-04-07):
  ```yaml
  wheel_base:      2.061   # measured
  wheel_tread:     1.213   # measured
  front_overhang:  0.406   # measured
  rear_overhang:   0.821   # measured
  vehicle_height:  2.005   # measured
  wheel_radius:    0.265   # fixed: was 0.53 (diameter), corrected to radius
  wheel_width:     0.14    # filled
  max_steer_angle: 0.349   # ~20 degrees
  ```
- Lexus mesh (`lexus.dae`) still used as 3D model placeholder — no golf cart model

### Can do before real machine
- [x] **Measure wheel radius and wheel width** — `wheel_radius: 0.265` (corrected from 0.53 diameter), `wheel_width: 0.14` in `vehicle_info.param.yaml` (fixed 2026-04-07).
- [ ] **Prepare `vehicle_interface.launch.xml` template** for Turing Drive integration once package specs are known
- [ ] **Document expected Autoware topics** the DBW must publish:
  - `/vehicle/status/velocity_status` (autoware_vehicle_msgs/VelocityReport)
  - `/vehicle/status/steering_status` (autoware_vehicle_msgs/SteeringReport)
  - `/vehicle/status/control_mode` (autoware_vehicle_msgs/ControlModeReport)
  - `/vehicle/status/gear_status` (autoware_vehicle_msgs/GearReport)
- [ ] **Replace Lexus mesh** with golf cart 3D model (if model is available; cosmetic, not functional)

### Requires real machine
- [ ] Install Turing Drive package on target machine
- [ ] Update `vehicle_interface.launch.xml` to launch Turing Drive nodes
- [ ] Wire control command subscription (`/control/command/control_cmd`)
- [ ] Test on stationary vehicle — verify status topics publish valid data
- [ ] Verify Autoware control mode switching (manual ↔ autonomous)

---

## 3. Obtain NTU campus maps from Turing Drive

**Status: Not started — external dependency**

### Current state
- `data/COSS-map-planning/` exists with complete practice maps:
  - `lanelet2_map.osm` (589 KB) — Lanelet2 vector map
  - `pointcloud_map.pcd` (78.3 MB) — point cloud map for NDT
  - `map_projector_info.yaml` — TransverseMercator projection (origin: 25.0201°N, 121.5423°E)
- `data/sample-map-planning/` exists with Autoware sample map (Japan, MGRS grid 54SVE)
- `data/huaxia-campus/` does **NOT exist**
- `data/visual_maps/` exists but is empty (README only)
- Default map path in `golfcart.launch.yaml` points to `./data/COSS-map-planning`

### Can do before real machine
- [ ] **Request maps from Turing Drive**: Lanelet2 vector map (`.osm`) + point cloud map (`.pcd`) for 華夏科大 campus
- [ ] **Create `data/huaxia-campus/` directory structure** with expected files:
  ```
  data/huaxia-campus/
  ├── lanelet2_map.osm
  ├── pointcloud_map.pcd
  └── map_projector_info.yaml
  ```
- [ ] **Practice with COSS map** — run `just launch-sim-planning` to learn map loading and verify planning works

### Requires real machine (or campus access)
- [ ] If Turing Drive cannot provide maps: drive the golf cart to collect point cloud data for map creation

---

## 4. Map audit

**Status: Not started — blocked by task 3**

### Can do before real machine (once maps are received)
- [ ] **Verify coordinate system** — check `map_projector_info.yaml` matches GNSS reference frame
- [ ] **Check lanelet connectivity** — ensure lane graph is connected for all intended routes
- [ ] **Inspect PCD density** — verify point cloud coverage for NDT (especially at intersections and turns)
- [ ] **Run planning simulation** — `just launch-sim-planning` with 華夏科大 map, verify Autoware plans a valid route
- [ ] **Verify map origin** — confirm GNSS coordinates align with map coordinate system

### Requires real machine
- [ ] Drive test route and compare GNSS position with map position
- [ ] Identify coverage gaps in point cloud map

---

## Summary

| Task | Status | Can prepare before real machine? |
|------|--------|----------------------------------|
| 1. Request DBW package | Not started | **Yes** — communication task |
| 2. Integrate DBW | Blocked | **Partial** — measure wheels, prepare template, document topics |
| 3. Obtain campus maps | Not started | **Yes** — request maps, practice with COSS |
| 4. Map audit | Blocked | **Yes** — once maps are received, can audit on dev machine |

### Blockers
| Blocker | Impact | Action |
|---------|--------|--------|
| Turing Drive DBW package not delivered | Blocks vehicle control, velocity feedback, Phase 3 NDT | Request from Turing Drive |
| 華夏科大 campus maps not obtained | Blocks map audit, Phase 3 NDT tuning | Request from Turing Drive |
| ~~Wheel radius/width not measured~~ | ~~Affects dead reckoning accuracy~~ | Done (`wheel_radius: 0.265`, `wheel_width: 0.14`) |

### Pre-move preparation checklist
These items can be completed before transferring to the real golf cart:
- [ ] Turing Drive DBW package requested (and ideally received)
- [ ] 華夏科大 campus maps requested (and ideally received)
- [x] Wheel radius and wheel width measured and added to `vehicle_info.param.yaml` (verify `wheel_radius: 0.53`)
- [ ] Expected Autoware topic interfaces documented
- [ ] COSS map planning simulation tested (`just launch-sim-planning`)
- [ ] Map audit completed (if maps received)
- [ ] `data/huaxia-campus/` directory created with received maps
- [ ] Golf cart 3D model replaced (if available)

### Phase 2 exit criteria (Track B portion)
- [ ] DBW interface publishes velocity and steering feedback
- [ ] NTU map loads and passes planning simulation smoke test
