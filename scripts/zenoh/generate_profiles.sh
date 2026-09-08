#!/usr/bin/env bash
# Regenerate config/zenoh/*.json5 from the rmw_zenoh_cpp defaults installed on
# this machine.
#
#     scripts/zenoh/generate_profiles.sh           # write config/zenoh/
#     scripts/zenoh/generate_profiles.sh --check   # exit 1 if they are stale
#
# WHY GENERATE RATHER THAN HAND-WRITE
#
# Zenoh fills every absent key from ITS OWN defaults, which are not the same as
# rmw_zenoh's. rmw_zenoh ships an ~820-line session config that turns multicast
# scouting OFF, pins sessions to localhost, sizes the SHM transport-optimization
# pool and raises queries_default_timeout to 600 s. A short hand-written profile
# listing only the keys we care about would silently discard all of that.
#
# So each profile here is a FULL COPY of the shipped default with a named,
# auditable set of edits applied. The edit list below is the entire difference
# between this repo's Zenoh configuration and stock rmw_zenoh; there is nothing
# hidden in the 800 lines that follow it in each file.
#
# --check is what keeps that claim true across a package upgrade. Bumping
# ros-humble-rmw-zenoh-cpp changes the shipped defaults underneath us, and a
# profile generated against 0.1.9 would then be a silent 800-line divergence
# rather than a three-key one. `just service doctor` runs the check.
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

SESSION_DEFAULT="${SHARE}/DEFAULT_RMW_ZENOH_SESSION_CONFIG.json5"

if [ ! -f "${SESSION_DEFAULT}" ]; then
    {
        echo "ERROR: rmw_zenoh_cpp default config not found at:"
        echo "         ${SESSION_DEFAULT}"
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
        echo "       Zenoh listen endpoints must be addresses, not hostnames:" >&2
        echo "       name resolution is one more thing that can fail on the exact" >&2
        echo "       link these profiles exist to establish." >&2
        exit 1
    fi
done

emit() {
    # emit <out-file> <role-description> <edit-spec...>   (specs are old<US>new<US>note)
    local dst="$1" desc="$2"; shift 2
    python3 - "${SESSION_DEFAULT}" "$dst" "$desc" "$@" <<'PYEOF'
import sys

src, dst, desc = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src, encoding="utf-8").read()

applied = []
for spec in sys.argv[4:]:
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
header += [f"//   * {n}" for n in applied]
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
# Topology: a peer clique discovered by multicast, with NO Zenoh router.
#
# This is deliberately the same shape as the CycloneDDS deployment it replaces --
# multicast discovery, then direct point-to-point links between peers -- and it
# is the reason there is no rmw_zenohd anywhere in this repo.
#
# The router is not architecturally required by rmw_zenoh. It is required only
# because rmw_zenoh ships `scouting.multicast.enabled: false`, which leaves
# router gossip as the sole discovery path. Zenoh has had Cyclone's SPDP-style
# multicast discovery all along; it is simply switched off. Measured on the
# master, single host, talker/listener over 25 s:
#
#     router up, multicast off (stock)   25 published  25 heard  0 duplicated
#     no router, multicast on            26 published  26 heard  0 duplicated
#
# The router-less run also does not emit the "Scouting delay elapsed before
# start conditions are met" warning that every node logs under the router
# arrangement.
#
# Dropping the router removes a whole failure mode rather than merely a process:
# with a router configured but absent, nodes do not fail and do not hang -- they
# start, publish, and are discovered by nobody, behind a single log line that
# says "Proceeding with initialization".
#
# Three edits, and none is optional:
#
#   scouting.multicast.enabled -> true
#       The whole point. Without it nothing discovers anything once the router
#       is gone.
#
#   connect.endpoints -> empty
#       Stock points every session at tcp/localhost:7447. With no router there,
#       each session would retry that endpoint forever (exit_on_failure.peer is
#       false, so it is not fatal, just permanent and noisy).
#
#   listen.endpoints -> the host's LAN address
#       Stock sessions listen on tcp/localhost:0, so the locator a node
#       advertises is 127.0.0.1 -- reachable from nothing on the other host.
#       Multicast would announce the peer and the far side still could not dial
#       it. Binding the specific LAN address rather than 0.0.0.0 keeps the LiDAR
#       nets (192.168.7.1, 172.168.1.1) and the 4G NIC out of the advertised
#       locator set, so a remote peer does not spend a connect timeout on each
#       unreachable address before finding the one that works.
#
# NOT edited, and worth knowing: `routing.peer.mode` stays "peer_to_peer". That
# is Zenoh's clique topology -- every peer linked directly to every other -- and
# it is already the shipped default. "clique" is the name Zenoh's documentation
# gives that topology, not a value the config accepts; the accepted values are
# "peer_to_peer" and "linkstate", as the comment above that key in each
# generated file says.
#
# Cost, recorded here because it is the thing to measure first: a clique means
# links scale with the square of the PROCESS count. Process, not node --
# rmw_zenoh opens one session per context, and config/runtime.conf keeps
# GOLFCART_CONTAINER_MODE=observable, so composable nodes share their
# container's session. Under `isolated` the same mesh is drawn between ~149
# processes, which is the shape of the problem that made CycloneDDS unusable in
# the first place.

MULTICAST_EDIT=$'      /// ROS setting: disable multicast discovery by default\n      enabled: false,\x1f      /// ROS setting: ENABLED HERE. This deployment runs no Zenoh router, so\n      /// multicast scouting is the only discovery path. See\n      /// scripts/zenoh/generate_profiles.sh and config/zenoh/README.md.\n      enabled: true,\x1fscouting.multicast.enabled -> true (stock: false)'

CONNECT_EDIT=$'    /// ROS setting: By default connect to the Zenoh router on localhost on port 7447.\n    endpoints: [\n      "tcp/localhost:7447"\n    ],\x1f    /// ROS setting: EMPTIED HERE. There is no Zenoh router to connect to;\n    /// peers find each other by multicast scouting and then link directly.\n    endpoints: [\n    ],\x1fconnect.endpoints -> empty, no router (stock: tcp/localhost:7447)'

emit "${OUT_DIR}/master-session.json5" \
    "Zenoh session for every ROS process on the MASTER host (cart AGX Orin, ${MASTER_IP}). Peer mode, multicast discovery, direct peer links. No Zenoh router runs anywhere in this deployment." \
    "${MULTICAST_EDIT}" "${CONNECT_EDIT}" \
    "$(printf '      "tcp/localhost:0"\x1f      "tcp/%s:0"\x1flisten.endpoints -> the LAN address (stock: tcp/localhost:0)' "${MASTER_IP}")"

emit "${OUT_DIR}/orin-session.json5" \
    "Zenoh session for every ROS process on the ORIN host (slave Jetson, ${ORIN_IP}). Mirror of master-session.json5 with the address swapped." \
    "${MULTICAST_EDIT}" "${CONNECT_EDIT}" \
    "$(printf '      "tcp/localhost:0"\x1f      "tcp/%s:0"\x1flisten.endpoints -> the LAN address (stock: tcp/localhost:0)' "${ORIN_IP}")"

# No loopback profile, deliberately. Single-machine operation gets the shipped
# defaults, because scripts/env.sh leaves ZENOH_SESSION_CONFIG_URI UNSET for that
# role -- a stronger guarantee than a checked-in copy that is byte-identical
# today, since the copy can drift when the package is upgraded.
#
# Note what that means: under the loopback role a node still expects a router,
# because the stock config points at one and has multicast off. Single-machine
# zenoh is not a path this repo has set up; the two-host profiles are.

if [ "${CHECK_ONLY}" = "1" ]; then
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
