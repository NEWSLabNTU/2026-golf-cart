# link_sim: baseline_rviz_zedimage_record

## master -> orin (Advantech transmits)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 9216.2 | 73.73 | 12584.9 | 100.68 | 7069 | 18836 |
| steady | 75 | 12532.8 | 100.26 | 12617.2 | 100.94 | 9560 | 12574 |
| echo | 15 | 12534.6 | 100.28 | 12548.6 | 100.39 | 9565 | 11061 |

## orin -> master (Advantech receives)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 4939.4 | 39.52 | 7061.1 | 56.49 | 3517 | 5138 |
| steady | 75 | 6934.2 | 55.47 | 7390.2 | 59.12 | 5014 | 6775 |
| echo | 15 | 6959.6 | 55.68 | 7463.1 | 59.70 | 5080 | 6617 |

Counted at the master's end of the veth, both directions, one second at a time.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 1948753660 | 1489364 | 143138 | 4409898 |
| orin -> master | 1067470363 | 768838 | 0 | 905070 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 98.994 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 1.562 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.003 s |

## The two recorders

- bag master: Duration: 154.263627315s Messages: 77533
- bag orin: Duration: 174.236643693s Messages: 27677

## Readers, and what a CLI participant discovers

| | |
|---|---:|
| readers of /sensing/lidar/vlp32/velodyne_points | pubs=1 subs=3 |
| readers of /sensing/lidar/vlp32/pointcloud | pubs=1 subs=1 |
| readers of /sensing/lidar/falcon/iv_points | pubs=1 subs=3 |
| readers of /sensing/lidar/concatenated/pointcloud | pubs=1 subs=1 |
| readers of /sensing/camera/zed/imu/data | pubs=1 subs=3 |
| readers of /tf | pubs=5 subs=20 |
| readers of /sensing/camera/left/image_raw/compressed | pubs=1 subs=2 |
| readers of /sensing/camera/zed/rgb/color/rect/image/compressed | pubs=1 subs=2 |
| orin (its stack domain) nodes | 161 |
| orin (its stack domain) topics | 643 |
| master (its stack domain) nodes | 161 |
| master (its stack domain) topics | 643 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 0 | multicast-data | 1846012312 | 1311418 |
| master->orin | 0 | unicast-discovery | 75313116 | 155324 |
| master->orin | 0 | multicast-discovery | 3581488 | 11368 |
| master->orin | 0 | unicast-data | 2792364 | 10833 |
| orin->master | 0 | multicast-data | 1044512639 | 726130 |
| orin->master | 0 | unicast-discovery | 9641568 | 33697 |
| orin->master | 0 | unicast-data | 1202732 | 7353 |
| orin->master | fragment-of-unknown | multicast | 803808 | 540 |
| orin->master | 0 | multicast-discovery | 170976 | 523 |

