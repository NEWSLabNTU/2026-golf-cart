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
| `cuda_ndt_matcher` | **No.** It is Rust on `rclrs`. Autoware is C++; there is no path for it, and the feasibility note explains why even its transport cannot reach the blackboard. |

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

## Sequencing

Two PRs, not one. They are independent nodes, they will be reviewed by the same
people, and a rejected crop box should not block a random downsample.

1. **Crop box.** The stronger case — it unblocks a GPU-resident chain and the
   gap is easy to demonstrate.
2. **Random downsample.** Land after, referencing the first. Its design note is
   the interesting part: an exact `sample_num` by random-key sort rather than
   thresholding, because thresholding gives a binomial count around the target
   where the CPU component promises *at most* `sample_num`.
3. **The `is_dense` question** as an issue, not a PR. Ask which of the two
   concatenators is right before proposing a change to either.

Open a draft PR early. The design-file and docs requirements are the ones
outside contributors most often miss, and reviewers will say so quickly.

## What stays downstream

`golfcart_cuda_preprocessor` becomes redundant once both nodes land upstream and
this repo moves to an Autoware version carrying them. Until then it is the
implementation; after, it should be deleted rather than left as a fork of code
that exists upstream.

`localization_pointcloud_backend`, the `util.launch.xml` that carries it, and the
two compatibility parameters stay here regardless — they are this repository's
integration, not a general capability.
