# link_sim: split_rviz_record

## master -> orin (Advantech transmits)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 1.9 | 0.02 | 34.2 | 0.27 | 5 | 83 |
| steady | 75 | 1.9 | 0.01 | 9.6 | 0.08 | 5 | 29 |
| echo | 15 | 1.7 | 0.01 | 9.5 | 0.08 | 5 | 23 |

## orin -> master (Advantech receives)

| window | s | mean kB/s | mean Mbit/s | peak second kB/s | peak Mbit/s | pkt/s mean | pkt/s peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 74.4 | 0.60 | 96.4 | 0.77 | 197 | 253 |
| steady | 75 | 88.8 | 0.71 | 114.7 | 0.92 | 236 | 332 |
| echo | 15 | 88.1 | 0.70 | 96.4 | 0.77 | 233 | 253 |

Counted at the master's end of the veth, both directions, one second at a time.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 325480 | 922 | 0 | 0 |
| orin -> master | 14583308 | 38686 | 0 | 0 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 99.894 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 12.987 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.000 s |

## The two recorders

- bag master: Duration: 156.144862885s Messages: 110398
- bag orin: Duration: 176.088790762s Messages: 27989

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
| readers of /sensing/camera/zed/rgb/color/rect/image/compressed | - |
| orin (its stack domain) nodes | 3 |
| orin (its stack domain) topics | 9 |
| orin (link domain 10) nodes | 2 |
| orin (link domain 10) topics | 7 |
| master (its stack domain) nodes | 160 |
| master (its stack domain) topics | 642 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 10 | unicast-discovery | 217408 | 538 |
| master->orin | 10 | unicast-data | 22000 | 198 |
| master->orin | 10 | multicast-discovery | 9328 | 22 |
| orin->master | 10 | unicast-data | 13709644 | 37808 |
| orin->master | 10 | unicast-discovery | 253836 | 679 |
| orin->master | 10 | multicast-discovery | 11664 | 29 |

## Bridge lanes: what each host put on the wire, per topic

Payload bytes from the bridge's own counters; the wire adds ~60-100 B of RTPS/UDP/IP per sample, more for fragmented ones.

| host | direction | topic | msgs | payload kB/s | throttled |
|---|---|---|---:|---:|---:|
| orin | -> wire | /sensing/camera/zed/imu/data | 16807 | 34.9 | 0 |
| orin | -> wire | /tf | 16807 | 13.0 | 0 |
| orin | -> wire | /sensing/camera/zed/rgb/color/rect/camera_info | 5095 | 10.7 | 0 |
| orin | -> wire | /diagnostics | 169 | 1.4 | 0 |
| orin | -> wire | /tf_static | 1 | 0.0 | 0 |

