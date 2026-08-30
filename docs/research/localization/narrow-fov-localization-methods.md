# Localizing on a narrow-FOV, high-density LiDAR

Written alongside [restricted-fov-ndt.md](restricted-fov-ndt.md), which measures
what plain NDT does when the horizon is cut down to a Seyond Robin-W's 120
degrees. This one is about what to *build* if that margin turns out to be too
thin, and about whether the working intuition -- that a narrow, dense LiDAR
should be treated like a camera -- holds up.

Everything here is read, not measured. The measurements are in the other
document. Where the two touch, that is said explicitly.

## The camera analogy is half right, and the half that fails is the useful half

The similarity is real and it is about **conditioning**. A sensor that sees 120
degrees of a scene constrains the pose it is solving for much less evenly than
one that sees all of it. A full-circle spinning LiDAR observes structure on
every side, so translation and heading are constrained by surfaces facing many
directions at once. Restrict it to a wedge and the constraint geometry starts to
look like a camera's: strong across the view, weak along it, and liable to
collapse entirely when the wedge happens to face something without structure --
a corridor, a tunnel, an open field, a blank wall. That is the same failure a
monocular front-facing camera has in a featureless hallway, and it is why the
techniques that grew up around cameras transfer.

The analogy breaks on **scale and correspondence**, and it breaks in the golf
cart's favour. A camera measures bearing only, so range and absolute scale are
unobservable from one view and have to be recovered by motion, by stereo, or by
a prior. A LiDAR measures range directly at every point. Scale is never in
question, correspondences are metric rather than photometric, and none of the
machinery cameras need to bootstrap depth is required here. The hardest problem
in visual localization simply does not arise.

So: **borrow the camera world's conditioning techniques, not its estimation
pipeline.** Concretely, the things worth borrowing are tight inertial coupling,
sliding-window estimation over multiple frames instead of one-shot registration,
and explicit detection of the directions the current view fails to constrain.

## What the literature does about it

Narrow-FOV LiDAR localization is not an open problem. It is a solved-enough one,
because the Livox ecosystem has been living with 70-to-80 degree sensors since
2019 and the methods are mature.

**Tight LiDAR-inertial coupling is the baseline, not an enhancement.** The
Livox-era odometry systems fuse IMU and LiDAR inside a single iterated filter
rather than registering a scan and handing the result to a downstream EKF. The
IMU carries the estimate through the moments when the wedge sees nothing that
constrains a given axis, and the scan corrects it when structure returns. This
is precisely the visual-inertial argument, and it is the single biggest
structural difference from what the golf cart runs today: Autoware's chain
registers with NDT and fuses afterwards in `ekf_localizer`, which is looser.

**Degeneracy detection is the specific answer to the specific failure.** The
standard treatment inspects the conditioning of the registration problem itself
-- the eigenstructure of its information matrix -- identifies the directions that
are unconstrained by the current geometry, and declines to update along them
rather than letting the optimizer wander. Recent work extends this from detecting
degeneracy after the fact to predicting alignment risk before committing to a
result. For a narrow FOV this matters more than any amount of parameter tuning,
because the failure is a property of what the sensor can see at that instant, not
of the settings.

**Prior-map localization has a directly applicable form.** Tightly-coupled range
inertial localization on a 3D prior map via sliding-window factor graph
optimization is the same problem this project has -- a prebuilt map, a LiDAR, an
IMU -- solved with a window of frames instead of frame-by-frame registration.
That is the natural upgrade path if NDT's margin proves too thin, and it comes
from the same research group as much of Autoware's own localization work, so it
is not foreign to the stack.

**Feature extraction is the part not to copy.** Early Livox work put effort into
extracting features suited to an irregular scan pattern. The later direct
methods, which match points to local planar structure without extracting
features, outperformed them and are simpler. NDT is already in that family -- it
models local distributions rather than extracting features -- so the golf cart is
on the right side of that split already.

## What this means for the golf cart, concretely

Ordered by cost, and the first item is free because it is already measured.

1. **Point it forward.** Not a method change, a mounting decision, and the
   measurement is unambiguous: at the same 120 degree width, a forward wedge
   gave 0.107 m scatter and a rear-facing one 2.99 m, with a third of the frames
   lost. See the direction table in the companion document.

2. **Watch heading, not position.** Across the forward sweep, position deviation
   grew mildly while frame-to-frame yaw error grew 2.7x. If a narrow FOV breaks
   this vehicle, the first sign will be in heading, so that is what a monitor
   should be gated on.

3. **Add degeneracy monitoring before adding a new estimator.** Knowing *when*
   the wedge is unconstrained is cheap, is diagnostic rather than behavioural,
   and tells you whether steps 4 and 5 are needed at all. It also converts the
   untested caveat in the other document -- that the 130 m sample route may
   simply never present a featureless stretch -- into something observable on the
   real site.

4. **Tighten the IMU coupling** if monitoring shows real degenerate stretches.
   This is the highest-value structural change and the one the literature is
   most unanimous about.

5. **Replace one-shot NDT with a sliding-window prior-map localizer** only if 4
   is insufficient. Largest change, best evidence behind it, no reason to reach
   for it first.

Note that the golf cart already has the CUDA NDT work banked, so per-frame cost
is not the constraint on any of this; the constraint is estimator structure.

## Data to test against

**No public Seyond dataset was found.** Searching for Robin-W or Falcon
recordings paired with a prior map turned up sensor documentation and integration
notes but no dataset. Seyond publishes ROS 1 and ROS 2 drivers, and Clearpath
documents Robin-W integration on their platforms -- which confirms the sensor is
straightforward to record from, and confirms that recording it is something this
project would have to do itself.

Useful substitutes, in order of fit:

- **TIERS multi-modal LiDAR dataset.** The closest available match: it carries
  two genuinely solid-state sensors, Livox Horizon and Avia, alongside spinning
  LiDARs on the same rig, with sub-millimetre motion-capture ground truth indoors
  and outdoor sequences as well. Because the same scene is recorded by both
  modalities at once, it supports the comparison this project actually wants --
  narrow-FOV solid-state against full-circle spinning -- rather than an emulation
  of it. It is odometry-oriented, so a prior map would have to be built from the
  data.
- **Autoware's own datasets**, including the Istanbul set, which exist precisely
  to reproduce map-based localization and ship point cloud maps with the
  recordings. Right pipeline, wrong sensor: spinning LiDAR, so they test the
  stack rather than the FOV question.
- **`Awesome-3D-LiDAR-Datasets`**, a maintained index, for when a more specific
  requirement appears than "solid-state with a map".

The honest conclusion is that the Robin-W question is not fully answerable from
public data. The emulation in the companion document is the best available proxy,
its limits are written down there, and **the decisive test is a recording from
the actual sensor on the actual route**, which is cheap to make once the hardware
is mounted.

## Sources

- [Clearpath: Seyond Robin W sensor spotlight](https://clearpathrobotics.com/blog/2024/08/sensor-spotlight-seyond-robin-w-high-performance-directional-lidar/)
- [Seyond product line](https://seyond.com/products/)
- [Tightly Coupled Range Inertial Localization on a 3D Prior Map Based on Sliding Window Factor Graph Optimization](https://arxiv.org/pdf/2402.05540)
- [SuperLoc: The Key to Robust LiDAR-Inertial Localization Lies in Predicting Alignment Risks](https://arxiv.org/pdf/2412.02901)
- [SS-LIO: Robust Tightly Coupled Solid-State LiDAR-Inertial Odometry for Indoor Degraded Environments](https://www.mdpi.com/2079-9292/14/15/2951)
- [Low-cost solid-state LiDAR/inertial-based localization with prior map for autonomous systems in urban scenarios](https://www.researchgate.net/publication/363698457_Low-cost_solid-state_LiDARinertial-based_localization_with_prior_map_for_autonomous_systems_in_urban_scenarios)
- [A Tightly-Coupled LiDAR-Inertial-Visual SLAM with Enhanced Dual-Subsystem for Limited FoV LiDAR](https://www.researchgate.net/publication/393736902_A_Tightly-Coupled_LiDAR-Inertial-Visual_SLAM_with_Enhanced_Dual-Subsystem_for_Limited_FoV_LiDAR)
- [TIERS multi-modal multi-LiDAR dataset](https://github.com/TIERS/tiers-lidars-dataset)
- [Multi-Modal Lidar Dataset for Benchmarking General-Purpose Localization and Mapping Algorithms](https://arxiv.org/pdf/2203.03454)
- [Autoware Documentation: Datasets](https://autowarefoundation.github.io/autoware-documentation/main/datasets/)
- [Awesome-3D-LiDAR-Datasets](https://github.com/minwoo0611/Awesome-3D-LiDAR-Datasets)
