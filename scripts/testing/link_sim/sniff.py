#!/usr/bin/env python3
"""Attribute link bytes to DDS domains and to multicast vs unicast.

    sniff.py IFACE OUT_FILE MASTER_IP [DOMAINS]

Opens a raw AF_PACKET socket on IFACE (CAP_NET_RAW, which the user namespace
the simulation runs in grants over its own network namespace; tcpdump cannot
be used there because it insists on dropping to a gid the namespace cannot
set) and counts every IPv4/UDP frame until SIGINT or SIGTERM, then writes a
table of bytes and packets by (direction, domain, class).

Direction is by source address: from MASTER_IP is "master->orin", anything
else "orin->master".

The domain is read off the DESTINATION port. CycloneDDS lays its ports out per
domain id d as 7400 + 250*d + {0: multicast discovery, 1: multicast data,
10+2i: unicast discovery, 11+2i: unicast data} for participant index i, so
the port says which domain a datagram belongs to, and whether it is discovery
or data. Almost: with MaxAutoParticipantIndex 200 a domain's unicast ports
run 400 past its base, into the next domain's range, so DOMAINS (default
"0,42", the two this deployment uses) says which bases exist and a port is
charged to the highest base at or below it.

Fragments: MaxMessageSize is 65500 B in every profile here, so most data
datagrams are IP-fragmented and only the first fragment carries a UDP header.
The first fragment's class is remembered under (src, dst, IP id) and later
fragments are charged to it.

The line this exists to produce, for the pre-split profiles: how many bytes
the master sent to a multicast address in domain 0 while the orin subscribed
to none of it. That is the traffic the split removes by construction rather
than by list.
"""

import signal
import socket
import struct
import sys
from collections import defaultdict

BASE = 7400
GAIN = 250
ETH_P_ALL = 0x0003


def classify_port(port, domains):
    d = None
    for cand in domains:
        if port >= BASE + GAIN * cand:
            d = cand
    if d is None:
        return ("other", "unicast")
    off = port - (BASE + GAIN * d)
    if off in (0, 1):
        return (str(d), "multicast-" + ("discovery" if off == 0 else "data"))
    if off >= 10:
        return (str(d), "unicast-" + ("discovery" if off % 2 == 0 else "data"))
    return (str(d), "unknown")


def main():
    iface, out_path, master_ip = sys.argv[1], sys.argv[2], sys.argv[3]
    domains = sorted(int(x) for x in (sys.argv[4] if len(sys.argv) > 4 else "0,42").split(","))
    master = socket.inet_aton(master_ip)
    bytes_by = defaultdict(int)
    pkts_by = defaultdict(int)
    frag_class = {}
    stop = False

    def on_signal(_sig, _frame):
        nonlocal stop
        stop = True
    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(ETH_P_ALL))
    s.bind((iface, 0))
    s.settimeout(0.5)

    while not stop:
        try:
            frame, meta = s.recvfrom(65600)
        except socket.timeout:
            continue
        except InterruptedError:
            continue
        except OSError:
            break  # the interface went away; write what was counted
        # Only what leaves or arrives on the wire: PACKET_OUTGOING (4) frames
        # are the ones this host sent, everything else is received.
        if len(frame) < 34 or frame[12:14] != b"\x08\x00":
            continue
        ihl = (frame[14] & 0x0F) * 4
        total_len = struct.unpack("!H", frame[16:18])[0]
        ip_id = struct.unpack("!H", frame[18:20])[0]
        frag = struct.unpack("!H", frame[20:22])[0]
        offset = (frag & 0x1FFF) * 8
        proto = frame[23]
        src = frame[26:30]
        dst = frame[30:34]
        if proto != 17:
            continue
        direction = "master->orin" if src == master else "orin->master"
        is_mcast = (dst[0] & 0xF0) == 0xE0
        if offset == 0:
            dport = struct.unpack("!H", frame[14 + ihl + 2:14 + ihl + 4])[0]
            domain, kind = classify_port(dport, domains)
            if is_mcast and not kind.startswith("multicast"):
                kind = "multicast-" + kind.split("-", 1)[-1]
            key = (direction, domain, kind)
            if frag & 0x2000:  # more fragments follow
                frag_class[(src, dst, ip_id)] = key
        else:
            key = frag_class.get(
                (src, dst, ip_id),
                (direction, "fragment-of-unknown", "multicast" if is_mcast else "unicast"))
            if not (frag & 0x2000):
                frag_class.pop((src, dst, ip_id), None)
        bytes_by[key] += total_len
        pkts_by[key] += 1

    rows = sorted(bytes_by.items(), key=lambda kv: (kv[0][0], -kv[1]))
    total = defaultdict(int)
    with open(out_path, "w") as f:
        f.write(f"{'direction':<14}{'domain':<22}{'class':<22}{'bytes':>14}{'packets':>10}\n")
        for key, b in rows:
            direction, domain, kind = key
            f.write(f"{direction:<14}{domain:<22}{kind:<22}{b:>14}{pkts_by[key]:>10}\n")
            total[direction] += b
        for direction, b in sorted(total.items()):
            f.write(f"{direction:<14}{'TOTAL':<22}{'':<22}{b:>14}\n")


if __name__ == "__main__":
    main()
