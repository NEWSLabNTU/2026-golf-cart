#!/usr/bin/env bash
# Make sure a recipe has the ROS / Autoware environment, however it was invoked.
#
#     source scripts/_env_guard.sh
#
# `.envrc` sets this up for an interactive shell, but `just build` run from a
# bare shell, a systemd unit, or an ssh command gets nothing. colcon then fails
# a long way from the cause: the Rust packages report a missing message crate
# and the launch packages report a missing package.sh, neither of which says
# "the environment was never sourced".
#
# All the real logic stays in scripts/env.sh, per the note there about direnv
# shells and bare shells not being allowed to drift apart. This only decides
# whether to call it, and says something useful when Autoware is absent.

_golfcart_env_guard() {
    local root
    root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

    # AMENT_PREFIX_PATH is set by any ROS setup file, so its absence means no
    # environment at all. Re-sourcing when it is already set would be harmless
    # but noisy, and would re-print env.sh's banners on every build.
    if [ -z "${AMENT_PREFIX_PATH:-}" ] && [ -f "${root}/scripts/env.sh" ]; then
        # env.sh is written to be sourced into interactive shells and does not
        # expect -e/-u; recipes run under `set -e`.
        local saved="$-"
        set +eu
        # shellcheck source=/dev/null
        . "${root}/scripts/env.sh"
        case "$saved" in *e*) set -e ;; esac
        case "$saved" in *u*) set -u ;; esac
    fi

    if [ ! -f /opt/autoware/1.5.0/setup.bash ]; then
        echo "→ Autoware not found at /opt/autoware/1.5.0/setup.bash"
        echo "  Packages that need its messages will fail to build. Install it with:"
        echo "      ./setup.sh autoware-debian     # or ./setup.sh for the full setup"
    fi
}

_golfcart_env_guard
