#!/usr/bin/env bash
# setup_ssh.sh - one-time: give this host key-based ssh access to the orin.
#
# Every other script in scripts/multi_machine/ runs ssh with BatchMode=yes, which
# never prompts by design: a script started by systemd or by a justfile trap has
# no terminal to type a password into, so it must fail fast instead of hanging
# forever on a hidden prompt. That makes a key on the far side mandatory, and this
# is the single place where the one password is typed - by a human, once.
#
# No credential handling: ssh-copy-id owns the password prompt and the password
# never passes through this script. Nothing is read, echoed, cached or stored.
#
# Usage:
#   setup_ssh.sh                 # use ORIN_SSH from config/multi_machine.conf
#   setup_ssh.sh user@host       # override the destination for this run

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="${REPO_ROOT}/config/multi_machine.conf"
# shellcheck source=/dev/null
[ -f "${CONF}" ] && . "${CONF}"

# Fallback chain, in order: explicit argument, config file, documented env
# override, built-in default. The last two are repeated here so the script still
# works from a checkout where config/multi_machine.conf is missing.
DEST="${1:-${ORIN_SSH:-${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}}}"

# A dedicated key with a FIXED path, never ~/.ssh/id_*. Two reasons:
#   - the user's default keys are theirs; this script must never generate over,
#     or quietly adopt, a key they use for GitHub or any other host.
#   - the consumers pass this path with `ssh -i`, so a non-default name works.
#     Without -i, ssh tries only id_ed25519/id_rsa/... and a differently-named
#     key is invisible unless an agent holds it - which is precisely how the old
#     ~/.ssh/golfcart_slave key passed by hand and failed under systemd.
KEY="${ORIN_SSH_KEY:-${GOLFCART_ORIN_SSH_KEY:-${HOME}/.ssh/golfcart_orin}}"

log() { printf 'setup_ssh: %s\n' "$1" >&2; }

if ! command -v ssh-copy-id >/dev/null 2>&1; then
    log "ERROR: ssh-copy-id not found (apt install openssh-client)"
    exit 1
fi

if [ -f "${KEY}" ]; then
    log "reusing the existing golf cart key ${KEY}"
else
    log "generating ${KEY}"
    mkdir -p "$(dirname "${KEY}")"
    chmod 700 "$(dirname "${KEY}")"
    # -N '': an empty passphrase is required, not lazy. The consumers run under
    # systemd, where there is no agent to unlock a protected key and no terminal
    # to unlock it from.
    ssh-keygen -t ed25519 -N '' -C "$(id -un)@$(hostname -s) golfcart-orin" -f "${KEY}"
fi

log "installing ${KEY}.pub on ${DEST}"
log "you will be asked for ${DEST}'s password once"
if ! ssh-copy-id -i "${KEY}.pub" -o StrictHostKeyChecking=accept-new "${DEST}"; then
    log "ERROR: ssh-copy-id failed - key NOT installed on ${DEST}"
    log "       check the host is up and the account name is right:"
    log "         ping ${DEST##*@}"
    exit 1
fi

# Verify with the exact option set the real consumers use. A successful
# ssh-copy-id is not proof: a wrong-permission ~/.ssh on the far side, or an
# sshd with PubkeyAuthentication off, still leaves BatchMode logins failing while
# an interactive password login keeps working.
#
# Verified WITHOUT an agent (env -u SSH_AUTH_SOCK) on purpose: with one running,
# a stale key it happens to hold can make this pass while every systemd unit
# still fails. Agentless is the condition the real consumers run under.
log "verifying key-based login (BatchMode, no agent, no prompt possible)..."
if REMOTE_HOST=$(env -u SSH_AUTH_SOCK ssh -i "${KEY}" -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new "${DEST}" hostname 2>/dev/null); then
    log "OK: key-based ssh to ${DEST} works (remote hostname: ${REMOTE_HOST})"
    log "    just launch-all, record control and bag-fetch-orin can now reach it."
    exit 0
fi

log "FAILED: ${DEST} still refuses key-based login."
log "        Re-run with verbose ssh to see why:"
log "          ssh -vvv -o BatchMode=yes ${DEST} true"
log "        Common causes: ~/.ssh perms on the remote (700, 600 on"
log "        authorized_keys), or PubkeyAuthentication disabled in its sshd_config."
exit 1
