# CUDA NDT on the Orin: the build fix, and what the CUDA path actually costs

**Written**: 2026-08-30, on the target hardware.
**Measured on**: NVIDIA Jetson AGX Orin Developer Kit, JetPack 6.2 (R36.4.4),
CUDA 12.6, driver 540.4.0, 12 cores, 61 GB shared LPDDR5, `nvpmodel` MAXN.
Supersedes the parts of
[2026-08-30-cuda-pipeline-to-orin.md](2026-08-30-cuda-pipeline-to-orin.md)
that were written from an x86 desktop and guessed at this hardware.

---

## The headline

`pose_source:=cuda_ndt` **is not a convergence problem.** It localises correctly
and agrees with Autoware's NDT to **2.8 cm RMSE** over a full replay.

It is a throughput problem, and only that. It takes **415 ms per frame where
Autoware takes 47 ms** — 8.8x slower, and 4.2x over its own configured
`critical_upper_bound_exe_time_ms` of 100 ms. Everything that looked like a
convergence failure follows from that one number.

`pose_source:=ndt` remains the setting to run on the vehicle.

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

| | Autoware NDT | CUDA NDT |
|---|---|---|
| `exe_time_ms` mean | **47.0** | **415.3** |
| `exe_time_ms` max | 82.7 | 480.5 |
| NVTL mean | 3.126 | 3.138 |
| transform probability mean | 6.71 | 6.78 |
| iterations mean | 3.13 | 2.68 |
| initial-to-result distance mean | 0.090 m | 0.080 m |
| poses / path | 244 / 129.3 m | 291 / 126.9 m |

Trajectory agreement against the Autoware run, over 242 matched stamps:

| | |
|---|---|
| 2D RMSE | **0.0277 m** |
| mean / p50 | 0.0219 m / 0.0161 m |
| p95 / max | 0.0559 m / 0.1022 m |
| \|dz\| mean / max | 0.0039 m / 0.0237 m |

The integration suite's own tolerance is 0.3 m RMSE. This passes with 10x
margin. **On quality, the CUDA path is equivalent to Autoware's NDT** — slightly
fewer iterations and a slightly smaller correction per frame, which is what you
would expect from a matcher that is converging properly.

The CUDA column had to be taken with the bag played at `--rate 0.2`. That is the
whole finding, stated another way.

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

## What to work on

1. **415 ms per frame.** This is the only real problem. It needs a profile on
   this hardware, not on a discrete GPU — the Orin's iGPU shares LPDDR5 with the
   CPU, so the desktop's numbers do not bound it. Note the frame cost is
   remarkably flat (min 383 ms, max 480 ms over 291 frames) and iteration count
   is low at 2.68, which points at fixed per-call overhead rather than at the
   optimiser doing too much work.
2. Only after that is the initial-pose align worth revisiting. The previous
   handover's 35.3 s align figure was measured on x86 with `particles_num: 200`;
   whatever fixes the per-frame cost likely moves it too.
3. `pose_source` should not default to `cuda_ndt` while (1) stands. It cannot
   hold 10 Hz, and the way it fails is silent.

## What is still unmeasured here

- Anything on the vehicle. This is the sample map and sample bag, not NTU or
  COSS, and not the golf cart's own sensors.
- `pointcloud_backend:=cuda` on this hardware. The 0.035 m figure in the
  previous handover is from the desktop.
- GPU utilisation. play_launch reports
  `GPU process enumeration not supported on this system` on Tegra, so the cost
  side of the GPU move is still not observable on the target — item 6 of the
  previous handover, unchanged.
