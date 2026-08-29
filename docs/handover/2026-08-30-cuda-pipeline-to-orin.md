# Checkpoint: CUDA point cloud pipeline and CUDA NDT, moving to the Orin

**Written**: 2026-08-30, parent at `228e6f0`, everything pushed.
**Measured on**: an x86_64 desktop, 20 cores, discrete RTX 3090 with 24 GB of
its own VRAM. **Not** the AGX Orin, whose iGPU shares LPDDR5 with the CPU. Every
GPU number below is an upper bound that will not transfer.

---

## Do this first, before running anything

The build fix for `cuda_ndt_matcher` takes on a risk that can only be checked on
the Orin, and getting it wrong means the node fails to load rather than fails
gracefully.

```bash
nm -D /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1 | grep cuEventElapsedTime_v2
```

- **Symbol present** -> the pin is fine, carry on.
- **Symbol absent** -> `cuda_ndt_matcher` will fail to open libcuda at startup.

Why: `src/ndt_cuda/Cargo.toml` pins cubecl's `cudarc` to `cuda-12080`, which is
the lowest floor that compiles (see below). `cuda-12080` also *declares*
`cuEventElapsedTime_v2`, and cudarc's `dynamic-loading` resolves **every**
declared symbol in `Lib::from_library()` when the library is opened, not lazily
on call. One missing export fails the whole load. The Cargo.toml records this
at length at the pin site.

If the symbol is absent, the fix is to hold `cubecl-cuda` at a version that does
not use the CUDA 12.8 tensormap API, which means pinning `cubecl` itself since
`cubecl` 0.8.1 requires `cubecl-cuda` ^0.8.1. Downgrading to `cubecl` 0.8.0 was
tried here and fails differently, with ~106 `defined multiple times` errors from
two `cuda-*` features being enabled at once.

---

## What the launch arguments now do

CUDA is the default. One coarse switch, two fine ones, all launch arguments.

```bash
just launch                          # CUDA everywhere (default)
just launch use_cuda:=false          # CPU everywhere
just launch pointcloud_backend:=cpu  # CUDA NDT, CPU preprocessing
just launch pose_source:=ndt         # CUDA preprocessing, CPU NDT
```

`use_cuda` sets the default for `pointcloud_backend` and `pose_source`; either
fine argument given explicitly wins. `pose_source:=aruco` is unaffected. The
same pair exists in `logging_simulation.launch.yaml` and
`ntu_logging_sim.launch.xml`.

`POINTCLOUD_BACKEND` is still `set_env`'d internally, because the sensing chain
drops unknown arguments. That is transport. Nobody sets it by hand.

---

## State of each piece

| piece | state | evidence |
|---|---|---|
| per-sensor preprocessing (crop, distortion, ring outlier) | **new, working** | full NDT replay, both backends |
| `pointcloud_backend:=cuda` | **validated** | 0.035 m scatter p95 vs 0.038 cpu, over ~600 m |
| `pose_source:=cuda_ndt` | **builds and converges, too slow to use** | 35.3 s align vs the caller deadline |
| `system_monitor` trimming | code only, never run on the cart | resolves to 5 monitors instead of 8 |
| `GNSS_RECEIVER=none` | code only, **not applied** | needs setting on the Advantech |

### The pipeline is measured, the NDT is not

`just ntu-test`, CSIE-1 merged bag, scored with
`scripts/localization/ndt_quality_report.py` over 120 s. That script ranks on
pose scatter and yaw step and deliberately **not** on NVTL, because NVTL rises
with coarser voxels and tighter crops whether or not the pose improves.

| | poses | path | scatter p95 | yaw step p95 |
|---|---|---|---|---|
| `pointcloud_backend:=cpu` | 4798 | 647 m | 0.038 m | 0.179 deg |
| `pointcloud_backend:=cuda` | 4771 | 604 m | 0.035 m | 0.167 deg |

Equivalent. The runs covered different distances, which accounts for a gap that
size, so read it as "no regression" rather than a CUDA win.

### cuda_ndt is the open problem

Three faults were found and two are fixed.

1. **It did not build on any host**, including the Orin, since the `cuda-12030`
   pin landed. `cubecl-cuda` 0.8.1 needs `cudarc`'s `cuda-12080` bindings.
   Fixed by raising that one pin, with the caveat at the top of this document.
2. **The align service re-voxelised the map it already held.** It asks for a map
   update before estimating, matching upstream ordering, but the first call
   reports "updated" only because there is no previous position. That rebuilt
   6.6M points, 9.9 s of GPU, competing with the alignment itself. Fixed with a
   fingerprint of the points the target was built from. The log now says
   `Map update skipped: target already built from these 6607317 points`.
3. **It converges and is still too slow.** Score 3.06, `reliable=true`, in
   **35.3 s** against the caller deadline. Phase timing now logs on every run:

   ```
   align phase startup: 100 particles in 14297ms (of which NVTL 2978ms)
   align phase tpe:     100 particles in 21037ms
   ```

   ~113 ms per batched particle and ~210 ms per serial TPE particle, with
   `particles_num: 200` and `n_startup_trials: 100`. The batching buys much less
   than its name suggests and the TPE half is serial. **That is the next thing
   to work on.** Until it lands, `pose_source:=ndt` is the working setting, and
   it is worth deciding whether the `pose_source` default should revert to `ndt`
   rather than shipping one that cannot initialise.

---

## Traps that cost time here

**`ros2 topic hz` lies on big messages.** It is a Python node and dropped ~75%
of 300 KiB clouds at 10 Hz. Playing a bag with nothing else running, the C++
`ros2 bag record` received 288 of 288 scans while `hz` reported 2.1 Hz on the
same topic. Use bag-record counts or the nodes' own diagnostics.

**Unset `RMW_IMPLEMENTATION` silently replaces the vehicle's DDS.** A harness
that unsets it gets default FastDDS instead of the tuned CycloneDDS profile,
which on the Velodyne topic is a 2.2x difference in delivered messages. Source
`scripts/env.sh` and leave it alone.

**A colon followed by a space inside an XML comment breaks the whole stack.**
Comments survive xacro expansion into `robot_description`, launch YAML-parses
parameter values, and `safe_load` then fails. You get `mapping values are not
allowed here`, no `/localization/initialize`, and `just ntu-test` reporting that
the stack never came up, with nothing naming a comment. Fixed once in
`sensor_kit.xacro`; the warning above that block explains it.

**The CSIE-1 bag is stationary for its first 90 seconds.** A quality report
taken there returns 1.5 m of path with scatter and yaw step of exactly 0.000,
which reads as a flawless result and means nothing.

**Submodule checkouts drift behind their pins silently.** `git status` in the
parent says nothing when a submodule sits at an ancestor of its pin. This
happened three times in one session. The check is:

```bash
git submodule status --recursive | grep '^+'
```

---

## Still open, roughly in order

1. Make cuda_ndt's align fit the caller deadline, or reduce `particles_num` for
   the CUDA path. 35.3 s is the whole problem.
2. Decide whether `pose_source` should default to `cuda_ndt` before (1) lands.
3. Confirm on the cart: the preprocessing chain, the `system_monitor` trimming,
   and `GNSS_RECEIVER=none` on the Advantech. All three are code-only.
4. The Seyond publishes `PointXYZIRC` with no per-point time, so that branch can
   never be deskewed by any backend. Needs a vendor driver change to
   `PointXYZIRCAEDT`.
5. Config defects #2, #5 and #6 in `docs/known-config-defects.md` need a
   decision about what those monitors should say, not a value.
6. Instrument the GPU. Every `gpu_*` column in play_launch's `system_stats.csv`
   is empty and `gpu_monitor` errors, so the cost side of any GPU move is
   currently unmeasurable on the target.
