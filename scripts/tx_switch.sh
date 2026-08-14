#!/usr/bin/env bash
# tx_switch.sh - pull the `tx=on|off` token out of a list of launch arguments.
#
# `just launch` and `just launch-up` both accept it, and both need the same two
# answers out of it, so the parsing lives here rather than being written twice:
#
#     eval "$(scripts/tx_switch.sh "$@")"
#
# emits shell assignments on stdout:
#
#     GOLFCART_TX_SET=0|1        was a tx= token present at all
#     GOLFCART_TX_ENABLED=...    true|false, only when GOLFCART_TX_SET=1
#     GOLFCART_LAUNCH_ARGS=...   the remaining arguments, single-quoted
#
# GOLFCART_TX_SET is the point of the exercise: "not mentioned" and "mentioned
# as off" are different instructions to a caller that persists the value into a
# systemd user environment. The first must leave whatever config/vehicle.conf
# resolves to alone; the second must override it.
#
# Errors go to stderr and exit 2, so the caller's `eval` gets nothing to run.

set -euo pipefail

tx_set=0
tx_value=""
rest=()

for arg in "$@"; do
    case "$arg" in
        tx=*)
            case "${arg#tx=}" in
                on | true | yes | 1)  tx_value=true ;;
                off | false | no | 0) tx_value=false ;;
                *)
                    echo "tx_switch: '$arg' is not a boolean; use tx=on or tx=off" >&2
                    exit 2
                    ;;
            esac
            tx_set=1
            ;;
        *)
            rest+=("$arg")
            ;;
    esac
done

# %q quotes for re-input by the shell, so a launch argument containing spaces or
# quotes survives the eval intact.
printf 'GOLFCART_TX_SET=%s\n' "$tx_set"
if [ "$tx_set" = 1 ]; then
    printf 'GOLFCART_TX_ENABLED=%s\n' "$tx_value"
fi
if [ ${#rest[@]} -gt 0 ]; then
    printf 'GOLFCART_LAUNCH_ARGS=%q\n' "${rest[*]}"
else
    printf 'GOLFCART_LAUNCH_ARGS=\n'
fi
