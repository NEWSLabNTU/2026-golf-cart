# Designing a Robin-W localization pipeline on Autoware

Ranked directions for making Autoware localize well on a Seyond Robin-W — a
sensor that is **narrow and dense**, 120 by 70 degrees at over 1.28 M points/s
and 0.15 by 0.36 degree resolution. General pipeline design, not this vehicle's
current maintenance backlog; that is in
[ndt-revisions-for-narrow-fov.md](ndt-revisions-for-narrow-fov.md).

Sequenced with decision points in
[docs/roadmaps/6-robinw-localization.md](../../roadmaps/6-robinw-localization.md).

Every direction below is **evaluable now on existing dense-LiDAR rosbags**, with
no Robin-W recording. What each bench can and cannot answer is at the bottom.

Two measured results shape the whole ranking:

- **A 120 by 70 degree forward wedge already works.** 0.082 m median against
  0.050 m for a full sensor, on a third of the points, heading unchanged. So this
  is a design problem, not a rescue.
- **The prior dominated the field of view by two orders of magnitude.** Without a
  twist source, one configuration gave 4.4 m, 7.3 m and 0.13 m across three
  identical runs; with one, three runs agreed to a millimetre. Anything that
  strengthens or protects the prior outranks anything that sharpens the matcher.

Both from [restricted-fov-ndt.md](restricted-fov-ndt.md). Papers in
[narrow-fov-related-work.md](narrow-fov-related-work.md).

| # | direction | kind | cost | testable on |
|---|---|---|---|---|
| 1 | per-point time, so the cloud can be deskewed | plumbing | **low** | any bag with per-point time |
| 2 | anisotropic covariance into the EKF | NDT revision | **one line** | any |
| 3 | spend the density deliberately | NDT revision | a sweep | dense bags |
| 4 | degeneracy-aware update | NDT revision | medium | any, needs degenerate stretches |
| 5 | VGICP in place of NDT | new method | medium | any |
| 6 | sliding-window prior-map localization | new method | high | any with IMU |
| 7 | range-image direct matching | new method | high | dense bags only |
| 8 | relocalization under a narrow FOV | parallel track | medium | any with revisits |

## 1. Get per-point timestamps, and deskew

**This is cheaper than this repo currently believes.** `CLAUDE.md` and
`docs/research/sensing/autoware-cuda-pointcloud-chain.md` both say the Seyond
publishes `PointXYZIRC` with no per-point time and that fixing it needs a vendor
driver change. The vendor driver already ships the field:

```c++
struct EIGEN_ALIGN16 PointXYZIT {
  PCL_ADD_POINT4D;
  double timestamp;          // per point
  float intensity;
  std::uint8_t flags, elongation;
  std::uint16_t scan_id, scan_idx;
  std::uint8_t is_2nd_return;
};
```

`PointXYZIT` is the driver's **default**, selected by `POINT_TYPE` in its
CMakeLists. What is missing is not the measurement but the conversion into
Autoware's `PointXYZIRCAEDT`, whose `time_stamp` is an offset from the scan start
rather than an absolute double. That is arithmetic plus a field mapping, and
azimuth/elevation/distance are derivable from xyz or from `scan_id`/`scan_idx`.

Why it ranks first for a **dense** sensor specifically: undeskewed points smear
by roughly speed times scan period, about 0.28 m at 10 km/h and 10 Hz. The
Robin-W's entire advantage is resolving fine structure, and 0.28 m of smear
erases structure far finer than that. Buying a sensor with 0.15 degree resolution
and then feeding NDT a smeared cloud spends the money without collecting the
benefit — and the errors being chased here are 0.08 m.

It is also a precondition for several items below, and it is plumbing rather than
research.

**A second, separate gap sits in front of it.** `NEWSLabNTU/seyond_ros_driver`
already emits Autoware's `PointXYZIRC` (`8e99e38`), and gets the struct layout
right, but registers the field *names* as `I`, `R`, `C`:

```c++
(std::uint8_t, intensity, I)
(std::uint8_t, return_type, R)
(std::uint16_t, ring,      C)
```

Autoware compares them literally — `field_intensity.name == "intensity"`,
`"return_type"`, `"channel"` — in
`autoware_pointcloud_preprocessor/src/utility/memory.cpp`. All three fail, so the
Seyond cloud is refused by every preprocessing node **today**, with or without a
timestamp. Three string literals and renaming `ring` to `channel`. The header's
own comment asserts the names match Autoware, which is presumably why it went
unnoticed.

**Test:** ablate the distortion corrector on any dense bag that carries per-point
time, at several speeds. The effect should grow with speed and with how fine the
map's voxels are.

## 2. Give the EKF an anisotropic covariance

`covariance_estimation_type: 0` — FIXED_VALUE — in both our
`cuda_scan_matcher.param.yaml` and Autoware's own. Every pose carries the same
hardcoded covariance whatever the scan actually constrained.

On a full circle that approximation is tolerable because the geometry constrains
most directions most of the time. On a forward wedge it is the wrong lie in the
worst direction: the filter is told the along-track axis, which a forward wedge
constrains worst, is as trustworthy as the across-track one, and then corrects the
axis NDT knew least about.

Options `1` (Laplace, from the Hessian already computed), `2` and `3` (multi-NDT)
exist upstream. Laplace is nearly free.

This is the highest value-per-unit-effort item on the list. It does not make the
matcher better; it makes the **rest of the pipeline correctly sceptical of the
matcher** exactly when the wedge faces nothing — which, given that the prior
dominates, is where the leverage is.

**Test:** any bag. Compare EKF output against a reference with the setting on and
off; the improvement should concentrate in the along-track axis.

## 3. Decide, deliberately, what the density is for

A Robin-W puts over 1.28 M points/s into a quarter of the azimuth. The current
`resolution: 2.0` and the downsample chain were chosen for a 360-degree
Velodyne, so points per voxel changes substantially — and NDT is
[unusually sensitive to voxel resolution](https://arxiv.org/pdf/2003.12841).

There are three distinct choices hiding here, and they should be made rather than
inherited:

- **Voxel resolution.** More points per voxel means better-conditioned
  distributions; finer voxels become affordable in a way they are not on a
  32-line sensor.
- **How much to keep.** The downsample rate is currently uniform. A denser
  sensor makes discarding cheap and keeping expensive; the question is whether
  the extra points buy accuracy or only cost time.
- **Where to keep it.** Uniform downsampling is not obviously right for a wedge.
  Spending points on the directions that constrain the pose worst is the idea
  behind Fisher-information-driven downsampling.

Rank three because it is cheap and because it is work that exists **only because
we are on NDT**; a resolution-robust matcher such as VGICP removes the first of
the three questions entirely. Score on pose quality, never NVTL — in this campaign
the worst configuration measured scored the highest NVTL of any restricted run.

**Test:** sweep resolution and keep-fraction on a dense bag. `fov_bake_bag.py`
already has `--keep-fraction` for the second axis.

## 4. Make the update degeneracy-aware

The narrow-FOV-specific algorithmic fix, and the pieces are already in place: the
matcher publishes per-frame conditioning of both Hessian blocks
(`cuda_ndt_matcher/src/node/degeneracy.rs`).

The step is to act on it — [X-ICP](https://arxiv.org/pdf/2211.16335) and
[LP-ICP](https://arxiv.org/html/2501.02580) constrain the optimization along
directions the geometry does not observe, instead of letting it drift there.

**Read [Informed, Constrained, Aligned](https://arxiv.org/pdf/2408.11809) first.**
Its criticism is aimed squarely at the naive implementation: thresholds need
per-environment tuning and one threshold cannot serve translation and rotation
together. That is why our monitor already separates the blocks, and why it ships
logged rather than gated.

A softer variant worth considering before the hard one: rather than refusing to
update along a weak direction, **inflate the covariance along it** and let the
EKF arbitrate. That is item 2 generalized from the whole pose to a per-axis
weighting, needs no change to the optimizer, and fails more gracefully.

**Test:** needs bags with genuinely degenerate stretches — corridors, tunnels,
open ground. Most dense-LiDAR datasets are indoor or urban and do have them.

## 5. Swap the matcher: VGICP

The cheapest probe of "is NDT the right matcher here at all".
[VGICP](https://staff.aist.go.jp/shuji.oishi/assets/papers/preprint/VoxelGICP_ICRA2021.pdf)
is reported as accurate as GICP, faster, and **robust to voxel resolution** — it
deletes item 3's first question rather than answering it. GICP-family methods
generally beat NDT on accuracy in
[benchmarks](https://arxiv.org/pdf/2003.12841).

Against it: NDT is what Autoware ships, what this project's CUDA work
accelerates, and what the parameters and operational experience are built around.
A swap spends that.

Rank five because it is a genuine fork in the road and the evidence favouring it
is generic rather than narrow-FOV-specific. Nothing measured here says VGICP
handles a wedge better than NDT — that is precisely the comparison to run.

**Test:** `data/tiers/baked_odo/` holds one sequence at four fields of view and
`compare_to_reference.py` scores anything against a common trajectory. A
candidate only needs to consume a bag and emit poses.

## 6. Sliding-window prior-map localization with tight coupling

The structural fix, and the one the literature is most unanimous about: fuse the
IMU **inside** the estimator rather than registering with NDT and fusing
afterwards in `ekf_localizer`. For a prior map the concrete form is [sliding
window factor graph optimization](https://arxiv.org/pdf/2402.05540), which also
addresses the narrow-FOV problem directly — a direction unobserved in one frame
is usually observed a second later, and a window recovers what frame-by-frame
registration discards.

This is the direction with the strongest theoretical case for a narrow sensor and
the highest integration cost, because it replaces the pose-estimator/EKF split
rather than a component inside it. It is also the item our own instability result
argues for most sharply: the prior was the whole story, and this is the direction
that stops treating the prior as an afterthought.

**Test:** any dense bag with an IMU. Should show its advantage most where item 4
would have fired.

## 7. Range-image direct matching

The literal version of "a dense narrow LiDAR resembles a camera": project into a
range image under a spherical model and register in image space
([Revisiting LiDAR Registration and Reconstruction](https://arxiv.org/pdf/2112.02779)).

This only pays off when the projection is not mostly holes — a regime a VLP-32C
is not in and a Robin-W is. **It is the one direction where the sensor upgrade
opens a door that was previously shut**, rather than mitigating a loss.

Ranked last among the methods because it is the least proven inside an Autoware
pipeline, has no existing integration, and would be a research project rather
than an integration. Worth a literature-backed prototype, not a roadmap
commitment.

**Test:** dense bags only, and the comparison against items 5 and 6 is what
decides whether density is better spent on a different representation or on the
same one.

## 8. Relocalization, as a parallel track

Separate subsystem, separate failure, and it does not compete with 1-7 for the
same effort.

Scan Context, the standard descriptor for place recognition, [degrades under a
restricted field of view](https://arxiv.org/pdf/2503.17005). Initial-pose
estimation has the same problem from the other end: a narrow wedge discriminates
less well between candidate poses, so a Monte Carlo search over particles has a
flatter objective.

Everything in this campaign measures **tracking**, with a seeded initial pose.
Nothing here says how the vehicle acquires or recovers a pose on a Robin-W, and
that should not be inherited from full-circle results.

**Test:** any dataset with revisits; score recall at a fixed precision as the
field of view narrows.

## Test benches

All of these are proxies. A Robin-W emulated by cropping something else is
poorer than the real sensor on point rate and scan pattern, which makes results a
lower bound. The limits are written up in
[restricted-fov-ndt.md](restricted-fov-ndt.md).

| bench | gives | cannot answer |
|---|---|---|
| **TIERS OS0-128** (`road01`, prepared, in `data/tiers/`) | 360 x 90 degrees, so both axes croppable to Robin-W spec; four baked fields of view; a reference trajectory and a prior map | outdoor driving speeds; it is a slow trolley, so deskew barely matters here |
| **Autoware sample bag** (prepared) | a known-good Autoware pipeline, vehicle speeds | vertical FOV — its VLS128 spans 40 degrees, narrower than a Robin-W |
| **Livox Horizon / Avia** (TIERS, same rig) | a genuine non-repetitive solid-state scan pattern | field of view — both are narrower than a Robin-W, so nothing can be cropped *to* it |
| [**Lidar Variability**](https://arxiv.org/html/2507.04321) | built to compare solid-state against spinning; not yet evaluated here | unknown until read |
| **Hilti / urban driving sets** | degenerate geometry at speed, which items 1 and 4 need | sensor is spinning, so density must be emulated by discarding |

The gap none of them closes is **a dense narrow sensor at vehicle speed on the
deployment route**. That is one recording once the hardware is mounted, and it is
worth making early — it is the only thing that turns every result above from a
lower bound into a measurement.

## If you only do three

1, 2 and 5. The first collects the resolution the sensor was bought for, the
second is the highest leverage per line changed, and the fifth answers whether
the rest of this list should be about NDT at all.
