# Upstreaming the CUDA point cloud work to Autoware

A proposal for the repository shape under `jerry73204`, and what has to change in
the code before any of it can go up. Read against
[cuda-pipeline-data-flow.md](cuda-pipeline-data-flow.md), which says what exists
and where.

Everything here is drawn from `autowarefoundation/autoware_universe` at 0.52.0
and its `.github/`, not from memory.

---

## The shape: forks, not new repositories

**`jerry73204/autoware_universe`** — a fork, and the only one strictly needed.

The two filters belong in the package that already holds their siblings,
`sensing/autoware_cuda_pointcloud_preprocessor`, beside
`CudaVoxelGridDownsampleFilterNode` and `CudaPolarVoxelOutlierFilterNode`. A
standalone repository would fragment a package whose whole value is that the
CUDA nodes chain blackboard-to-blackboard within it, and it would have to be
released separately for anyone to use.

**`jerry73204/autoware_launch`** — a second fork, only if the launch switch goes
up. `tier4_localization_launch` is not in `autoware_universe`; it lives there.
This is optional and lower value; see *What is worth upstreaming*.

**No third repository.** Work happens on topic branches in the fork; there is no
need for a staging repo, and a separate one would only make the eventual PR a
port rather than a push.

## What is worth upstreaming, and what is not

| | verdict |
|---|---|
| `CudaCropBoxFilterNode` | **Yes.** Fills a real gap: the only GPU cropping upstream has is fused inside `CudaPointcloudPreprocessorNode` with distortion correction and needs a per-point time field, so it cannot be used standalone. |
| `CudaRandomDownsampleFilterNode` | **Yes.** No CUDA equivalent exists at all. Together with the crop box it lets a preprocessing chain stay GPU-resident end to end, which today it cannot. |
| The `is_dense` inconsistency | **Yes, as a small separate issue.** The CPU concatenator publishes `is_dense=False` where the CUDA one publishes `True`, on clouds that measurably contain no non-finite points either way. One of the two is wrong. |
| `localization_pointcloud_backend` | **Maybe, later.** It is useful, but it is a `tier4_localization_launch` change in a different repository, and upstream may prefer their own idiom. Offer it after the nodes land, if asked. |
| `cuda_ndt_matcher` | **No, and not because it is unwelcome.** It already has its own home at `NEWSLabNTU/cuda_ndt_matcher` and is developed there. It is also Rust on `rclrs` against a C++ codebase, so there is no path even if that changed. Nothing about the localization matcher is in scope here. |

## Per-node file manifest

Upstream requires more per node than a header and a source file. For a node
called `CudaCropBoxFilter`, matching what `CudaVoxelGridDownsampleFilter` has:

```
sensing/autoware_cuda_pointcloud_preprocessor/
├── include/autoware/cuda_pointcloud_preprocessor/cuda_crop_box_filter/
│   ├── cuda_crop_box_filter.hpp
│   └── cuda_crop_box_filter_node.hpp
├── src/cuda_crop_box_filter/
│   ├── cuda_crop_box_filter.cu
│   └── cuda_crop_box_filter_node.cpp
├── config/cuda_crop_box_filter.param.yaml
├── schema/cuda_crop_box_filter.schema.json
├── launch/cuda_crop_box_filter.launch.xml
├── design/CudaCropBoxFilter.node.yaml        ← easy to miss
└── docs/cuda-crop-box-filter.md              ← easy to miss
```

plus edits to `CMakeLists.txt` (source list and
`rclcpp_components_register_node`) and to `README.md`, whose sections are fixed:
*Purpose*, *Inner-workings / Algorithms*, *(Optional) Future extensions*.

`design/*.node.yaml` uses `autoware_system_design_format: 0.3.0` and declares
plugin, executable, subscribers, publishers and param files. Note the existing
CUDA one carries a comment worth copying: blackboard I/O is declared as
`sensor_msgs/msg/PointCloud2`, the negotiated ROS-graph type, not
`CudaPointCloud2`.

## What must change in the code before it goes up

The nodes work, are tested, and are none of them upstream-shaped yet:

1. **Namespace and package.** `golfcart::cuda_preprocessor::` →
   `autoware::cuda_pointcloud_preprocessor::`; `golfcart_cuda_preprocessor` →
   the existing package. Include guards follow the path, so they change too, and
   `ros-include-guard` in pre-commit enforces it.
2. **CMake.** Ours calls `enable_language(CUDA)` with `CMAKE_CUDA_ARCHITECTURES`.
   Theirs uses the legacy `find_package(CUDA)` with an explicit `-gencode` list
   and a `CUDA_VERSION` conditional for sm_101/sm_110/sm_120. Adopt theirs
   rather than introducing a second idiom in one package.
3. **Licence headers.** Ours say NEWSLab. New files may keep that under
   Apache-2.0 — upstream files carry TIER IV's — but the year and the SPDX shape
   must match the surrounding files exactly.
4. **The two compatibility parameters.** `CudaCropBoxFilterNode` declares
   `output_frame` and `processing_time_threshold_sec` so that one parameter file
   can drive either backend in *our* launch. Upstream has no such requirement and
   may reject them as dead surface. Be ready to drop them and keep that shim
   downstream; the node's behaviour does not depend on them.
5. **Tests.** The package has **no test directory today** — only
   `ament_lint_auto`. Our 12 gtest cases would add one, plus
   `ament_cmake_gtest` to `package.xml`. That is a contribution in itself and
   worth raising in the PR description rather than slipping in, since it changes
   what CI runs for that package.

## Process, from their `.github/`

- **DCO sign-off on every commit** (`git commit -s`) — `dco.yaml` enforces it.
- **Semantic PR title** — `semantic-pull-request.yaml`. Use
  `feat(autoware_cuda_pointcloud_preprocessor): add a standalone CUDA crop box`.
- **pre-commit before pushing.** The config includes `ros-include-guard`,
  `sort-package-xml`, `prettier-launch-xml`, `prettier-package-xml`,
  `markdownlint`, `yamllint`, `shellcheck`, `check-json`, `check-xml` and
  `check-package-depends`. Most first-PR churn is here; run it locally.
- **CI that will run**: `build-and-test-differential`, `clang-tidy-differential`,
  `cppcheck-differential`.
- **Reviewers** come from `.github/CODEOWNERS`, which for this package is six
  TIER IV maintainers. `CHANGELOG.rst` is release-tooling output — do not hand-edit.

## Roadmap: fix, extract, publish

Three stages. The ordering matters because each one is cheaper to do before the
next: fixing is cheapest in this repo, restructuring is cheapest before review,
and review is cheapest when neither is outstanding.

### U0 — fix before the split

Everything here is easier while the code still lives in one repo with a working
replay harness attached. None of it is easier after the fork.

| | why it blocks |
|---|---|
| **Measure what the CUDA chain costs** | Never timed. Correctness and equivalence are established; speed is not. The first question any reviewer asks is "is it faster?", and "we did not measure" is a bad answer for a GPU contribution. It could also be *slower* — kernel launches, and a host-to-device copy at the first stage when sensing is on CPU. |
| **Node-level tests** | The 12 gtest cases cover the filter classes only. The parameter validation — inverted bounds, `sample_num <= 0`, the frame-mismatch rejection — is untested, and so is component loading. Upstream is adding a test directory to a package that has none, so what lands there should be worth the precedent. |
| **Settle the `is_dense` question** | Needed before the issue can be filed usefully. The CPU concatenator says `False` and the CUDA one `True` on clouds measured clean either way. Decide which is right, with evidence, before asking upstream to change either. |
| **Isolate the two compatibility parameters** | `output_frame` and `processing_time_threshold_sec` exist only so one parameter file drives both backends *here*. They should not go up. Make their removal a deletion rather than an untangling. |
| **Exercise on the vehicle, if the chance comes** | Not a blocker, but every number so far is Autoware's 30 s sample bag with three Velodynes. One run on VLP-32C plus Seyond would make the PR's claims about real sensors rather than a tutorial fixture. |

### U1 — extract

Fork `autowarefoundation/autoware_universe` to `jerry73204/autoware_universe`,
branch per node, and move the code into their layout. Mechanical, but there is
more of it than it looks:

1. Files into the per-node layout above, including `design/*.node.yaml` and
   `docs/*.md`.
2. Namespace, package name and include guards renamed together —
   `ros-include-guard` will catch a miss.
3. Their CMake idiom adopted: legacy `find_package(CUDA)` with the explicit
   `-gencode` list and the `CUDA_VERSION` conditional, not our
   `enable_language(CUDA)`.
4. The two compatibility parameters removed.
5. `pre-commit run --all-files` until clean. This is where most first-PR churn
   goes, and it is free to absorb now rather than in review.
6. Build and run the tests against upstream's tree, not ours — different CMake,
   different dependency set.

**Do not** port the downstream launch integration. `util.launch.xml` and
`localization_pointcloud_backend` stay here.

### U2 — publish

1. **Draft PR: crop box.** Open it early and unfinished. The design-file and docs
   requirements are what reviewers catch first, and a draft gets that feedback
   before the work is polished. Semantic title, DCO sign-off on every commit.
2. **Address review.** Expect questions about the test directory, and about
   whether the node should transform frames — it deliberately does not, and the
   answer is in the header comment.
3. **PR: random downsample**, referencing the first. Lead with the algorithm
   choice: exact `sample_num` by random-key sort rather than thresholding,
   because thresholding gives a binomial count where the CPU component promises
   *at most* `sample_num`.
4. **Issue: `is_dense`**, once U0 has settled which side is wrong.
5. **After both merge**: bump this repo to an Autoware carrying them, delete
   `golfcart_cuda_preprocessor`, and keep only the launch integration. Leaving a
   local fork of code that exists upstream is how the two drift.

**Lead with capability, not performance.** The honest argument is that a
preprocessing chain cannot stay GPU-resident without these two nodes, which is
demonstrable from upstream's own package. Our measured saving — about 19% of one
core, with no visible system effect — argues weakly, and quoting it invites the
reviewer to conclude the work is not worth taking.

## What stays downstream

`golfcart_cuda_preprocessor` becomes redundant once both nodes land upstream and
this repo moves to an Autoware version carrying them. Until then it is the
implementation; after, it should be deleted rather than left as a fork of code
that exists upstream.

`localization_pointcloud_backend`, the `util.launch.xml` that carries it, and the
two compatibility parameters stay here regardless — they are this repository's
integration, not a general capability.
