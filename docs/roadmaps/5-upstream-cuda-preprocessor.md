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
| **U1 — extract** | **done** — both nodes ported into upstream's layout on `feat/cuda-crop-box-filter` in `jerry73204/autoware_universe` |
| **U2 — publish** | **prepared, not opened.** Opening a PR against the foundation is the one irreversible step and is held for an explicit go-ahead |

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
  `golfcart::cuda_preprocessor` → `autoware::cuda_pointcloud_preprocessor`, with
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

Not ported, and deliberately: the downstream launch integration.
`util.launch.xml` and `localization_pointcloud_backend` stay in this repository.

## U2 — publish (prepared)

Everything up to the irreversible step is ready. What remains is a decision, not
work:

1. **Open the crop box PR as a draft.** Semantic title, DCO sign-off. Draft on
   purpose — the design-file and docs requirements are what reviewers catch
   first, and a draft gets that feedback before polish.
2. Address review. Expect questions about the new test directory (this package
   has none today) and about why the node does not transform frames.
3. **Random downsample PR**, referencing the first. Lead with the algorithm
   choice: exact `sample_num` by random-key sort rather than thresholding,
   because thresholding gives a binomial count where the CPU component promises
   *at most* `sample_num`.
4. **`is_dense` issue**, once U0 settles which side is wrong.
5. After both merge: bump this repo's Autoware, delete
   `golfcart_cuda_preprocessor`, keep only the launch integration.

**Lead with capability, not performance.** The honest argument is that a
preprocessing chain cannot stay GPU-resident without these two nodes, which is
demonstrable from upstream's own package. The measured saving — about 19% of one
core, with no visible system effect — argues weakly enough that quoting it
invites the reviewer to conclude the work is not worth taking.

## Honest caveats

- The upstream package has **no test directory**. Whatever lands there sets a
  precedent for it, so the tests should be worth having rather than merely
  present.
- These nodes have run against one 30 s bag on one machine. That is enough to
  claim correctness and not enough to claim performance, and the PR should say
  so rather than let a reviewer assume otherwise.
