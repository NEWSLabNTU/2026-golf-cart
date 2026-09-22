# link_sim: split_rviz_zedimage_record

## master -> orin (Advantech transmits)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 1.9 | 0.02 | 34.4 | 0.27 | 5 | 86 |
| steady | 75 | 1.9 | 0.02 | 9.9 | 0.08 | 5 | 31 |
| echo | 15 | 1.7 | 0.01 | 9.5 | 0.08 | 5 | 23 |

## orin -> master (Advantech receives)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 5780.5 | 46.24 | 7025.8 | 56.21 | 3991 | 4857 |
| steady | 75 | 6873.0 | 54.98 | 7013.7 | 56.11 | 4747 | 4837 |
| echo | 15 | 6869.4 | 54.96 | 6990.3 | 55.92 | 4743 | 4819 |

Counted at the master's end of the veth, both directions, one second at a time.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 326548 | 928 | 0 | 0 |
| orin -> master | 1132362852 | 781974 | 0 | 984579 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 97.084 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 13.723 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.004 s |

## The two recorders

- bag master: Duration: 156.191699441s Messages: 111601
- bag orin: Duration: 176.129984216s Messages: 27927

## Readers, and what a CLI participant discovers

| | |
|---|---:|
| readers of /sensing/lidar/vlp32/velodyne_points | pubs=1 subs=3 |
| readers of /sensing/lidar/vlp32/pointcloud | pubs=1 subs=1 |
| readers of /sensing/lidar/falcon/iv_points | pubs=1 subs=3 |
| readers of /sensing/lidar/concatenated/pointcloud | pubs=1 subs=1 |
| readers of /sensing/camera/zed/imu/data | pubs=1 subs=2 |
| readers of /tf | pubs=5 subs=20 |
| readers of /sensing/camera/left/image_raw/compressed | pubs=1 subs=2 |
| readers of /sensing/camera/zed/rgb/color/rect/image/compressed | pubs=1 subs=1 |
| orin (its stack domain) nodes | 3 |
| orin (its stack domain) topics | 9 |
| orin (link domain 10) nodes | 2 |
| orin (link domain 10) topics | 8 |
| master (its stack domain) nodes | 160 |
| master (its stack domain) topics | 643 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 10 | unicast-discovery | 214520 | 536 |
| master->orin | 10 | unicast-data | 25900 | 207 |
| master->orin | 10 | multicast-discovery | 9328 | 22 |
| orin->master | 10 | unicast-data | 1121060736 | 781088 |
| orin->master | 10 | unicast-discovery | 253332 | 672 |
| orin->master | 10 | multicast-discovery | 11664 | 29 |

## Bridge lanes: what each host put on the wire, per topic

Payload bytes from the bridge's own counters; the wire adds ~60-100 B of RTPS/UDP/IP per sample, more for fragmented ones.

| host | direction | topic | msgs | payload kB/s | throttled |
|---|---|---|---:|---:|---:|
| orin | -> wire | /sensing/camera/zed/imu/data | 16737 | 34.7 | 0 |
| orin | -> wire | /tf | 16737 | 13.0 | 0 |
| orin | -> wire | /sensing/camera/zed/rgb/color/rect/camera_info | 5095 | 10.7 | 0 |
| orin | -> wire | /diagnostics | 169 | 1.4 | 0 |
| orin | -> wire | /tf_static | 1 | 0.0 | 0 |
| orin | -> wire | /sensing/camera/zed/rgb/color/rect/image/compressed | 5095 | 7007.7 | 0 |

