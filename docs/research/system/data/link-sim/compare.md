# link_sim: baseline vs split

| window | metric | baseline | split | change |
|---|---|---:|---:|---:|
| startup | tx mean kB/s | 8915.3 | 1.8 | -100.0% |
| startup | tx peak kB/s | 12214.6 | 19.6 | -99.8% |
| startup | rx mean kB/s | 110.9 | 75.0 | -32.4% |
| startup | rx peak kB/s | 917.7 | 97.1 | -89.4% |
| startup | tx pkt/s mean | 6788 | 5 | -99.9% |
| startup | tx pkt/s peak | 18100 | 48 | -99.7% |
| startup | rx pkt/s mean | 311 | 199 | -36.1% |
| startup | rx pkt/s peak | 2973 | 255 | -91.4% |
| startup | tx total bytes | 624071596 | 127502 | -100.0% |
| startup | rx total bytes | 7763148 | 5251346 | -32.4% |
| steady | tx mean kB/s | 12140.7 | 1.9 | -100.0% |
| steady | tx peak kB/s | 12324.0 | 12.4 | -99.9% |
| steady | rx mean kB/s | 148.7 | 89.3 | -39.9% |
| steady | rx peak kB/s | 659.9 | 124.4 | -81.1% |
| steady | tx pkt/s mean | 9229 | 5 | -99.9% |
| steady | tx pkt/s peak | 11829 | 36 | -99.7% |
| steady | rx pkt/s mean | 498 | 237 | -52.4% |
| steady | rx pkt/s peak | 2801 | 357 | -87.3% |
| steady | tx total bytes | 910551137 | 140734 | -100.0% |
| steady | rx total bytes | 11154077 | 6698270 | -39.9% |
| echo | tx mean kB/s | 12127.1 | 1.8 | -100.0% |
| echo | tx peak kB/s | 12282.3 | 9.5 | -99.9% |
| echo | rx mean kB/s | 6635.3 | 88.6 | -98.7% |
| echo | rx peak kB/s | 7249.6 | 96.4 | -98.7% |
| echo | tx pkt/s mean | 9109 | 5 | -99.9% |
| echo | tx pkt/s peak | 11265 | 23 | -99.8% |
| echo | rx pkt/s mean | 4871 | 235 | -95.2% |
| echo | rx pkt/s peak | 6450 | 253 | -96.1% |
| echo | tx total bytes | 181907027 | 26260 | -100.0% |
| echo | rx total bytes | 99529028 | 1329390 | -98.7% |

| token bucket, whole run | baseline | split |
|---|---:|---:|
| master -> orin sent_bytes | 1872120077 | 317972 |
| master -> orin dropped | 161840 | 0 |
| master -> orin overlimits | 4185529 | 0 |
| orin -> master sent_bytes | 120439879 | 14582668 |
| orin -> master dropped | 0 | 0 |
| orin -> master overlimits | 85756 | 0 |

| at the real consumers | baseline | split |
|---|---:|---:|
| delay /sensing/camera/zed/imu/data | 0.000 s | 0.000 s |
| hz /localization/kinematic_state | no messages | no messages |
| hz /localization/twist_estimator/twist_with_covariance | 2.069 Hz | 13.424 Hz |
| hz /sensing/imu/imu_data | 100.003 Hz | 99.706 Hz |

| readers and discovery | baseline | split |
|---|---:|---:|
| master (domain 0) nodes | 159 | 158 |
| master (domain 0) topics | 624 | 623 |
| orin (domain 0) nodes | 159 | 3 |
| orin (domain 0) topics | 624 | 9 |
| orin (link domain 42) nodes | - | 2 |
| orin (link domain 42) topics | - | 7 |
| readers of /sensing/camera/left/image_raw/compressed | pubs=1 subs=1 | pubs=1 subs=1 |
| readers of /sensing/camera/zed/imu/data | pubs=1 subs=3 | pubs=1 subs=2 |
| readers of /sensing/lidar/concatenated/pointcloud | pubs=1 subs=1 | pubs=1 subs=1 |
| readers of /sensing/lidar/falcon/iv_points | pubs=1 subs=2 | pubs=1 subs=2 |
| readers of /sensing/lidar/vlp32/pointcloud | pubs=1 subs=1 | pubs=1 subs=1 |
| readers of /sensing/lidar/vlp32/velodyne_points | pubs=1 subs=2 | pubs=1 subs=2 |
| readers of /tf | pubs=5 subs=19 | pubs=5 subs=19 |

