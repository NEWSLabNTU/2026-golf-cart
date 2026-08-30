# Related work: localizing on a narrow-FOV, dense LiDAR

Literature survey for the Seyond Robin-W question — a sensor that sees a 120 by
70 degree wedge but samples it far more densely than the spinning LiDAR this
stack was tuned on. Companion to
[restricted-fov-ndt.md](restricted-fov-ndt.md), which measures what our own NDT
does, and to
[ndt-revisions-for-narrow-fov.md](ndt-revisions-for-narrow-fov.md), which says
what to change.

Read, not reproduced. Where a paper's numbers touch ours, that is said and the
comparison is made explicit.

## Someone else ran our experiment, and got the same shape of answer

The most directly comparable result is an **ablation over LiDAR field of view**
in [Sequential Autonomous Exploration-Based Precise
Mapping](https://arxiv.org/pdf/2503.17005), which evaluates 90, 180 and 360
degrees and reports 360 as **1.34x** the accuracy of 180 and **2.94x** that of
90.

Ours, from the TIERS Ouster OS0-128 arm, three runs each, median error against a
full-sensor reference:

| field of view | ours | ratio to full | their ratio |
|---|---|---|---|
| full circle | 0.050 m | 1.00x | 1.00x |
| 120 deg (Robin-W) | 0.082 m | 1.64x | — |
| 90 deg | 0.117 m | 2.34x | 2.94x |

Different sensor, different site, different pipeline, and the degradation at 90
degrees lands within 25% of theirs. That is worth more than either number alone:
**the shape of the curve is not an artifact of our harness.** It also puts the
Robin-W's 120 degrees where we measured it, in the gentle part of the curve
rather than near the cliff.

Two related findings from the same area:

- The same work reports that the value of **stepwise, consistent motion rises as
  FOV falls** — a narrow sensor is less forgiving of aggressive manoeuvres. Our
  route is a slow golf cart, which helps.
- [Scan Context degrades when the FOV is
  restricted](https://arxiv.org/pdf/2503.17005). That is a place-recognition
  descriptor, so it does not affect our tracking, but it does affect **global
  relocalization**: whatever the golf cart eventually uses to recover from a
  lost state should not be assumed to survive the sensor change.

## Degeneracy: the mechanism, and the state of the art

This is the line of work behind the monitor now in `cuda_ndt_matcher`
(`src/cuda_ndt_matcher/src/node/degeneracy.rs`).

**[X-ICP](https://arxiv.org/pdf/2211.16335)** is the reference for
localizability-aware registration: it analyses, per constraint, whether the
geometry actually observes each degree of freedom, and constrains the
optimization accordingly rather than letting it drift along unobserved
directions. **[LP-ICP](https://arxiv.org/html/2501.02580)** extends the same idea
to point-to-line correspondences for unstructured environments.

**Read [Informed, Constrained, Aligned](https://arxiv.org/pdf/2408.11809) before
implementing any of it.** It is a field analysis of degeneracy-aware
registration and its criticism lands squarely on the obvious implementation:
solution remapping "depends on heuristic tuning of thresholds for operation in
different environments", and **a single threshold cannot serve both translation
and rotation**. That is the same units argument our own monitor is built around,
arrived at independently — which is why it reports the translation and rotation
blocks separately and refuses to combine them into one condition number.

It also explains why the monitor ships **logged but not gated**. A threshold is
site-specific and nobody here has measured one; the literature says a badly
chosen one is actively harmful rather than merely useless.

**[SuperLoc](https://arxiv.org/pdf/2412.02901)** moves from detecting degeneracy
after the fact to *predicting alignment risk* before committing to a result.
**[Degeneracy Sensing LiDAR-Inertial
SLAM](https://www.researchgate.net/publication/399091026_Degeneracy_Sensing_Light_Detection_and_Ranging-Inertial_Simultaneous_Localization_and_Mapping_with_Dual-Layer_Resistant_Odometry_and_Scan-Context_Loop-Closure_Detection_Backend_in_Diverse_Environments)
uses Fisher information to grade degeneracy and then **adapts the downsampling
rate** to it — interesting for us because it spends compute where the geometry is
weak instead of uniformly, and our voxel downsample is currently fixed.

## The small-FoV LiDAR lineage: what was tried, and what won

**[LOAM-Livox](https://arxiv.org/pdf/1909.06700)** is the origin point, written
for the Livox MID-40 and explicit that the problem is "feature extraction and
selection in a very limited FoV". Its framing of the difficulty still holds:
**a small FoV and a non-repetitive scan pattern together leave very few
correspondences between consecutive scans**, per
[FF-LINS](https://arxiv.org/pdf/2307.06632).

What won, though, was **not** better feature extraction. The direct methods did:

- **[FAST-LIO2](https://arxiv.org/pdf/2107.06829)** — an error-state iterated
  Kalman filter that registers raw points to a map without extracting features
  at all, with a Kalman-gain formulation that keeps large clouds tractable.
- **[Point-LIO](https://advanced.onlinelibrary.wiley.com/doi/10.1002/aisy.202200459)**
  — point-by-point update rather than frame-by-frame, which removes the
  in-frame motion assumption entirely.
- **[Voxel-SLAM](https://arxiv.org/html/2410.08935v1)** and
  **[Traj-LO](https://arxiv.org/pdf/2309.13842)** — the latter arguing
  continuous-time trajectory estimation is enough without an IMU, which is the
  contrarian position in this set and worth knowing exists.

**This matters for our choice of estimator.** NDT models local distributions
rather than extracting features, so it is already on the winning side of that
split — the golf cart does not need to abandon it to follow the literature. What
the literature is unanimous about instead is *where the fusion happens*: these
systems fuse the IMU **inside** the estimator, whereas Autoware registers with
NDT and fuses afterwards in `ekf_localizer`.

Our own data is a sharp demonstration of why that matters. On the TIERS rig,
which has no wheel odometry, the identical configuration gave median errors of
4.4 m, 7.3 m and 0.13 m across three runs — the prior was the whole story. Adding
a twist source collapsed the spread to a millimetre. That is the loose-coupling
weakness the LIO line exists to remove.

## Prior-map localization, which is our actual problem

Most of the above is odometry. We have a map, which is a different and easier
problem, and the directly applicable work is **[Tightly Coupled Range Inertial
Localization on a 3D Prior Map](https://arxiv.org/pdf/2402.05540)**: a sliding
window factor graph over a prebuilt map with LiDAR and IMU. Same inputs as ours,
same goal, and a window of frames instead of one-shot registration — a direction
unobserved in one frame is usually observed a second later.

It is also the least foreign option available: it comes out of the same research
lineage as much of Autoware's own localization.

## Treating a dense LiDAR like a camera: the literal version

The working intuition that a dense narrow LiDAR resembles a camera has a literal
implementation in the literature, not just an analogy.

**[Revisiting LiDAR Registration and Reconstruction: A Range Image
Perspective](https://arxiv.org/pdf/2112.02779)** projects the cloud into a range
image under a spherical model and registers multi-scale in image space. This
only pays off when the sensor is dense enough that the projection is not mostly
holes — which is exactly the regime the Robin-W is in at 0.15 by 0.36 degrees and
1.28 M points/s, and exactly the regime a VLP-32C is *not* in. If the golf cart
ever wants a fundamentally different matcher rather than a tuned NDT, this is
where the sensor upgrade actually opens a door.

[Panoramic Direct LiDAR-assisted Visual Odometry](https://arxiv.org/pdf/2409.09287)
is adjacent and worth a look if the ZED camera ends up carrying weight.

See [narrow-fov-localization-methods.md](narrow-fov-localization-methods.md) for
where the camera analogy holds and where it breaks — the short version is that it
holds for conditioning and breaks for scale, in our favour.

## Fallbacks when the geometry genuinely is not there

Worth knowing these exist, because the honest answer to a degenerate corridor is
sometimes "add information" rather than "estimate better".

- **[Artificial landmark enhanced LiDAR odometry for small-FoV
  LiDARs](https://www.cambridge.org/core/journals/robotica/article/artificial-landmark-enhanced-light-detection-and-ranging-lidar-odometry-and-mapping-for-lidars-with-a-small-field-of-view/E3213932A9665BA36C7FDCAB7769509C)**
  — reflectors placed in degraded regions, with reflector residuals folded into
  the LOAM cost. Directly analogous to this project's own ArUco indoor
  localization work, but using the LiDAR's intensity channel rather than a
  camera, which would suit a sensor with no camera overlap.
- **Regularization from an external prior.** Autoware already implements this and
  it is switched off here; see the Tier 1 section of
  [ndt-revisions-for-narrow-fov.md](ndt-revisions-for-narrow-fov.md).

## Data

**[Lidar Variability: A Novel Dataset and Comparative Study of Solid-State and
Spinning Lidars](https://arxiv.org/html/2507.04321)** is the closest thing to
what this campaign needed and did not have: a dataset built specifically to
compare solid-state against spinning sensors. Worth evaluating before recording
anything ourselves — it may remove the need to emulate a Robin-W at all.

The [TIERS multi-modal dataset](https://github.com/TIERS/tiers-lidars-dataset)
used here carries both modalities on one rig but ships no prior map;
`scripts/localization/restricted_fov/` builds one.

Still no public Seyond recording with a map. The decisive test remains a
recording from the actual sensor on the actual route.

## What to read first

If only one: [Informed, Constrained,
Aligned](https://arxiv.org/pdf/2408.11809), because it is the one that would
stop us implementing a thresholded degeneracy gate badly.

Then [Tightly Coupled Range Inertial Localization on a 3D Prior
Map](https://arxiv.org/pdf/2402.05540) as the concrete upgrade path, and
[FAST-LIO2](https://arxiv.org/pdf/2107.06829) for why tight coupling is the
baseline rather than an enhancement.
