# Checkpoint: CUDA point cloud pipeline and CUDA NDT, moving to the Orin

**Written**: 2026-08-30, parent at `228e6f0`.
**Updated**: 2026-08-30 after work on the Orin (`7af02e1`, `3d0c51a`), pinned
at `49f83ab`. Two of my conclusions were corrected there and both corrections
are kept in place rather than deleted.

**Measured on**: an x86_64 desktop, 20 cores, discrete RTX 3090 with 24 GB of
its own VRAM, EXCEPT where a row says Orin. The Orin's iGPU shares LPDDR5 with
the CPU, so a desktop GPU number is an upper bound that does not transfer;
where both exist, trust the Orin one.

---

## The CUDA floor: resolved on the Orin, and I had it wrong

**Superseded 2026-08-30 by work on the Orin (`7af02e1`). No action needed; kept
because the reasoning is worth not repeating.**

This section originally told you to run `nm -D` for `cuEventElapsedTime_v2`
before anything else, because I had pinned cubecl's `cudarc` to `cuda-12080`
and could not test the consequence. That check was run on the Orin: **JetPack
6.2 does not export the symbol**, so the pin I left in place would have taken a
package that compiles everywhere and made it open nowhere on the target. The
floor is back at `cuda-12030`.

My diagnosis behind that pin was also wrong, in a way worth naming. I reported
that `cubecl-cuda` 0.8.1 references the CUDA 12.8 tensormap symbols
*unconditionally at 7 sites*. It does not. They sit behind
`#[cfg(cuda_12080)]` with a fallback branch beside them. I grepped for the
symbol names and never read the `cfg` attributes around them.

The real cause is subtler and is now fixed properly: that `cfg` is set by
`cubecl-cuda`'s own **build-dependency** copy of `cudarc`, which shells out to
`nvcc --version` and assumes CUDA 13.0 when nvcc is off PATH. Cargo's v2
resolver keeps build-dependency features separate from normal ones, so pinning
the normal copy could never reach the copy that decides. The fix is a
`[build-dependencies]` block naming the same crate at the same floor, plus a
`build.rs` that makes cargo resolve it. Reproduced both ways on the Orin, and
verified building clean on x86 here.

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
| `pose_source:=cuda_ndt` | per-frame **fixed on the Orin**; init still too slow | 40.5 ms/frame, but 23.1 s to initialise |
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

### cuda_ndt: per-frame is solved, initialisation is not

Four faults. Three are fixed, and the per-frame path is now **faster than
Autoware's own NDT**.

1. **It did not build on any host.** Cause and fix are in the section at the top
   of this document; the short version is that the deciding cudarc copy is a
   build-dependency, and it is now pinned as one.
2. **The align service re-voxelised the map it already held.** It asks for a map
   update before estimating, matching upstream ordering, but the first call
   reports "updated" only because there is no previous position. That rebuilt
   6.6M points, 9.9 s of GPU, competing with the alignment itself. Fixed with a
   fingerprint of the points the target was built from. The log now says
   `Map update skipped: target already built from these 6607317 points`.
3. **Per-frame alignment ended with a serial CPU NVTL pass.** Fixed on the Orin
   (`3d0c51a`) by scoring NVTL on the GPU runtime the node already owned. It was
   393 ms of a 416 ms alignment, 94.5%. Measured there over Autoware's sample
   map and bag, 292 frames at full playback rate:

   | | before | after |
   |---|---|---|
   | `exe_time_ms` mean | 415.3 | **40.5** |
   | `exe_time_ms` max | 480 | 56 |
   | NVTL | 3.138 | 3.139 |
   | RMSE vs Autoware NDT | 0.0277 m | 0.0297 m |

   Autoware's own NDT is 47.0 ms mean on the same machine and bag, so **the CUDA
   path is now the faster of the two**, and `cuda_ndt` holds 10 Hz in real time
   where it previously ran 4.8x slower than the sensor.

4. **Initialisation still misses the caller deadline.** Re-measured on x86 after
   taking (3), because that work targets the per-frame path and the align
   service is separate:

   ```
   align phase startup: 100 particles in 14002ms (of which NVTL 3240ms)
   align phase tpe:     100 particles in  9077ms
   ```

   23.1 s, down from 35.3 s. The TPE half is 2.3x faster because it runs through
   `align_full_gpu` and inherits the NVTL fix. **The batched startup phase does
   not, and now dominates**: 14.0 s for 100 particles, ~108 ms each before NVTL,
   from a call named `align_batch` that is not buying much batching.

   So `pose_source:=cuda_ndt` still cannot initialise, `pose_source:=ndt`
   remains the working setting, and it is still worth deciding whether the
   default should revert until (4) lands.

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

1. Make cuda_ndt's **initialisation** fit the caller deadline. 23.1 s, of which
   14.0 s is the batched startup phase, which did not benefit from the NVTL fix.
   Either make `align_batch` actually batch, or reduce `particles_num` /
   `n_startup_trials` for the CUDA path. The per-frame path is already done.
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
