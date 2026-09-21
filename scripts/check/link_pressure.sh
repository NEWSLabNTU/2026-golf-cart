#!/usr/bin/env bash
# link_pressure.sh - what one interface carries, second by second.
#
#   scripts/check/link_pressure.sh IFACE SECONDS [OUT.csv]
#   just link pressure                      # enP5p3s0 for 60 s
#
# Reads /proc/net/dev once a second (it is per network namespace, which is
# what lets the simulation use it on a veth exactly as the cart uses it on
# enP5p3s0) and prints a summary of the deltas: mean, peak second and total,
# for bytes and packets, each direction. With OUT.csv every sample is kept.
#
# No root, no tcpdump, no dependency on what is producing the traffic. The
# numbers are the NIC's own counters, so they include everything: DDS,
# ssh, chrony, ARP. On the cart during a run DDS is all of it that matters.
#
# What to look at: `tx peak` and `rx peak` are the burst figure; a link that
# "sticks" does so in the worst second, not the mean one. On 100 Mb/s the
# ceiling is 12.5 MB/s each way, in practice ~11.
set -uo pipefail

IFACE="${1:?usage: link_pressure.sh IFACE SECONDS [OUT.csv]}"
SECONDS_TO_RUN="${2:?usage: link_pressure.sh IFACE SECONDS [OUT.csv]}"
OUT="${3:-}"

read_counters() {
    # rx_bytes rx_packets tx_bytes tx_packets
    awk -v ifc="${IFACE}:" '$1 == ifc {print $2, $3, $10, $11}' /proc/net/dev
}

if [ -z "$(read_counters)" ]; then
    echo "link_pressure: no interface '${IFACE}' in /proc/net/dev" >&2
    exit 1
fi

[ -n "$OUT" ] && echo "t,rx_bytes,rx_pkts,tx_bytes,tx_pkts" > "$OUT"

read -r rb0 rp0 tb0 tp0 < <(read_counters)
prev_rb=$rb0; prev_rp=$rp0; prev_tb=$tb0; prev_tp=$tp0
rx_peak=0; tx_peak=0; rxp_peak=0; txp_peak=0
for ((t = 1; t <= SECONDS_TO_RUN; t++)); do
    sleep 1
    read -r rb rp tb tp < <(read_counters)
    drb=$((rb - prev_rb)); drp=$((rp - prev_rp))
    dtb=$((tb - prev_tb)); dtp=$((tp - prev_tp))
    prev_rb=$rb; prev_rp=$rp; prev_tb=$tb; prev_tp=$tp
    [ "$drb" -gt "$rx_peak" ] && rx_peak=$drb
    [ "$dtb" -gt "$tx_peak" ] && tx_peak=$dtb
    [ "$drp" -gt "$rxp_peak" ] && rxp_peak=$drp
    [ "$dtp" -gt "$txp_peak" ] && txp_peak=$dtp
    [ -n "$OUT" ] && echo "$t,$drb,$drp,$dtb,$dtp" >> "$OUT"
done

rx_total=$((prev_rb - rb0)); tx_total=$((prev_tb - tb0))
rxp_total=$((prev_rp - rp0)); txp_total=$((prev_tp - tp0))

fmt() { # bytes -> "N kB/s (M Mbit/s)"
    awk -v b="$1" 'BEGIN {printf "%8.1f kB/s (%6.2f Mbit/s)", b / 1000, b * 8 / 1e6}'
}

echo "link_pressure ${IFACE} over ${SECONDS_TO_RUN}s"
echo "  tx mean  $(fmt $((tx_total / SECONDS_TO_RUN)))   $((txp_total / SECONDS_TO_RUN)) pkt/s"
echo "  tx peak  $(fmt "$tx_peak")   ${txp_peak} pkt/s"
echo "  rx mean  $(fmt $((rx_total / SECONDS_TO_RUN)))   $((rxp_total / SECONDS_TO_RUN)) pkt/s"
echo "  rx peak  $(fmt "$rx_peak")   ${rxp_peak} pkt/s"
echo "  total    tx ${tx_total} B / ${txp_total} pkts, rx ${rx_total} B / ${rxp_total} pkts"
