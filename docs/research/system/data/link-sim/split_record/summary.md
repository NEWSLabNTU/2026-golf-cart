# link_sim: split_record

## master -> orin (Advantech transmits)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 1.9 | 0.02 | 34.7 | 0.28 | 5 | 82 |
| steady | 75 | 1.9 | 0.02 | 10.2 | 0.08 | 5 | 33 |
| echo | 15 | 1.7 | 0.01 | 9.3 | 0.07 | 5 | 23 |

## orin -> master (Advantech receives)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 74.7 | 0.60 | 96.4 | 0.77 | 198 | 253 |
| steady | 75 | 89.4 | 0.72 | 115.0 | 0.92 | 238 | 337 |
| echo | 15 | 88.6 | 0.71 | 96.4 | 0.77 | 235 | 253 |

Counted at the master's end of the veth, both directions, one second at a time.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 324124 | 926 | 0 | 0 |
| orin -> master | 14631682 | 38847 | 0 | 0 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 99.985 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 14.218 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.000 s |

## The two recorders

- bag master: Duration: 155.790119757s Messages: 112724
- bag orin: Duration: 175.777949891s Messages: 28056

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
| readers of /sensing/camera/zed/rgb/color/rect/image/compressed | - |
| orin (its stack domain) nodes | 3 |
| orin (its stack domain) topics | 9 |
| orin (link domain 10) nodes | 2 |
| orin (link domain 10) topics | 7 |
| master (its stack domain) nodes | 158 |
| master (its stack domain) topics | 623 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 10 | unicast-discovery | 217796 | 543 |
| master->orin | 10 | unicast-data | 22744 | 203 |
| master->orin | 10 | multicast-discovery | 9328 | 22 |
| orin->master | 10 | unicast-data | 13763724 | 37974 |
| orin->master | 10 | unicast-discovery | 246268 | 674 |
| orin->master | 10 | multicast-discovery | 11240 | 28 |

## Bridge lanes: what each host put on the wire, per topic

Payload bytes from the bridge's own counters; the wire adds ~60-100 B of RTPS/UDP/IP per sample, more for fragmented ones.

| host | direction | topic | msgs | payload kB/s | throttled |
|---|---|---|---:|---:|---:|
| orin | -> wire | /sensing/camera/zed/imu/data | 16916 | 35.1 | 0 |
| orin | -> wire | /tf | 16916 | 13.1 | 0 |
| orin | -> wire | /sensing/camera/zed/rgb/color/rect/camera_info | 5095 | 10.7 | 0 |
| orin | -> wire | /diagnostics | 169 | 1.4 | 0 |
| orin | -> wire | /tf_static | 1 | 0.0 | 0 |

