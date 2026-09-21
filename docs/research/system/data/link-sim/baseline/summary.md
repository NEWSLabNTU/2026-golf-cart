# link_sim: baseline

| window | s | tx mean kB/s | tx peak kB/s (Mbit/s) | rx mean kB/s | rx peak kB/s (Mbit/s) | tx pkt/s mean/peak | rx pkt/s mean/peak |
|---|---:|---:|---:|---:|---:|---:|---:|
| startup | 40 | 13392.6 | 28281.2 (226.25) | 74.0 | 471.4 (3.77) | 10280 / 36613 | 173 / 1099 |
| steady | 45 | 13466.4 | 18639.6 (149.12) | 103.7 | 475.8 (3.81) | 10495 / 20418 | 328 / 1739 |
| echo | 15 | 13329.1 | 18701.4 (149.61) | 4938.6 | 5456.6 (43.65) | 10336 / 20275 | 3506 / 4538 |

tx = master -> orin, rx = orin -> master, as seen at the master's end of the veth.

## Data path (master's view of the orin's topics)

| | |
|---|---|
| imu_msgs | 9970 |
| imu_rate_hz | 99.7 |
| imu_latency_mean_ms | 0.119 |
| imu_latency_p99_ms | 0.309 |
| imu_latency_max_ms | 3.052 |
| orin_diagnostics_msgs | 100 |
| tf_static_frames | 32 |

## What a CLI participant discovers

| | count |
|---|---:|
| orin (domain 0) nodes | 142 |
| orin (domain 0) topics | 552 |
| master (domain 0) nodes | 142 |
| master (domain 0) topics | 552 |

## Bytes by domain and class (raw socket on the veth, whole run)

| direction | domain | class | bytes | packets |
|---|---|---|---:|---:|
| master->orin | 0 | multicast-data | 1253348426 | 875263 |
| master->orin | 0 | unicast-discovery | 67150956 | 134584 |
| master->orin | 0 | multicast-discovery | 3131072 | 6582 |
| master->orin | 0 | unicast-data | 1310536 | 5484 |
| master->orin | fragment-of-unknown | multicast | 961988 | 653 |
| orin->master | 0 | unicast-data | 59056332 | 49206 |
| orin->master | 0 | unicast-discovery | 2843024 | 10805 |
| orin->master | 0 | multicast-data | 158988 | 221 |
| orin->master | 0 | multicast-discovery | 61656 | 250 |
| orin->master | fragment-of-unknown | unicast | 9188 | 7 |

