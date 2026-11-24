# golfcart_localization_config

The golf cart's localization parameters: a whole copy of Autoware 2.1.0's
`autoware_localization_config/config` tree, with our changes marked
`# {OVERRIDE: reason}` on the line, upstream's own convention.

Autoware 2.1.0's localization launch files read every parameter file from
`$(find-pkg-share $(var localization_config_pkg))/config`. Passing
`localization_config_pkg:=golfcart_localization_config` therefore swaps all of
them at once, for every pose source upstream launches (`ndt`, `yabloc`,
`eagleye`, `artag`, `lidar-marker`). golfcart_launch passes it, and its own
`cuda_ndt`, `ndt` and `aruco` paths read the same files through
`loc_config_path`.

## What is ours

Only the NDT input and its score gate; everything else is upstream's, verbatim.

| file | key | upstream | ours |
|---|---|---|---|
| `ndt_scan_matcher/ndt_scan_matcher.param.yaml` | `score_estimation.converged_param_nearest_voxel_transformation_likelihood` | 2.3 | 1.3 |
| `ndt_scan_matcher/pointcloud_preprocessor/crop_box_filter_measurement_range.param.yaml` | `min_z` | -30.0 | -1.0 |
| `ndt_scan_matcher/pointcloud_preprocessor/random_downsample_filter.param.yaml` | `sample_num` | 1500 | 2000 |
| `ndt_scan_matcher/pointcloud_preprocessor/voxel_grid_filter.param.yaml` | `voxel_size_{x,y,z}` | 3.0 | 0.5 |

The reasons and measurements are in comments beside each value.
`test/test_matches_upstream.py` pins this table against the installed
`autoware_localization_config`: the same files, the same keys, and no other
value changed. Add a row there when you change a value here.

`cuda_ndt` has its own scan-matcher parameters in `cuda_ndt_matcher_launch`;
it reads the EKF, pose initializer, stop filter, twist2accel and the two
monitors from here, and its own copy of the NDT preprocessing files.

## On an Autoware upgrade

1. Copy the new release's `autoware_localization_config/config` over `config/`.
2. Re-apply the overrides in the table, with their comments.
3. Run the test (`just test`), which fails on any file or key upstream added
   or removed, and on an override whose upstream value moved.

Golf-cart-only localization configs (the ArUco boards, the reflective board,
rig_localization, the localization presets) are not part of Autoware's tree
and stay in `golfcart_launch/config/localization/`.
