# Phase 5 — Upstreaming the CUDA preprocessor filters

Contribute `CudaCropBoxFilterNode` and `CudaRandomDownsampleFilterNode` to
`autowarefoundation/autoware_universe`, so this repository stops carrying a local
fork of code that belongs upstream.

Plan and conventions:
[upstreaming-cuda-preprocessor.md](../design/upstreaming-cuda-preprocessor.md).
What exists and where:
[cuda-pipeline-data-flow.md](../design/cuda-pipeline-data-flow.md).

Last updated: 2026-08-31.

**Out of scope: `cuda_ndt_matcher`.** It has its own repository at
`NEWSLabNTU/cuda_ndt_matcher` and is developed there. Nothing about the
localization matcher goes to Autoware.

---

## Status

| | |
|---|---|
| **U0 — fix before the split** | **not started**, and one item may change the pitch |
| **U1 — extract** | **done** — both nodes ported, tested and pushed as two branches on `jerry73204/autoware_universe` |
| **U2 — publish** | **opened as a draft**, [autoware_universe#13301](https://github.com/autowarefoundation/autoware_universe/pull/13301), 2026-08-31. Now waiting on CI and review |

## U0 — fix before the split

Not blocking the extraction, which is why U1 ran first, but blocking a *good*
pull request.

| item | state |
|---|---|
| **Measure what the CUDA chain costs** | Not done. Correctness and equivalence are established; speed is not. "Is it faster?" is the first question a GPU contribution gets, and the answer could be "no" — kernel launches, plus a host-to-device copy at the first stage when sensing is on CPU. |
| **Node-level tests** | Not done. The 12 gtest cases cover the filter classes; parameter validation and the frame-mismatch rejection are unexercised. |
| **Settle the `is_dense` question** | Not done. The CPU concatenator says `False` and the CUDA one `True` on clouds measured clean either way. Needed before filing it as an issue. |
| **Isolate the compatibility parameters** | **Done, by removal.** `output_frame` and `processing_time_threshold_sec` exist only so one parameter file drives both backends downstream; the upstream copy does not declare them. |
| Exercise on the vehicle | Not done. Every number so far is Autoware's 30 s sample bag with three Velodynes. |

## U1 — extract (done)

Branch `feat/cuda-crop-box-filter` off upstream `main`, carrying both nodes.

What the port involved, beyond copying files:

- **Namespace, package and include guards** renamed together —
  `cuda_pointcloud_filters` → `autoware::cuda_pointcloud_preprocessor`, with
  guards following the new path because `ros-include-guard` enforces it.
- **Their directory convention, not ours.** Upstream groups by *category*, not
  by node: the random downsample belongs in `src/cuda_downsample_filter/`
  alongside the voxel grid one, not in a directory of its own. The crop box gets
  a new category.
- **Their CMake idiom.** `.cu` files join `cuda_pointcloud_preprocessor_lib` via
  `cuda_add_library`; `_node.cpp` files join `cuda_pointcloud_preprocessor` via
  `ament_auto_add_library`; each node gets an `rclcpp_components_register_node`
  block under a comment banner. Our `enable_language(CUDA)` is not used.
- **The two compatibility parameters dropped**, as planned.
- **Per-node artefacts** that are easy to miss and that reviewers check first:
  `design/<Node>.node.yaml` in `autoware_system_design_format: 0.3.0`,
  `docs/<node>.md` following the existing pages' section structure, a
  `schema/<node>.schema.json` matching their draft-07 shape, and a row in the
  README's filter table.

- **Tests came too**, which the package had none of. Twelve gtest cases, seven on
  the crop box and five on the downsample, ported with the sources and wired
  through `ament_add_gtest` against `cuda_pointcloud_preprocessor_lib`. Only
  `ament_cmake_gtest` was added to `package.xml`; the existing `BUILD_TESTING`
  block already runs the linters, so the new one does not repeat them.
- **Two branches, not one**, because they are two pull requests:
  `feat/cuda-crop-box-filter` carries the crop box and the test wiring, and
  `feat/cuda-random-downsample-filter` sits on top of it. The second is stacked
  rather than independent because it reuses the first's test target, and the PR
  should say so.

Not ported, and deliberately: the downstream launch integration.
`util.launch.xml` and `localization_pointcloud_backend` stay in this repository.

### What was verified, and how

`colcon build` **cannot configure this package on this machine, before any of my
changes.** The installed Autoware 1.5.0 exports
`autoware_pointcloud_preprocessor::pointcloud_preprocessor_filter_base` with
`INTERFACE_INCLUDE_DIRECTORIES` pointing at `/output/workspace/install/...`, the
path inside the container it was built in, which does not exist here. Checked
against a pristine `git stash` of the upstream tree: it fails identically. This
is the binary install, not the port.

So the four sources were compiled directly, with the include set harvested from
this repository's own working build of `cuda_pointcloud_filters`, and the
tests linked against those objects plus `libcuda_blackboard`. All four compile
clean, `nm` confirms both components register under
`autoware::cuda_pointcloud_preprocessor`, and **all 12 tests pass on the Orin's
GPU** — before and again after reformatting. `clang-format` with upstream's own
`.clang-format` reports no violations.

What that does **not** cover: the package's real link step, the CMake wiring as
CMake sees it, and the launch files. Upstream CI is the first thing that will
exercise those, which is a reason to open the first PR as a draft.

## U2 — publish (opened)

[autoware_universe#13301](https://github.com/autowarefoundation/autoware_universe/pull/13301),
draft, from `jerry73204:feat/cuda-standalone-filters` onto `main` at `afe69ff`.
23 files, +1839 lines, no deletions.

**One pull request, not two.** The nodes were prepared on separate branches and
then collapsed, because splitting them meant stacking the second on the first —
its diff would have carried the first's commit until that merged, showing
reviewers the crop box twice. One review of a coherent pair beats two reviews of
half a capability, and the pair is the point: neither node alone keeps a chain
on the device.

Remaining:

1. **Fix what CI finds.** Nine workflows touch the diff. `dco` and
   `semantic-pull-request` should pass as written; both commits are signed off as
   `aeon <jerry73204@gmail.com>`, and there is deliberately no `Co-Authored-By`
   trailer, because a co-author without their own sign-off is what trips DCO
   bots — the AI assistance is disclosed in the PR body instead. `clang-format`
   was checked locally against upstream's own config. Everything else runs there
   first, and `spell-check-differential` and `clang-tidy-differential` are where
   new-package pull requests actually churn.
2. Address review, then mark ready. Six TIER IV codeowners on this path are
   requested automatically. Expect questions about the new test directory and
   about `input_frame` dropping rather than transforming.
3. **`is_dense` issue**, once U0 settles which side is wrong.
4. After merge: bump this repo's Autoware, drop the `cuda_pointcloud_filters` submodule,
   keep only the launch integration.

**The submodule cannot be short-circuited through the Debian.** The three
commits were briefly cherry-picked onto
`NEWSLabNTU/autoware_universe:1.5.0-patches` (`1f77afc1a`, `b09faefea`,
`d0d0f927b`) and the pin bumped, on the theory that a Debian rebuild could
retire the submodule before review finished. That was reverted.
`NEWSLabNTU/autoware-localrepo` builds official Autoware source so that
`/opt/autoware/<version>` stays a clean baseline; vehicle-side patches belong in
this repository and its submodules. The commits remain reachable on the
`1.5.0-cuda-filters` branch, and the pin is back where it was.

So the retirement is gated on the merge after all:

1. #13301 merges;
2. we move to an Autoware release carrying it, and
   `ros2 component types | grep -i cudacropbox` names
   `autoware::cuda_pointcloud_preprocessor::CudaCropBoxFilterNode`;
3. repoint the launch files at the upstream package and namespace;
4. drop the submodule here and in AutoSDV, and archive
   `NEWSLabNTU/cuda_pointcloud_filters`.

The installed `/opt/autoware/1.5.0` ships neither filter, so until then the
submodule is the only provider. AutoSDV records the same sequence in
`docs/design/cuda-pipeline-data-flow.md`.

**Lead with capability, not performance.** The honest argument is that a
preprocessing chain cannot stay GPU-resident without these two nodes, which is
demonstrable from upstream's own package. The measured saving — about 19% of one
core, with no visible system effect — argues weakly enough that quoting it
invites the reviewer to conclude the work is not worth taking.

## Honest caveats

- The upstream package had **no test directory**, and this adds one. That sets a
  precedent, so the twelve cases were chosen to pin behaviour a reader would
  otherwise have to infer — inclusive bounds on all six faces, the exact-count
  guarantee, order preservation — rather than to raise a coverage number.
- These nodes have run against one 30 s bag on one machine. That is enough to
  claim correctness and not enough to claim performance, and the PR should say
  so rather than let a reviewer assume otherwise.
