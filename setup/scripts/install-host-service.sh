#!/usr/bin/env bash
# install-host-service.sh - one-time provisioning of a golf cart host's systemd
# user units.
#
#   install-host-service.sh master|orin [--remove] [--remote [user@host]]
#
# One script for both machines, run either locally or - with --remote - against
# the far side over ssh, where it re-invokes itself inside that machine's own
# checkout. Replaces install-orin-host.sh, which knew only about the orin: the
# master's unit had no installer at all and its lingering was never enabled, so
# its units would have died with the terminal that started them.
#
# --remote is deliberately the ONE path here that may prompt. It is the bootstrap
# step, run before key-based ssh necessarily exists, and enabling lingering on the
# far side needs that machine's sudo - so it allocates a tty and lets ssh and sudo
# ask the user directly. Every other script in this repo uses BatchMode=yes and
# must never prompt.
#
# The unit files in setup/files/systemd are role-independent. Everything specific
# to this machine - which role it plays, and where the repo actually lives - is
# written as a drop-in here. That retires the %h/2026-golf-cart hardcode, which
# previously only produced a warning at install time and then a failure at start
# time on any checkout living somewhere else.
#
# Requires sudo only for `loginctl enable-linger`.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
UNIT_SRC="${REPO_DIR}/setup/files/systemd"
UNIT_DST="${HOME}/.config/systemd/user"

usage() {
    echo "usage: $(basename "$0") <master|orin> [--remove] [--remote [user@host]]" >&2
    exit 2
}

ROLE=""
REMOVE=0
REMOTE=0
REMOTE_DEST=""
while [ $# -gt 0 ]; do
    case "$1" in
        master|orin) ROLE="$1" ;;
        --remove)    REMOVE=1 ;;
        --remote)
            REMOTE=1
            # An optional destination may follow; anything starting with - is the
            # next flag, not a host.
            case "${2:-}" in
                ""|-*) ;;
                *) REMOTE_DEST="$2"; shift ;;
            esac
            ;;
        -h|--help)   usage ;;
        *)           echo "unknown argument: $1" >&2; usage ;;
    esac
    shift
done
[ -n "${ROLE}" ] || usage

if [ "${REMOTE}" -eq 1 ]; then
    CONF="${REPO_DIR}/config/multi_machine.conf"
    # shellcheck source=/dev/null
    [ -f "${CONF}" ] && . "${CONF}"
    DEST="${REMOTE_DEST:-${ORIN_SSH:-${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}}}"
    # The far side has its own checkout; this script runs from THAT copy, so the
    # drop-in it writes points at the remote path rather than this machine's.
    REMOTE_REPO="${ORIN_WORKSPACE:-${GOLFCART_ORIN_WORKSPACE:-2026-golf-cart}}"

    echo "Provisioning ${ROLE} on ${DEST} (repo: ~/${REMOTE_REPO})..."
    echo "You may be asked for ${DEST}'s login password, and for its sudo password."
    echo

    ARGS="${ROLE}"
    [ "${REMOVE}" -eq 1 ] && ARGS="${ARGS} --remove"

    # -t: sudo on the far side needs a terminal to prompt on. No BatchMode here,
    # on purpose - see the header.
    if ! ssh -t -o StrictHostKeyChecking=accept-new "${DEST}" \
            "cd ~/${REMOTE_REPO} && ./setup/scripts/install-host-service.sh ${ARGS}"; then
        echo >&2
        echo "ERROR: remote provisioning of ${DEST} failed." >&2
        echo "       Check the repo is at ~/${REMOTE_REPO} there and up to date." >&2
        exit 1
    fi
    echo
    echo "Remote provisioning of ${DEST} done."
    exit 0
fi

# The DDS profile is the same thing launch_unit_exec.sh resolves at start time;
# checking it here turns a runtime failure into an install-time one.
if [ ! -f "${REPO_DIR}/config/cyclonedds/${ROLE}.xml" ]; then
    echo "ERROR: no config/cyclonedds/${ROLE}.xml in ${REPO_DIR}" >&2
    exit 1
fi

# The watchdog is orin-only: it exists to notice a missing master, which is not a
# question the master can ask about itself.
case "${ROLE}" in
    master) UNITS=(golfcart-launch.service golfcart-record.service) ;;
    orin)   UNITS=(golfcart-launch.service golfcart-record.service golfcart-watchdog.service) ;;
esac

# ExecStart per unit, as absolute paths into the resolved repo. Kept here rather
# than derived from the shipped unit file so a mistyped path shows up as a
# missing file below instead of a unit that starts nothing.
exec_start_for() {
    case "$1" in
        golfcart-launch.service)   echo "${REPO_DIR}/scripts/multi_machine/launch_unit_exec.sh" ;;
        golfcart-record.service)   echo "${REPO_DIR}/scripts/recording/record_unit_exec.sh" ;;
        golfcart-watchdog.service) echo "${REPO_DIR}/scripts/multi_machine/watchdog.sh" ;;
    esac
}

if [ "${REMOVE}" -eq 1 ]; then
    echo "Removing golf cart systemd user units (${ROLE})..."
    for unit in "${UNITS[@]}"; do
        # Stop before disable: a disabled-but-running unit is the worst outcome,
        # since nothing left on disk explains what is still holding the DDS domain.
        systemctl --user stop "${unit}" 2>/dev/null || true
        systemctl --user disable "${unit}" 2>/dev/null || true
        rm -f "${UNIT_DST}/${unit}"
        rm -rf "${UNIT_DST}/${unit}.d"
        echo "  ${unit}"
    done
    systemctl --user daemon-reload
    # Lingering is left alone on purpose: it is a per-user setting that other
    # services may rely on, and removing these units is not a reason to revoke it.
    echo
    echo "Done. Lingering left unchanged (revoke manually with:"
    echo "  sudo loginctl disable-linger ${USER})"
    exit 0
fi

echo "Installing systemd user units for role '${ROLE}' from ${REPO_DIR}..."
mkdir -p "${UNIT_DST}"
for unit in "${UNITS[@]}"; do
    install -m 644 "${UNIT_SRC}/${unit}" "${UNIT_DST}/${unit}"

    start="$(exec_start_for "${unit}")"
    if [ ! -x "${start}" ]; then
        # Not fatal: record_unit_exec.sh may arrive with a later checkout, and a
        # half-provisioned host is still more useful than a failed install.
        echo "  WARNING: ${start} is missing or not executable" >&2
    fi

    mkdir -p "${UNIT_DST}/${unit}.d"
    {
        echo "# Generated by setup/scripts/install-host-service.sh - do not edit."
        echo "# Re-run the installer to regenerate after moving the repository."
        echo "[Service]"
        echo "Environment=GOLFCART_HOST=${ROLE}"
        echo "Environment=GOLFCART_WORKSPACE=${REPO_DIR}"
        # The empty assignment is required: ExecStart= is a list-valued directive,
        # so without the reset the drop-in would APPEND a second command rather
        # than replace the shipped %h/2026-golf-cart one.
        echo "ExecStart="
        echo "ExecStart=${start}"
    } > "${UNIT_DST}/${unit}.d/override.conf"

    echo "  ${unit} (+ override.conf)"
done

echo "Reloading the user systemd manager..."
systemctl --user daemon-reload

# Without lingering, the user manager exits when the last session closes, taking
# the units with it - and both hosts are driven over non-interactive ssh sessions
# (the master by `just`, the orin by orin_remote.sh), which are exactly that.
if loginctl show-user "${USER}" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    echo "Lingering already enabled for ${USER}."
else
    echo
    echo "Enabling lingering for ${USER}. This is the only step needing sudo:"
    echo "  sudo loginctl enable-linger ${USER}"
    sudo loginctl enable-linger "${USER}"
fi

echo
echo "Done. The units are installed but NOT enabled - they are started on demand,"
echo "never at boot. Check with:"
for unit in "${UNITS[@]}"; do
    echo "  systemctl --user status ${unit}"
done
