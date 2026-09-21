# link_sim: split

| window | s | tx mean kB/s | tx peak kB/s (Mbit/s) | rx mean kB/s | rx peak kB/s (Mbit/s) | tx pkt/s mean/peak | rx pkt/s mean/peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 1.8 | 19.6 (0.16) | 75.0 | 97.1 (0.78) | 5 / 48 | 199 / 255 |
| steady | 75 | 1.9 | 12.4 (0.10) | 89.3 | 124.4 (1.00) | 5 / 36 | 237 / 357 |
| echo | 15 | 1.8 | 9.5 (0.08) | 88.6 | 96.4 (0.77) | 5 / 23 | 235 / 253 |

tx = master -> orin, rx = orin -> master, as seen at the master's end of the veth.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 317972 | 912 | 0 | 0 |
| orin -> master | 14582668 | 38696 | 0 | 0 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 99.706 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 13.424 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.000 s |

## The two recorders

- bag master: Duration: 155.075332803s Messages: 110799
- bag orin: Duration: 174.987957585s Messages: 27922

## Readers, and what a CLI participant discovers

| | |
|---|---:|
| readers of /sensing/lidar/vlp32/velodyne_points | pubs=1 subs=2 |
| readers of /sensing/lidar/vlp32/pointcloud | pubs=1 subs=1 |
| readers of /sensing/lidar/falcon/iv_points | pubs=1 subs=2 |
| readers of /sensing/lidar/concatenated/pointcloud | pubs=1 subs=1 |
| readers of /sensing/camera/zed/imu/data | pubs=1 subs=2 |
| readers of /tf | pubs=5 subs=19 |
| readers of /sensing/camera/left/image_raw/compressed | pubs=1 subs=1 |
| orin (domain 0) nodes | 3 |
| orin (domain 0) topics | 9 |
| orin (link domain 42) nodes | 2 |
| orin (link domain 42) topics | 7 |
| master (domain 0) nodes | 158 |
| master (domain 0) topics | 623 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 42 | unicast-discovery | 214456 | 537 |
| master->orin | 42 | unicast-data | 20092 | 192 |
| master->orin | 42 | multicast-discovery | 9328 | 22 |
| orin->master | 42 | unicast-data | 13717232 | 37833 |
| orin->master | 42 | unicast-discovery | 245852 | 662 |
| orin->master | 42 | multicast-discovery | 11240 | 28 |

