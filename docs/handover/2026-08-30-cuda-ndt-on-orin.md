# CUDA NDT on the Orin: the build fix, and what the CUDA path actually costs

**Written**: 2026-08-30, on the target hardware.
**Measured on**: NVIDIA Jetson AGX Orin Developer Kit, JetPack 6.2 (R36.4.4),
CUDA 12.6, driver 540.4.0, 12 cores, 61 GB shared LPDDR5, `nvpmodel` MAXN.
Companion to
[2026-08-30-cuda-pipeline-to-orin.md](2026-08-30-cuda-pipeline-to-orin.md),
which carries the wider checkpoint and the traps. That document folds in the
headline results; this one is the working record behind them -- the phase
measurements, the two optimizations that were rejected on measurement, and the
scoring defect the second one exposed.

---

## The headline

`pose_source:=cuda_ndt` **is not a convergence problem.** It localises correctly
and agrees with Autoware's NDT to **2.8 cm RMSE** over a full replay.

It was a throughput problem, and only that. **That is now fixed**: 415 ms per
frame became **31 ms**, against Autoware's 47 ms on the same machine and bag.
cuda_ndt holds 10 Hz in real time and is comfortably the faster of the two.

The whole cost was one CPU call — see [The 415 ms](#the-415-ms) below.

---

## The preflight check in the previous handover: the symbol is absent

That document opens by telling you to run this, and it was right to:

```bash
nm -D /usr/lib/aarch64-linux-gnu/tegra/libcuda.so.1 | grep cuEventElapsedTime_v2
```

**The symbol is absent on this JetPack.** Only `cuEventElapsedTime` exists. So
the `cuda-12080` pin would have failed to load here, exactly as predicted —
`cudarc`'s `dynamic-loading` resolves every declared symbol in
`Lib::from_library()` with `.expect()`, so one missing export panics the node at
startup rather than degrading it.

**The remedy that document proposes is not the one that was needed.** It suggests
holding `cubecl-cuda` at a version without the 12.8 tensormap API, which means
pinning `cubecl` itself. That is unnecessary, and the attempt to do it via
`cubecl` 0.8.0 fails on its own terms.

`cubecl-cuda` 0.8.1 already supports older CUDA. Every reference to the 12.8
tensormap API is behind `#[cfg(cuda_12080)]`, with a `#[cfg(not(cuda_12080))]`
fallback beside it. That is a **custom cfg**, not a cargo feature, and it is set
by `cubecl-cuda`'s own build script from `cudarc::driver::sys::CUDA_VERSION` as
read from its **build-dependency** copy of `cudarc` — a different copy from the
one the crate pins. That copy carries `cuda-version-from-build-system` and
`fallback-latest`, so it runs `nvcc --version` and **assumes CUDA 13.0 when nvcc
is off PATH**.

That is the whole bug. When the guess is 13.0, `cubecl-cuda` compiles its 12.8
branch against a normal `cudarc` pinned lower, the two copies disagree, and you
get:

```
error[E0432]: unresolved imports `cudarc::driver::sys::CUtensorMapIm2ColWideMode`,
              `cudarc::driver::sys::cuTensorMapEncodeIm2colWide`
error[E0425]: cannot find value `CU_TENSOR_MAP_DATA_TYPE_16U4_ALIGN8B`
```

Reproduced both directions on this machine, from one tree: with nvcc on PATH the
`cuda-12030` pin compiles clean; removing nvcc from PATH is sufficient, on its
own, to produce those two errors. **The pin was never the cause.**

Cargo's v2 resolver keeps build-dependency features separate from normal ones,
which is why pinning the normal copy could not reach the deciding one. The fix
declares the same crate at the same floor in `[build-dependencies]`, with a
`build.rs` so cargo resolves it. `CUDA_VERSION` is then 12030 on every host,
`cuda_12080` is never set, and no 12.8 symbol is demanded at load time. It also
retires the "PATH is not in cargo's fingerprint" trap: an explicit feature is in
the fingerprint, a detected one is not.

Verified here: builds with and without nvcc on PATH; the installed binary
references none of `cuEventElapsedTime_v2`, `cuCtxGetDevice_v2` or
`cuTensorMapEncodeIm2colWide`; `cargo test -p ndt_cuda` passes **336/336**,
including the GPU scoring and CPU/GPU agreement tests.

---

## The harness fault that hid all of this

Before any of the numbers below could be taken, `scripts/run_demo.sh` had to be
fixed, and it is worth knowing about because it produces a **confident wrong
answer** rather than an error.

It started the rosbag 5 seconds after launching the stack, with a comment
saying play_launch starts Autoware fast enough for that. On this Orin it is not
close: play_launch spends ~45 s parsing the launch tree before it runs anything,
and reports all nodes ready at **~58 s**. The bag therefore played into a stack
that did not exist, and because the jobs run under `parallel --halt now,done=1`,
playback finishing tore the run down before the matcher saw a single scan.

The run still **exited 0** and still wrote a rosbag — an empty one — with no
debug log and nothing in the output naming the cause. It reads as the scan
matcher failing to converge. It is not.

Readiness now comes from play_launch's own `Startup complete` line. A DDS probe
was tried first and does not work in this harness: `ros2 topic list` and
`ros2 service list` both answer from the ROS 2 daemon, which is started under a
different environment than the nodes and reports nothing however long it is
polled. Note also that `cuda_ndt_matcher` is an rclrs node and **does not apply
launch remap rules**, so the namespaced service name the launch XML asks for
never exists to be probed for.

---

## The measurement

Autoware's own sample map and sample rosbag, shipped in the submodule under
`data/` (30 s, 129 m of driving). Same map, same bag, same machine, one
parameter set. `just run-builtin` against `just run-cuda`.

| | Autoware NDT | CUDA NDT (before) | CUDA NDT (after) |
|---|---|---|---|
| `exe_time_ms` mean | 47.0 | **415.3** | **30.7** |
| `exe_time_ms` max | 82.7 | 480.5 | 52.8 |
| NVTL mean | 3.126 | 3.138 | 3.138 |
| transform probability mean | 6.71 | 6.78 | 6.78 |
| iterations mean | 3.13 | 2.68 | 3.30 |
| initial-to-result distance mean | 0.090 m | 0.080 m | 0.119 m |
| poses / path | 244 / 129.3 m | 291 / 126.9 m | 294 / 129.8 m |
| playback rate | 1x | 0.2x (could not hold 1x) | **1x** |

Trajectory agreement against the Autoware run, over 242 matched stamps:

| | |
|---|---|
| 2D RMSE | **0.0309 m** |
| mean / p50 | 0.0241 m / 0.0175 m |
| p95 / max | 0.0610 m / 0.1203 m |
| \|dz\| mean / max | 0.0039 m / 0.0237 m |

The integration suite's own tolerance is 0.3 m RMSE. This passes with 10x
margin. **On quality, the CUDA path is equivalent to Autoware's NDT** — slightly
fewer iterations and a slightly smaller correction per frame, which is what you
would expect from a matcher that is converging properly.

The "before" column had to be taken with the bag played at `--rate 0.2`, because
the node could not keep up at 1x. The "after" column is at full rate.

### Why it looks like a convergence failure at 1x

At full rate the CUDA node gets through only **5.2 s of the 30 s bag**, because
it runs 4.8x slower than real time. The vehicle is stationary for that opening —
the same trap the previous handover records for the CSIE-1 bag.

Worse, the pose prior freezes. The recorded
`initial_pose_with_covariance` sits at exactly `(89571.000, 42301.000, -3.300)`
for every frame, which is the literal `user_defined_initial_pose` from
`ndt_replay_simulation.launch.xml`. The EKF feedback loop never closes, because
an estimator running at 2.1 Hz against a 10 Hz sensor never gives the filter
anything current to work with. NDT then re-converges onto the same seed forever,
reporting a healthy NVTL of 3.2 the entire time.

That is the failure mode to recognise: **NVTL stays high and the pose stops
moving.** NVTL says the scan matched the map somewhere; it does not say the
somewhere was right, and it does not say the loop is closed. Compare the prior
against the output before concluding anything about convergence.

---

## The 415 ms

Phase timing, added behind `NDT_PROFILE=1` because the crate's existing timing
module has no call sites and collects nothing. Over 292 frames, inside
`align_full_gpu`:

| phase | mean | share |
|---|---|---|
| `nvtl` | **393.1 ms** | **94.5%** |
| `optimize` | 11.6 ms | 2.8% |
| `voxel_pack` | 8.7 ms | 2.1% |
| `upload` | 2.4 ms | 0.6% |
| `pipeline_new` | 0.2 ms | 0.1% |
| total | 416.1 ms | |

The GPU NDT optimisation was never slow. At 11.6 ms it is four times faster than
Autoware's entire 47 ms frame. Everything else was one CPU call at the end.

`align_full_gpu` finished by computing NVTL through `compute_nvtl_simple`: a
serial loop over all 5000 source points, each doing a KD-tree radius search and
f64 scoring against every voxel returned. Single-threaded, ~78 µs per point.

It was redundant. `NdtScanMatcher` already owns a GPU scoring runtime and an
uploaded copy of the voxel grid, and already scores NVTL on the GPU in
`evaluate_nvtl` — which is why the *other* NVTL call in the node, the one before
the timer starts, never showed up as a cost. `align_full_gpu` simply never used
that path. The optimizer now defers NVTL to its caller and `align_gpu` fills it
from the GPU, falling back to the same CPU routine when there is no runtime or
no uploaded grid.

The two agree to three decimal places (NVTL 3.137 vs 3.138), which is the
check that matters — the pose gate is NVTL, so a GPU/CPU disagreement here would
move convergence, and this one does not.

**A note on what this says about profiling.** The flat frame cost and the low
iteration count pointed at fixed per-call overhead, and there is real per-call
overhead in this function — it rebuilds the GPU pipeline, repacks the voxel
grid and re-uploads it on every frame, all of which are invariant between
frames. That reasoning was correct and it was the wrong answer: those three
together are 11.3 ms. Measuring first would have cost less than deducing.

## Where the frame goes now

Two rounds of this, each measured rather than reasoned about. After the NVTL
move, `voxel_pack` was 18.1 ms of 34.5 -- it grew in share *and* in absolute
terms once it stopped competing with a 390 ms CPU pass for memory bandwidth.
`align_full_gpu` rebuilt `GpuVoxelData` from the target grid on every scan: 16
floats per voxel over 11601 voxels, allocated and filled, for a value that only
changes when the map is reloaded. `NdtScanMatcher` already keeps that packing
from `set_target`, so it now hands it down.

Current split, 294 frames at full rate:

| phase | mean | note |
|---|---|---|
| `optimize` | 14.4 ms | the GPU Newton loop; the real work |
| `gpu_nvtl` | 13.2 ms | scored in `align_gpu`, outside the phase line |
| `upload` | 2.4 ms | source points, and the voxel grid re-uploaded per frame |
| `pipeline_new` | 0.3 ms | |
| `exe_time_ms` | 30.7 ms | |

### A rejected optimization, and the bug it exposed

`gpu_nvtl` is 13.2 ms because `evaluate_nvtl_gpu` re-uploads the whole voxel
grid on every call. `GpuScoringPipeline` holds exactly that data persistently
from `set_target`, so routing the per-frame NVTL through it looked like the
obvious next win.

**It is not, on two counts, and the second one matters much more.**

It was slower: 15.7 ms against 11.7 ms for the re-uploading path, measured side
by side on the same frames. And it returned a *different number*: NVTL 2.821
against 3.138, mean absolute difference 0.317, max 0.808.

The re-uploading path is the correct one — it agrees with the CPU
`compute_nvtl_simple` to three decimals, which is how the NVTL move was
validated in the first place. So `GpuScoringPipeline` is scoring the wrong
rotation.

The cause is a convention mismatch, and it is the same one this project has
been bitten by before:

- `GpuScoringPipeline` is addressed with `[x, y, z, roll, pitch, yaw]` and
  builds its matrix with `pose_to_transform_matrix`, which composes
  **`Rx(roll) · Ry(pitch) · Rz(yaw)`** — Autoware's convention.
- Every caller derives those angles from `nalgebra`'s
  `Isometry3::rotation.euler_angles()`, which describes the **opposite**
  composition order.

Feeding one convention's angles to the other's builder gives a different
rotation for anything but small angles. `cuda_scan_matcher.param.yaml` already
records this failure mode from 2026-08-03/04, when a euler round trip made the
GPU read ~1.45x high and the NVTL gate had to be recalibrated against it.

**This was a live bug, not just a rejected optimization. It is now fixed** —
`isometry_to_pose_vector` is the conversion that belongs at both call sites, and
`derivatives/gpu.rs` already round-trip tests it against
`pose_to_transform_matrix`; the two sites simply bypassed it.

**A correction on its blast radius.** The first reading of this said the
initial-pose align service ranked its particles on the wrong NVTL. That was
wrong. The estimator scores particles with the singular `evaluate_nvtl`, which
takes the matrix route and was always correct. What the bug actually reached:

- `evaluate_nvtl_batch`, used only by `covariance.rs` for `MULTI_NDT` and
  `MULTI_NDT_SCORE` — dormant, since the shipped config is
  `covariance_estimation_type: 0` (FIXED).
- `compute_per_point_scores_for_visualization`, the per-point score overlay.
  Live, but cosmetic.

A full replay after the fix is unchanged at 30.8 ms, NVTL 3.137 and 2.9 cm
RMSE, which is the expected result: the per-scan path never used either site.

The regression test took two attempts to make real, and both failures are the
same shape as the bug. With the default config both scorers fall back to the
same CPU routine and agree for the wrong reason, so it must force `use_gpu`.
And with an arbitrary source cloud the pose carries it off the map, both
scorers return 0, and it agrees again — so the source is built by pulling the
target back through the pose, and the test asserts the fixture actually scores
before it compares. A test that cannot fail is worse than no test.

## What to work on

1. ~~The `GpuScoringPipeline` euler convention.~~ **Fixed.** The persistent-target
   path is now correct, but still not worth taking for per-frame NVTL: it
   measured 15.7 ms against 11.7 ms for the re-uploading path.
2. **`upload`, 2.4 ms.** `align_full_gpu` still re-uploads the voxel grid to the
   GPU every frame even though it no longer repacks it, because the pipeline is
   constructed per call. Persisting the pipeline across frames would need
   interior mutability and invalidation on map reload.
3. ~~The initial-pose align.~~ **Measured and fixed — see below.** 49.1 s → 9.9 s,
   and `pose_source:=cuda_ndt` now initialises from Monte Carlo and tracks end
   to end on the Orin. The serial TPE phase is what is left, at 6.4 s.
4. **The TPE phase, 6.0 s**, now 67% of the align and all of it real work:
   4.4 s of alignments and 1.6 s of TPE sampling. Both are reducible only by
   changing the search — fewer particles, a cheaper sampler, or batching a
   sequential algorithm — not by deleting redundant work. `particles_num: 200`
   and `n_startup_trials: 100` are inherited from Autoware's defaults and have
   never been tuned for this matcher.
5. `pose_source:=cuda_ndt` now holds 10 Hz with margin on the per-scan path
   (max 52.8 ms against a 100 ms bound), is the faster of the two matchers, and
   initialises in 9.9 s. Whether it should *default* to CUDA is a call to make
   on vehicle data, not on this bag.

## The initial-pose align: 49.1 s → 9.9 s

The previous handover measured 35.3 s for this on an **x86 desktop with a
discrete RTX 3090**, and concluded `cuda_ndt` could not initialise. Measured
here for the first time, on the Orin:

| phase | before | after |
|---|---|---|
| startup, 100 particles batched | 42178 ms | **2984 ms** |
| TPE, 100 particles serial | 6898 ms | **6020 ms** |
| **total align** | **49.1 s** | **9.0 s** |
| result | converged, 3.205, reliable | converged, 3.199, reliable |

The Orin now beats the desktop figure by 3.9x.

**What the phase split gave away.** The startup phase costs 422 ms per particle
against 69 ms for the *serial* TPE phase beside it. A batched path six times
slower per item than the sequential one is not a tuning problem, it is a defect.

`align_batch_gpu` ended every particle with `compute_nvtl` on the CPU — the same
serial per-point KD-tree pass taken off the per-scan path earlier, still present
here and run once per particle. At `n_startup_trials: 100` that was 42.2 s of the
49.1 s.

It was redundant twice over: the initial-pose estimator ignores
`AlignResult::nvtl` and recomputes NVTL itself immediately afterwards, which is
the 1192 ms the phase line reports separately. The optimizer now defers NVTL to
the matcher exactly as it does for `align_full_gpu`, and the matcher scores each
aligned pose on the GPU so the field stays meaningful for callers that do read it.

**A second duplicate, in both particle loops.** Each one called `evaluate_nvtl`
on `align_result.pose` immediately after aligning to it — but `align` already
scores NVTL at exactly that pose, on the GPU, and fills `AlignResult::nvtl`. The
loops were recomputing a number they already held: 887 ms across the TPE
particles and 519 ms across the startup ones.

**Where the 9.0 s actually goes.** The TPE log now carries a phase breakdown,
which is what found the above:

| TPE phase, 100 particles | |
|---|---|
| the alignments | 4412 ms |
| `get_next_input` (the TPE sampler) | 1603 ms |
| NVTL | 0 ms |
| bookkeeping | 5 ms |

The sampler is CPU, ~16 ms per call, and it grows with the trial count because
the KDE is rebuilt over every previous trial. Neither it nor the alignments are
redundant work — reducing them means changing what the search does, not deleting
a duplicate. The startup phase does the same alignments batched at 30 ms each
against TPE's 44 ms, but TPE is sequential by construction: each trial's
sampling depends on the previous result.

**`pose_source:=cuda_ndt` initialises and tracks.** Verified end to end with the
user-defined initial pose disabled: `align server succeeded.` → `EKF Activation
succeeded` → `NDT Activation succeeded`, then 263 poses over 129.4 m at 32.8 ms
and NVTL 3.131. That was the last piece of the CUDA path still unverified on this
hardware.

## `pointcloud_backend`: what CUDA actually costs and saves

Measured on the Orin for the first time. The existing figure for this stage
(0.035 m scatter p95 over ~600 m) is a *localization-quality* number from an x86
desktop, and it says nothing about utilisation.

Autoware's sample bag through `logging_simulation.launch.yaml` with
`sensor_model:=sample_bag_sensor_kit`, which carries both modes. Two runs per
backend, 31 s windows, 63 tegrastats samples each.

**Throughput first, because the rest is meaningless without it.** Both backends
deliver the same work:

| | cpu | cuda |
|---|---|---|
| `top/pointcloud_before_sync` | 299, 299 | 298, 299 |
| `concatenated/pointcloud` | 367, 370 | 356, 361 |
| bag duration | 29.74 s | 29.76 s |

**The comparison**, re-measured under play_launch 0.9.0 through the justfile's
own invocation (`--container-mode observable`), two runs per backend:

| | cpu | cuda | delta |
|---|---|---|---|
| `pointcloud_container` CPU | 127.8%, 131.5% | 104.8%, 107.1% | **−23.7 pts (−18%)** |
| system CPU, 12-core mean | 76.9%, 75.4% | 76.4%, 75.7% | ~0 |
| **GPU `GR3D_FREQ`** | 2.0%, 2.7% | 37.5%, 33.5% | **+33.1 pts** |
| `VDD_GPU_SOC` | 4347, 4305 mW | 4797, 4784 mW | +465 mW |
| `VDD_CPU_CV` | 10158, 10093 mW | 10205, 10139 mW | +46 mW (noise) |

The first pass, under play_launch 0.5.1 without `--container-mode`, gave
−25.5 pts / +30.7 pts / +617 mW. Same conclusion, and the two sets of absolute
numbers do not compare — see *What changed between the two passes* below.

So the CUDA path **trades about a quarter of a core for about a third of the
GPU, and roughly half a watt**, at equal throughput.

**Use tegrastats, not play_launch, for GPU on Tegra.** Every `gpu_*` column in
play_launch's `system_stats.csv` is empty here and its resource monitor logs
`GPU process enumeration not supported on this system`. `GR3D_FREQ` from
`tegrastats` is what actually reads the iGPU, and it is system-wide rather than
per-process — which is adequate for an A/B where the backend is the only
variable, and inadequate for anything else.

### Reading these numbers honestly

- **System CPU does not move.** The stage is a small part of a 161-node stack,
  and at 73% the machine was not CPU-bound, so freeing a quarter core changed
  nothing observable. The saving is real and it is only worth having on a
  configuration that is actually CPU-limited.
- **`pointcloud_container` is not just the pipeline.** It also holds
  CenterPoint, ground filtering, clustering and the occupancy grid. Only the
  *delta* is attributable to the backend, since everything else in the container
  is identical between runs. The absolute 90-120% figures are not "the
  preprocessing chain".
- **This is not the cart's sensor set.** The sample bag carries three Velodynes
  and all three are preprocessed. On the golf cart only the Velodyne goes
  through this stage -- the Seyond publishes `PointXYZIRC` with no per-point
  time and cannot be deskewed by either backend -- so the CPU saving there will
  be smaller than a third of what is measured here.
- The CPU concatenator published marginally more clouds (367/370 against
  356/361, ~2.5%). Not investigated.

### What changed between the two passes

The delta held; the absolutes moved, and the process topology moved with them.

`ndt_scan_matcher` is the largest consumer in the second pass at **~140% CPU in
all four runs**, and it did not appear at all in the first — where nothing
outside `pointcloud_container` exceeded 60%. The node is the same and it was
running both times. What changed is that `--container-mode observable` is now
actually accepted, so composable nodes are hosted differently and per-process
attribution lands differently.

The lesson is narrow and worth keeping: **absolute per-process CPU from
play_launch is a function of its container mode, not just of the code.** Compare
deltas within one configuration; do not compare absolutes across configurations.

### Correction: that ~140% is not cuda_ndt

An earlier revision of this document read the ~140% as `cuda_ndt` and called it
unexplained, since 30.7 ms per frame at 10 Hz is 31% duty and 1.4 cores is far
more than that accounts for. **It is not cuda_ndt.** Every one of those four
runs was running Autoware's C++ node:

```
$ head -c 80 play_log/*/node/ndt_scan_matcher/cmdline
/opt/autoware/1.5.0/lib/autoware_ndt_scan_matcher/autoware_ndt_scan_matcher_node
```

`logging_simulation.launch.yaml` defaults `pose_source: ndt`, and says why —
*"cuda_ndt is asked for by name"*. The measurement never asked. The node is
called `ndt_scan_matcher` under either setting, which is what made the
misreading easy: the process name says which algorithm only if you look at
`cmdline`.

Nothing else in that section is affected. The pointcloud A/B varies
`pointcloud_backend`, not `pose_source`, and both arms ran the same C++ NDT.

**And the 140% is not anomalous.** Sampling that process per-thread shows four
threads at ~31% each — pclomp's OpenMP pool, `num_threads: 4` in the NDT
parameters. Multi-threaded CPU NDT costing about four threads is the design
working, not a defect.

### cuda_ndt's own CPU, and whether it spins

Measured in `cuda_ndt_matcher`'s own replay harness, which tracks correctly, with
alignment confirmed from the node's `Callback stats` line — 50 alignments inside
the 20 s window, and no warnings in the log for that period:

| | |
|---|---|
| total | **40.0%** of one core |
| main thread | 21.3% |
| ~13 runtime pool threads | ~1.3% each |
| DDS `recvMC` | 0.7% |

**It does not busy-wait on the GPU.** No thread is pegged; the cost is spread
across the cubecl/CUDA pool in small slices. A spin-wait would show at least one
thread at or above the alignment's duty cycle, and none is.

What this does **not** establish is a CPU ratio between the two matchers. A
matched pair needs both running the same harness, at the same playback rate,
both verifiably tracking, and several attempts diverged instead — one Autoware
run covered 2.3 m of the route rather than 129.8 m while reporting plausible
per-frame numbers. Anyone wanting that ratio should check the recorded path
length before trusting a CPU figure.

### Profiling on this hardware

`perf` is not usable: `/usr/bin/perf` is the Ubuntu wrapper and reports
`WARNING: perf not found for kernel 5.15.148`, wanting `linux-tools-5.15.148-tegra`,
for which apt has no candidate. The numbers above come from sampling
`/proc/<pid>/task/*/stat` instead, which gives per-thread CPU but no symbols.

Three traps when scripting this, all of which produced a wrong PID or none:

- `comm` truncates at 15 characters, so the process is `cuda_ndt_matche`, and
  `pgrep -x cuda_ndt_matcher` never matches.
- The map path contains `cuda_ndt_matcher`, so `pgrep -f cuda_ndt_matcher`
  matches play_launch and the harness script instead of the node.
- `ros2 topic echo` cannot see these nodes here — the same daemon problem that
  defeats `ros2 topic list`. Detect activity from the node's own log.

### A measurement that was wrong, and why

The first attempt reported `pointcloud_container` at 117.7% -> 38.6%, a 3x
reduction. That was an artifact: stale `play_launch` stacks from earlier runs
had survived their SIGINT and were still competing for the same 12 cores, and
the load average was 278 when the "measurement" ran. The clean figure is
117.9% -> 91.5%, a 1.29x reduction.

The harness now refuses to start if any `play_launch`, `component_container` or
`ros2 bag` process is alive, and waits for the load average to fall below 6
before opening its window. On a shared 12-core box that guard is not optional --
without it the numbers are confidently wrong rather than noisy.

The guard is still needed under 0.9.0: every run in the second pass left **three
play_launch processes alive 25 seconds after SIGINT**, so the survival is not a
0.5.1 defect. Match on `comm` when checking -- `pgrep -f play_launch` also
matches the shell running the check.

## What is still unmeasured here

- Anything on the vehicle. This is the sample map and sample bag, not NTU or
  COSS, and not the golf cart's own sensors.
- `pointcloud_backend:=cuda` *localization quality* on this hardware. Its
  utilisation is now measured (above), but the 0.035 m scatter figure is still
  the desktop's, and it was taken on the NTU CSIE-1 bag, whose Velodyne stream
  is now known to be unreliable.
- GPU utilisation. play_launch reports
  `GPU process enumeration not supported on this system` on Tegra, so the cost
  side of the GPU move is still not observable on the target — item 6 of the
  previous handover, unchanged.
