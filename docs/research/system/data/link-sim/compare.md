# link_sim: baseline vs split

| window | metric | baseline | split | change |
|---|---|---:|---:|---:|
| startup | tx mean kB/s | 13392.6 | 2.2 | -100.0% |
| startup | tx peak kB/s | 28281.2 | 31.6 | -99.9% |
| startup | rx mean kB/s | 74.0 | 54.0 | -26.9% |
| startup | rx peak kB/s | 471.4 | 79.9 | -83.1% |
| startup | tx pkt/s mean | 10280 | 6 | -99.9% |
| startup | tx pkt/s peak | 36613 | 76 | -99.8% |
| startup | rx pkt/s mean | 173 | 121 | -30.0% |
| startup | rx pkt/s peak | 1099 | 189 | -82.8% |
| startup | tx total bytes | 535702534 | 86862 | -100.0% |
| startup | rx total bytes | 2958084 | 2161546 | -26.9% |
| steady | tx mean kB/s | 13466.4 | 2.2 | -100.0% |
| steady | tx peak kB/s | 18639.6 | 12.4 | -99.9% |
| steady | rx mean kB/s | 103.7 | 55.0 | -46.9% |
| steady | rx peak kB/s | 475.8 | 78.9 | -83.4% |
| steady | tx pkt/s mean | 10495 | 6 | -99.9% |
| steady | tx pkt/s peak | 20418 | 31 | -99.8% |
| steady | rx pkt/s mean | 328 | 124 | -62.1% |
| steady | rx pkt/s peak | 1739 | 213 | -87.8% |
| steady | tx total bytes | 605988822 | 98012 | -100.0% |
| steady | rx total bytes | 4665555 | 2475966 | -46.9% |
| echo | tx mean kB/s | 13329.1 | 1.7 | -100.0% |
| echo | tx peak kB/s | 18701.4 | 12.4 | -99.9% |
| echo | rx mean kB/s | 4938.6 | 53.9 | -98.9% |
| echo | rx peak kB/s | 5456.6 | 64.4 | -98.8% |
| echo | tx pkt/s mean | 10336 | 5 | -100.0% |
| echo | tx pkt/s peak | 20275 | 30 | -99.9% |
| echo | rx pkt/s mean | 3506 | 120 | -96.6% |
| echo | rx pkt/s peak | 4538 | 145 | -96.8% |
| echo | tx total bytes | 199936550 | 26106 | -100.0% |
| echo | rx total bytes | 74079372 | 807796 | -98.9% |

| data path | baseline | split |
|---|---:|---:|
| imu_latency_max_ms | 3.052 | 5.932 |
| imu_latency_mean_ms | 0.119 | 0.165 |
| imu_latency_p99_ms | 0.309 | 0.423 |
| imu_msgs | 9970 | 9976 |
| imu_rate_hz | 99.7 | 99.8 |
| orin_diagnostics_msgs | 100 | 99 |
| tf_static_frames | 32 | 32 |

| discovery | baseline | split |
|---|---:|---:|
| master (domain 0) nodes | 142 | 142 |
| master (domain 0) topics | 552 | 551 |
| orin (domain 0) nodes | 142 | 2 |
| orin (domain 0) topics | 552 | 7 |
| orin (link domain 42) nodes | - | 2 |
| orin (link domain 42) topics | - | 6 |

