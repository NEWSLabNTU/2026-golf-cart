#!/usr/bin/env bash
# Regenerate config/zenoh/*.json5 from the rmw_zenoh_cpp defaults installed on
# this machine.
#
#     scripts/zenoh/generate_profiles.sh          # write config/zenoh/
#     scripts/zenoh/generate_profiles.sh --check   # exit 1 if they are stale
#
# WHY GENERATE RATHER THAN HAND-WRITE
#
# Zenoh fills every absent key from ITS OWN defaults, which are not the same as
# rmw_zenoh's. rmw_zenoh ships two ~815-line files that turn multicast scouting
# OFF, pin sessions to localhost, size the SHM transport-optimization pool and
# raise queries_default_timeout to 600 s. A short hand-written profile listing
# only the keys we care about would silently discard all of that -- most
# damagingly it would re-enable multicast scouting, because upstream Zenoh
# defaults it to true and rmw_zenoh defaults it to false.
#
# So each profile here is a FULL COPY of the shipped default with a named,
# auditable set of edits applied. The edit list below is the entire difference
# between this repo's Zenoh configuration and stock rmw_zenoh; there is nothing
# hidden in the 800 lines that follow it in each file.
#
# --check is what keeps that claim true across a package upgrade. Bumping
# ros-humble-rmw-zenoh-cpp changes the shipped defaults underneath us, and a
# profile generated against 0.1.9 would then be a silent 800-line divergence
# rather than a two-key one. `just service doctor` runs the check.
set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
OUT_DIR="${REPO_ROOT}/config/zenoh"

CHECK_ONLY=0
[ "${1:-}" = "--check" ] && CHECK_ONLY=1

# ── Where the shipped defaults live ──────────────────────────────────────────
# Resolved from the ament index when a ROS environment is sourced, so a
# non-standard install prefix still works; the /opt path is the fallback for a
# bare shell (this script is deliberately runnable without sourcing ROS).
SHARE=""
if command -v ros2 >/dev/null 2>&1 && ros2 pkg prefix rmw_zenoh_cpp >/dev/null 2>&1; then
    SHARE="$(ros2 pkg prefix rmw_zenoh_cpp)/share/rmw_zenoh_cpp/config"
fi
[ -d "${SHARE}" ] || SHARE="/opt/ros/humble/share/rmw_zenoh_cpp/config"

ROUTER_DEFAULT="${SHARE}/DEFAULT_RMW_ZENOH_ROUTER_CONFIG.json5"
SESSION_DEFAULT="${SHARE}/DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5"

if [ ! -f "${ROUTER_DEFAULT}" ] || [ ! -f "${SESSION_DEFAULT}" ]; then
    {
        echo "ERROR: rmw_zenoh_cpp default configs not found under:"
        echo "         ${SHARE}"
        echo "       Install the package first:"
        echo "         sudo apt install ros-humble-rmw-zenoh-cpp"
    } >&2
    exit 1
fi

# ── Addresses ────────────────────────────────────────────────────────────────
# Taken from config/multi_machine.conf so the two hosts' addresses are stated in
# exactly one tracked place. config/cyclonedds/*.xml still carries its own copy;
# that is pre-existing duplication, and this file deliberately does not add a
# third.
MASTER_IP="192.168.125.100"
ORIN_SSH="jetson@192.168.125.101"
# shellcheck source=/dev/null
[ -f "${REPO_ROOT}/config/multi_machine.conf" ] && . "${REPO_ROOT}/config/multi_machine.conf"
ORIN_IP="${ORIN_SSH##*@}"   # strip the user@ prefix; the host part is the address

for ip in "${MASTER_IP}" "${ORIN_IP}"; do
    if ! printf '%s' "$ip" | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
        echo "ERROR: '${ip}' is not a dotted-quad address." >&2
        echo "       Zenoh listen/connect endpoints must be addresses, not hostnames:" >&2
        echo "       name resolution is one more thing that can fail on the exact" >&2
        echo "       link these profiles exist to establish." >&2
        exit 1
    fi
done

emit() {
    # emit <default-file> <out-file> <role-description> <python-edit-args...>
    local src="$1" dst="$2" desc="$3"; shift 3
    python3 - "$src" "$dst" "$desc" "$@" <<'PYEOF'
import sys

src, dst, desc = sys.argv[1], sys.argv[2], sys.argv[3]
edits = sys.argv[4:]           # flat list of old\x1fnew pairs

text = open(src, encoding="utf-8").read()

applied = []
for spec in edits:
    old, new, note = spec.split("\x1f")
    n = text.count(old)
    if n != 1:
        sys.exit(f"anchor {old!r} matched {n} times in {src} (expected exactly 1); "
                 "the shipped default has changed -- update generate_profiles.sh")
    text = text.replace(old, new)
    applied.append(note)

header = [
    "// GENERATED FILE -- do not edit by hand.",
    "//",
    f"// {desc}",
    "//",
    "// Produced by scripts/zenoh/generate_profiles.sh from",
    f"//   {src}",
    "// which is a full copy of the rmw_zenoh_cpp shipped default. Everything",
    "// below is stock EXCEPT the following edits:",
    "//",
]
for note in applied:
    header.append(f"//   * {note}")
header += [
    "//",
    "// Re-run the generator after upgrading ros-humble-rmw-zenoh-cpp;",
    "// `scripts/zenoh/generate_profiles.sh --check` reports drift.",
    "",
]
open(dst, "w", encoding="utf-8").write("\n".join(header) + text)
PYEOF
}

# ── The edits, stated once ───────────────────────────────────────────────────
#
# Topology: peer mesh over the LAN. Nodes stay Zenoh peers and open DIRECT links
# to each other, on both hosts; the routers exist only to carry discovery. The
# alternative -- nodes in client mode with the routers brokering every message --
# is the path rmw_zenoh's README documents, and it was rejected here because it
# puts the master's own PointCloud2 traffic through an extra process hop even
# though both ends are on the same box.
#
# Two edits make that work, and neither is optional:
#
#   listen on the LAN address (sessions only)
#       Stock sessions listen on tcp/localhost:0, so the locator a node
#       advertises is 127.0.0.1 -- reachable from nothing on the other host. A
#       peer on the orin cannot dial a peer on the master no matter what
#       discovery tells it. Binding the specific LAN address, rather than
#       0.0.0.0, keeps the LiDAR nets (192.168.7.1, 172.168.1.1) and the 4G NIC
#       out of the advertised locator set -- otherwise every remote peer tries
#       those unreachable addresses first and eats a connect timeout per link.
#
#   gossip multihop (routers and sessions)
#       Stock gossip is single-hop: router A announces its own direct neighbours
#       and nothing re-propagates. A peer on the master therefore learns that
#       router B exists but never that the orin's peers do. It does eventually
#       converge -- each peer autoconnects to the REMOTE router, and is then a
#       direct neighbour of it, and learns the far side that way -- but the
#       route there opens an extra cross-host link per peer and the timing is
#       nobody's design. Multihop makes router A propagate router B's
#       neighbours, so a peer learns the far side in one step and connects
#       straight to it.
#
# Cost, recorded here because it is the thing to measure first: peers
# autoconnect to peers (scouting.gossip.autoconnect.peer = ["router","peer"]),
# so this is a FULL MESH across both hosts -- links scale with the square of the
# PROCESS count. Process count, not node count: rmw_zenoh opens one session per
# context, and config/runtime.conf keeps GOLFCART_CONTAINER_MODE=observable, so
# composable nodes share their container's session. Under `isolated` that same
# mesh is drawn between ~149 processes instead, which is the shape of the
# problem that made CycloneDDS unusable in the first place.

MULTIHOP_EDIT=$'      multihop: false,\x1f      multihop: true,\x1fgossip multihop enabled (stock: false)'

emit "${ROUTER_DEFAULT}" "${OUT_DIR}/master-router.json5" \
    "Zenoh router for the MASTER host (cart AGX Orin, ${MASTER_IP}). Listens on the stock tcp/[::]:7447 and dials nobody: the orin's router is the side that initiates, so that a master restart is recovered by the orin's existing connect-retry loop rather than needing one here." \
    "${MULTIHOP_EDIT}"

emit "${ROUTER_DEFAULT}" "${OUT_DIR}/orin-router.json5" \
    "Zenoh router for the ORIN host (slave Jetson, ${ORIN_IP}). Dials the master's router; connect.exit_on_failure.router is stock false and the retry loop caps at 4 s, so this comes up whether or not the master is already running, and reconnects on its own if the master restarts." \
    "${MULTIHOP_EDIT}" \
    "$(printf '    endpoints: [\n      // "<proto>/<address>"\n    ],\x1f    endpoints: [\n      "tcp/%s:7447"\n    ],\x1fconnect.endpoints -> the master router (stock: empty)' "${MASTER_IP}")"

emit "${SESSION_DEFAULT}" "${OUT_DIR}/master-session.json5" \
    "Zenoh session for every ROS process on the MASTER host. Stays mode:\"peer\" and keeps the stock connect to the local router on tcp/localhost:7447 for discovery." \
    "${MULTIHOP_EDIT}" \
    "$(printf '      "tcp/localhost:0"\x1f      "tcp/%s:0"\x1flisten.endpoints -> the LAN address (stock: tcp/localhost:0)' "${MASTER_IP}")"

emit "${SESSION_DEFAULT}" "${OUT_DIR}/orin-session.json5" \
    "Zenoh session for every ROS process on the ORIN host. Mirror of master-session.json5 with the address swapped." \
    "${MULTIHOP_EDIT}" \
    "$(printf '      "tcp/localhost:0"\x1f      "tcp/%s:0"\x1flisten.endpoints -> the LAN address (stock: tcp/localhost:0)' "${ORIN_IP}")"

# No loopback profile, deliberately. Single-machine operation wants exactly the
# shipped defaults -- peer sessions on localhost, one local router, no LAN
# listener -- so scripts/env.sh leaves ZENOH_SESSION_CONFIG_URI and
# ZENOH_ROUTER_CONFIG_URI UNSET for the loopback role. An unset variable is a
# stronger statement than a file that happens to be byte-identical to the
# default: it cannot drift.

if [ "${CHECK_ONLY}" = "1" ]; then
    # emit() has just overwritten the files; ask git whether that changed
    # anything. Untracked (never generated) counts as stale too.
    if ! git -C "${REPO_ROOT}" diff --quiet -- config/zenoh 2>/dev/null \
       || [ -n "$(git -C "${REPO_ROOT}" ls-files --others --exclude-standard -- config/zenoh)" ]; then
        {
            echo "config/zenoh/ is STALE with respect to the installed rmw_zenoh_cpp."
            echo "Regenerate and commit:"
            echo "    scripts/zenoh/generate_profiles.sh"
            echo "    git add config/zenoh && git commit"
        } >&2
        exit 1
    fi
    echo "config/zenoh/ is up to date with the rmw_zenoh_cpp defaults in ${SHARE}"
    exit 0
fi

echo "Wrote:"
for f in "${OUT_DIR}"/*.json5; do echo "  ${f#"${REPO_ROOT}"/}"; done
