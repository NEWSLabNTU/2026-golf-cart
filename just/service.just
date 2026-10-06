# Multi-machine systemd user units, one role per machine
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory, and every `./scripts/...` path
# in the repo breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so without this `just vehicle` would bring up the vehicle interface and
# `just ntu-test` would start a bag. Naming it `default` makes the harmless
# thing the accident.
# List this module's recipes
default:
    @just --list service

# Provision the orin over ssh (may prompt for its password and sudo).
install-orin:
    # Runs before key-based ssh necessarily exists, and lingering needs the
    # orin's sudo - hence the tty. Every other remote call is BatchMode=yes.
    ./scripts/multi_machine/on_orin.sh --tty just service install orin

# Unit states on both hosts.
status:
    #!/usr/bin/env bash
    just service host-status
    ./scripts/multi_machine/on_orin.sh just service host-status \
        || echo "orin: unreachable" >&2

# Generate an ssh key if needed and copy it to the orin (one password prompt).
ssh-setup DEST="":
    ./scripts/multi_machine/setup_ssh.sh {{DEST}}

# ============================================================================
# Recording - independent of the launch, start it whenever you want

# What this host's golfcart units are doing.
host-status:
    #!/usr/bin/env bash
    for u in golfcart-launch golfcart-record golfcart-watchdog; do
        state=$(systemctl --user is-active "${u}.service" 2>/dev/null)
        [ "$state" = "inactive" ] && ! systemctl --user cat "${u}.service" >/dev/null 2>&1 && continue
        printf '%s: %-18s %s\n' "$(hostname)" "${u#golfcart-}" "$state"
    done
    # Which middleware this host is on. Both machines must agree: the two RMWs
    # share no wire protocol, so a mismatched pair does not error - each comes up
    # cleanly and simply never sees the other's topics. That is the single most
    # confusing state this deployment can be in, so it is reported first-class,
    # next to the units, on both hosts.
    RMW=$(
        GOLFCART_ENV_RESOLVE_ONLY=1 GOLFCART_ENV_QUIET=1 \
        bash -c 'source {{justfile_directory()}}/scripts/env.sh; printf "%s" "${GOLFCART_RMW}"'
    ) || RMW="?"
    printf '%s: %-18s %s\n' "$(hostname)" "middleware" "${RMW}"

# ── Both hosts, driven from the master ──────────────────────────────────────

# Environment, DDS profile, units and disk - run this when topics do not show up.
doctor:
    ./scripts/doctor.sh

# The same diagnostic, run on the orin over ssh.
doctor-orin:
    ./scripts/multi_machine/on_orin.sh ./scripts/doctor.sh

# Install this host's systemd user units. ROLE: master or orin.
install ROLE:
    ./setup/scripts/install-host-service.sh {{ROLE}}

# Remove this host's systemd user units. ROLE: master or orin.
remove ROLE:
    ./setup/scripts/install-host-service.sh {{ROLE}} --remove
