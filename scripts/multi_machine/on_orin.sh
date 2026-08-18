#!/usr/bin/env bash
# on_orin.sh - run a command in the orin's checkout, over ssh.
#
#   on_orin.sh just record up          # the same recipe this host would run
#   on_orin.sh --tty just service install orin
#   on_orin.sh systemctl --user is-active golfcart-record.service
#
# This is the whole remote-control layer, on purpose. It replaced a script that
# knew about unit names, aliases, per-unit failure policies and which units imply
# which others - all of it duplicating, on the master, decisions the orin can make
# for itself. Both machines carry the same repository, so orchestration is: log in
# and run the same recipe there. The only thing this file owns is *how* to log in.
#
# Consequences worth keeping in mind:
#   - the exit status is the remote command's, so callers decide what a failure
#     means rather than having a policy imposed here;
#   - anything runnable by hand on the orin is runnable from here, with no new
#     verb to add on this side.
#
# Environment:
#   ORIN_SSH        ssh destination        (config/multi_machine.conf)
#   ORIN_SSH_KEY    private key to offer   (config/multi_machine.conf)
#   ORIN_WORKSPACE  repo path on the orin, relative to its home
#   GOLFCART_ORIN_* the documented overrides for each of the above

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
CONF="${REPO_DIR}/config/multi_machine.conf"
# shellcheck source=/dev/null
[ -f "${CONF}" ] && . "${CONF}"

ORIN="${ORIN_SSH:-${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}}"
KEY="${ORIN_SSH_KEY:-${GOLFCART_ORIN_SSH_KEY:-${HOME}/.ssh/golfcart_orin}}"
WORKSPACE="${ORIN_WORKSPACE:-${GOLFCART_ORIN_WORKSPACE:-~/2026-golf-cart}}"

# The workspace may be written `~/path` or `/path`. A tilde has to survive to the
# far side unquoted so the REMOTE shell expands it against the REMOTE home - this
# machine's $HOME is the wrong answer and may not even exist over there. Quote
# only the part after the tilde, so a path with spaces still works.
case "${WORKSPACE}" in
    "~")    REMOTE_CD="cd ~" ;;
    "~/"*)  REMOTE_CD="cd ~/$(printf '%q' "${WORKSPACE#\~/}")" ;;
    *)      REMOTE_CD="cd $(printf '%q' "${WORKSPACE}")" ;;
esac

TTY_OPT=()
if [ "${1:-}" = "--tty" ]; then
    # For the one bootstrap case that must be able to prompt: installing the
    # units needs the orin's sudo, and that needs a terminal to ask on.
    TTY_OPT=(-t)
    shift
fi

[ $# -gt 0 ] || { echo "usage: $(basename "$0") [--tty] <command...>" >&2; exit 2; }

SSH_OPTS=(-o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)
if [ "${#TTY_OPT[@]}" -eq 0 ]; then
    # BatchMode everywhere except the bootstrap: a script started by systemd or by
    # a justfile has no terminal, so it must fail in five seconds rather than hang
    # forever on a password prompt nobody can see.
    SSH_OPTS+=(-o BatchMode=yes)
fi
# The golf cart key is at a dedicated, non-default path so setup_ssh.sh never has
# to touch the user's own id_* keys - which means ssh has to be told about it.
# On its own ssh tries only id_ed25519/id_rsa/..., and a differently-named key is
# invisible unless an agent happens to hold it. That is exactly how the previous
# key worked by hand and failed under systemd, which carries no agent.
[ -f "${KEY}" ] && SSH_OPTS+=(-i "${KEY}")

# ~/.local/bin is where `just` and `play_launch` live, and a login shell does NOT
# reliably put it on PATH: on the orin, `bash -lc just` fails with
# "just: command not found" because its ~/.profile only extends PATH for
# interactive shells. Prepending it here is what makes `on_orin.sh just ...` work.
# Quote each argument separately rather than joining with "$*". `$*` flattens the
# argument vector into one space-separated string, so the far side re-splits it
# on spaces and a single argument that CONTAINS spaces arrives as several:
#
#   on_orin.sh just launch-up "tx=on rviz:=false"
#     $*   -> just launch-up tx=on rviz:=false   # two arguments, just errors out
#     "$@" -> just launch-up tx\=on\ rviz\:\=false
#
# That is the whole reason `just launch-all "<several args>"` did nothing on the
# orin while working on the master. No caller passes a shell snippet expecting it
# to be parsed remotely, so quoting every argument costs nothing.
printf -v REMOTE_ARGV '%q ' "$@"
REMOTE_CMD='export PATH="$HOME/.local/bin:$PATH"; '"${REMOTE_CD} && ${REMOTE_ARGV% }"

# The whole command has to survive TWO parsers: ssh concatenates its arguments and
# hands the result to a shell on the far side, which re-splits them. Quoting it
# once here is what makes it arrive as a single argument to `bash -lc`. Without
# this, `bash -lc "cd /repo && pwd"` reached the orin as
#   bash -lc cd /repo && pwd
# - two separate commands, so the cd applied to nothing and everything afterwards
# ran in the home directory instead of the checkout.
exec ssh "${TTY_OPT[@]}" "${SSH_OPTS[@]}" "${ORIN}" \
    bash -lc "$(printf '%q' "${REMOTE_CMD}")"
