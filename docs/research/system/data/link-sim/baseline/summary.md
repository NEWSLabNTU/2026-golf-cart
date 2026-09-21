# link_sim: baseline

| window | s | tx mean kB/s | tx peak kB/s (Mbit/s) | rx mean kB/s | rx peak kB/s (Mbit/s) | tx pkt/s mean/peak | rx pkt/s mean/peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 70 | 8915.3 | 12214.6 (97.72) | 110.9 | 917.7 (7.34) | 6788 / 18100 | 311 / 2973 |
| steady | 75 | 12140.7 | 12324.0 (98.59) | 148.7 | 659.9 (5.28) | 9229 / 11829 | 498 / 2801 |
| echo | 15 | 12127.1 | 12282.3 (98.26) | 6635.3 | 7249.6 (58.00) | 9109 / 11265 | 4871 / 6450 |

tx = master -> orin, rx = orin -> master, as seen at the master's end of the veth.

## The wire's token bucket (100 Mbit/s each way), whole run

| direction | sent bytes | sent packets | dropped packets | overlimits |
|---|---:|---:|---:|---:|
| master -> orin | 1872120077 | 1423089 | 161840 | 4185529 |
| orin -> master | 120439879 | 139144 | 0 | 85756 |

## At the real consumers on the master (mid-run, 20 s windows)

| | |
|---|---|
| hz /sensing/imu/imu_data | 100.003 Hz |
| hz /localization/twist_estimator/twist_with_covariance | 2.069 Hz |
| hz /localization/kinematic_state | no messages |
| delay /sensing/camera/zed/imu/data | 0.000 s |

## The two recorders

- bag master: Duration: 153.015712563s Messages: 78937
- bag orin: Duration: 173.024074817s Messages: 27639

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
| orin (domain 0) nodes | 159 |
| orin (domain 0) topics | 624 |
| master (domain 0) nodes | 159 |
| master (domain 0) topics | 624 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 0 | multicast-data | 1782025171 | 1268081 |
| master->orin | 0 | unicast-discovery | 64068468 | 133392 |
| master->orin | 0 | multicast-discovery | 3423556 | 11006 |
| master->orin | 0 | unicast-data | 2544488 | 10325 |
| orin->master | 0 | multicast-data | 107266659 | 97084 |
| orin->master | 0 | unicast-discovery | 9705996 | 33934 |
| orin->master | 0 | unicast-data | 1208536 | 7228 |
| orin->master | 0 | multicast-discovery | 175808 | 555 |

