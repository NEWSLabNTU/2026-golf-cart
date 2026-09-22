# link_sim: baseline_rviz_record

## master -> orin (Advantech transmits)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 9214.8 | 73.72 | 12556.8 | 100.45 | 7026 | 19532 |
| steady | 75 | 12533.0 | 100.26 | 12543.6 | 100.35 | 9490 | 12320 |
| echo | 15 | 12534.6 | 100.28 | 12543.3 | 100.35 | 9543 | 11114 |

## orin -> master (Advantech receives)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 109.9 | 0.88 | 951.5 | 7.61 | 308 | 3253 |
| steady | 75 | 158.4 | 1.27 | 753.5 | 6.03 | 504 | 2165 |
| echo | 15 | 6587.4 | 52.70 | 7299.9 | 58.40 | 4829 | 6713 |

Counted at the master's end of the veth, both directions, one second at a time.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 1948747796 | 1480250 | 156205 | 4434563 |
| orin -> master | 120475657 | 139029 | 0 | 85779 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 99.990 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 1.586 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.000 s |

## The two recorders

- bag master: Duration: 154.219327470s Messages: 77758
- bag orin: Duration: 174.251861699s Messages: 27777

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
| readers of /sensing/camera/zed/rgb/color/rect/image/compressed | pubs=1 subs=1 |
| orin (its stack domain) nodes | 161 |
| orin (its stack domain) topics | 643 |
| master (its stack domain) nodes | 161 |
| master (its stack domain) topics | 643 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 0 | multicast-data | 1852884372 | 1316176 |
| master->orin | 0 | unicast-discovery | 68830996 | 141619 |
| master->orin | 0 | multicast-discovery | 3652316 | 11713 |
| master->orin | 0 | unicast-data | 2562072 | 10500 |
| orin->master | 0 | multicast-data | 107130595 | 97014 |
| orin->master | 0 | unicast-discovery | 9730324 | 33900 |
| orin->master | 0 | unicast-data | 1184216 | 7154 |
| orin->master | 0 | multicast-discovery | 180148 | 525 |
| orin->master | fragment-of-unknown | multicast | 121968 | 82 |

