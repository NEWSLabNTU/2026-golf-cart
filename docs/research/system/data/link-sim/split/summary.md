# link_sim: split

| window | s | tx mean kB/s | tx peak kB/s (Mbit/s) | rx mean kB/s | rx peak kB/s (Mbit/s) | tx pkt/s mean/peak | rx pkt/s mean/peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 40 | 2.2 | 31.6 (0.25) | 54.0 | 79.9 (0.64) | 6 / 76 | 121 / 189 |
| steady | 45 | 2.2 | 12.4 (0.10) | 55.0 | 78.9 (0.63) | 6 / 31 | 124 / 213 |
| echo | 15 | 1.7 | 12.4 (0.10) | 53.9 | 64.4 (0.52) | 5 / 30 | 120 / 145 |

tx = master -> orin, rx = orin -> master, as seen at the master's end of the veth.

## Data path (master's view of the orin's topics)

| | |
|---|---|
| imu_msgs | 9976 |
| imu_rate_hz | 99.8 |
| imu_latency_mean_ms | 0.165 |
| imu_latency_p99_ms | 0.423 |
| imu_latency_max_ms | 5.932 |
| orin_diagnostics_msgs | 99 |
| tf_static_frames | 32 |

## What a CLI participant discovers

| | count |
|---|---:|
| orin (domain 0) nodes | 2 |
| orin (domain 0) topics | 7 |
| orin (link domain 42) nodes | 2 |
| orin (link domain 42) topics | 6 |
| master (domain 0) nodes | 142 |
| master (domain 0) topics | 551 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 42 | unicast-discovery | 138504 | 345 |
| master->orin | 42 | unicast-data | 12716 | 125 |
| master->orin | 42 | multicast-discovery | 5936 | 14 |
| orin->master | 42 | unicast-data | 5434748 | 12496 |
| orin->master | 42 | unicast-discovery | 167180 | 472 |
| orin->master | 42 | multicast-discovery | 7848 | 20 |

