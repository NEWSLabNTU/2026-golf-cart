# link_sim: baseline_record

## master -> orin (Advantech transmits)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 8897.9 | 71.18 | 12310.5 | 98.48 | 6871 | 19061 |
| steady | 75 | 12100.0 | 96.80 | 12426.5 | 99.41 | 9278 | 12359 |
| echo | 15 | 12099.8 | 96.80 | 12300.4 | 98.40 | 9234 | 11265 |

## orin -> master (Advantech receives)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 111.4 | 0.89 | 1041.4 | 8.33 | 310 | 3142 |
| steady | 75 | 150.5 | 1.20 | 532.8 | 4.26 | 501 | 2272 |
| echo | 15 | 6640.8 | 53.13 | 7271.4 | 58.17 | 4884 | 6684 |

Counted at the master's end of the veth, both directions, one second at a time.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 1880007436 | 1444968 | 137358 | 4226422 |
| orin -> master | 120745953 | 139683 | 0 | 83339 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 100.004 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 2.022 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.000 s |

## The two recorders

- bag master: Duration: 154.074713856s Messages: 79403
- bag orin: Duration: 174.069978250s Messages: 27788

## Readers, and what a CLI participant discovers

| | |
|---|---:|
| readers of /sensing/lidar/vlp32/velodyne_points | pubs=1 subs=2 |
| readers of /sensing/lidar/vlp32/pointcloud | pubs=1 subs=1 |
| readers of /sensing/lidar/falcon/iv_points | pubs=1 subs=2 |
| readers of /sensing/lidar/concatenated/pointcloud | pubs=1 subs=1 |
| readers of /sensing/camera/zed/imu/data | pubs=1 subs=3 |
| readers of /tf | pubs=5 subs=19 |
| readers of /sensing/camera/left/image_raw/compressed | pubs=1 subs=1 |
| readers of /sensing/camera/zed/rgb/color/rect/image/compressed | pubs=1 subs=1 |
| orin (its stack domain) nodes | 159 |
| orin (its stack domain) topics | 624 |
| master (its stack domain) nodes | 159 |
| master (its stack domain) topics | 624 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 0 | multicast-data | 1777957120 | 1266042 |
| master->orin | 0 | unicast-discovery | 75397620 | 156750 |
| master->orin | 0 | multicast-discovery | 3578896 | 11256 |
| master->orin | 0 | unicast-data | 2691368 | 10593 |
| orin->master | 0 | multicast-data | 107743551 | 97473 |
| orin->master | 0 | unicast-discovery | 9716304 | 34007 |
| orin->master | 0 | unicast-data | 965260 | 7198 |
| orin->master | 0 | multicast-discovery | 156008 | 545 |

