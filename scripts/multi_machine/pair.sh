#!/usr/bin/env bash
# pair.sh - pair this master with the orin, once. Run ON THE MASTER, after
# `./setup.sh --role master` here and `./setup.sh --role orin` there.
#
#   pair.sh            install the ssh key if needed (one password prompt), check
#                      the orin, offer to run its setup over ssh, then checklists
#                      and doctor on both hosts
#   pair.sh --check    the same checks, read-only: no key install, no offer to run
#                      anything on the orin, no prompts
#
# Reached as `just service pair` / `just service pair --check`.
#
# What it verifies, in order, each failure with the exact command that fixes it
# and the machine to run it on:
#   1. this checkout is the master            (config/host)
#   2. the orin answers key-based ssh         (BatchMode, no agent - the condition
#                                              the units and recipes run under)
#   3. the orin's checkout exists             (ORIN_WORKSPACE, config/multi_machine.conf)
#   4. the orin's config/host says orin
#   5. the orin's units are installed         (its own setup checklist)
#   6. both checkouts are on the same commit  (warning only)
#   7. setup checklist on both hosts, then scripts/doctor.sh on both
#
# Idempotent. Nothing here needs sudo on the master; the one optional remote run
# (`./setup.sh --run --role orin -y` on the orin) asks for the orin's sudo on
# its own tty, and only after a y/N prompt.
#
# Exit status: 0 when the pair is ready (warnings allowed), 1 otherwise.

set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
CONF="${REPO_DIR}/config/multi_machine.conf"
# shellcheck source=/dev/null
[ -f "${CONF}" ] && . "${CONF}"

ORIN="${ORIN_SSH:-${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}}"
KEY="${ORIN_SSH_KEY:-${GOLFCART_ORIN_SSH_KEY:-${HOME}/.ssh/golfcart_orin}}"
WORKSPACE="${ORIN_WORKSPACE:-${GOLFCART_ORIN_WORKSPACE:-~/2026-golf-cart}}"
ON_ORIN="${REPO_DIR}/scripts/multi_machine/on_orin.sh"

CHECK=0
for arg in "$@"; do
    case "${arg}" in
        --check|check) CHECK=1 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: ${arg} (expected --check)" >&2; exit 2 ;;
    esac
done

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

todo_list=()
warns=0
ok()      { printf '  %s[ OK ]%s   %s\n' "$GREEN" "$NC" "$1"; }
warn()    { printf '  %s[WARN]%s   %s\n' "$YELLOW" "$NC" "$1"; warns=$((warns + 1)); }
todo()    { printf '  %s[TODO]%s   %s\n' "$RED" "$NC" "$1"; todo_list+=("$1"); }
info()    { printf '           %s\n' "$1"; }
section() { printf '\n%s%s-- %s --%s\n' "$CYAN" "$BOLD" "$1" "$NC"; }

summary() {
    printf '\n'
    if [ "${#todo_list[@]}" -gt 0 ]; then
        printf '%sPairing not complete: %d item(s)%s\n' "$RED" "${#todo_list[@]}" "$NC"
        for t in "${todo_list[@]}"; do printf '  - %s\n' "$t"; done
        printf 'Fix them, then run `just service pair` again.\n'
        exit 1
    fi
    printf '%sPaired with %s%s' "$GREEN" "${ORIN}" "$NC"
    [ "${warns}" -gt 0 ] && printf ' (%d warning(s))' "${warns}"
    printf '\nStart both hosts with: just up\n'
    exit 0
}

# Where the orin's checkout is, in words a person types on the orin.
ws_shown="${WORKSPACE}"
origin_url="$(git -C "${REPO_DIR}" remote get-url origin 2>/dev/null || echo '<repo url>')"

printf '%sPair this master with the orin%s  (%s, checkout %s)%s\n' \
    "$BOLD" "$NC" "${ORIN}" "${ws_shown}" "$( [ "$CHECK" -eq 1 ] && echo '  [check only]')"

# ── 1. this host ─────────────────────────────────────────────────────────────
section "This host"
local_role="$(tr -d '[:space:]' < "${REPO_DIR}/config/host" 2>/dev/null || true)"
if [ "${local_role}" = "master" ]; then
    ok "config/host: master"
else
    todo "this checkout is not the master (config/host: ${local_role:-missing})"
    info "pair runs on the master. If this is the master, here:"
    info "    ./setup.sh --role master"
    summary
fi

# ── 2. ssh ───────────────────────────────────────────────────────────────────
section "ssh to the orin"
# Exactly the options the consumers use, and no agent: a key only an agent
# holds is how this deployment once worked by hand and failed under systemd.
ssh_probe() {
    [ -f "${KEY}" ] || return 1
    env -u SSH_AUTH_SOCK ssh -i "${KEY}" -o BatchMode=yes -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=accept-new "${ORIN}" true </dev/null 2>/dev/null
}

if ssh_probe; then
    ok "key-based ssh to ${ORIN} works (${KEY})"
elif [ "${CHECK}" -eq 1 ]; then
    todo "key-based ssh to ${ORIN} does not work"
    info "here, on the master (one password prompt):"
    info "    just service pair          # or only the key: just service ssh-setup"
    info "if the orin is down: ping ${ORIN##*@}"
    summary
else
    info "no working key yet; installing ${KEY} on ${ORIN}"
    if ! "${REPO_DIR}/scripts/multi_machine/setup_ssh.sh"; then
        todo "could not install the ssh key on ${ORIN} (see setup_ssh output above)"
        summary
    fi
    ok "key-based ssh to ${ORIN} works (${KEY})"
fi

# ── 3-5. the orin's checkout, role and units ─────────────────────────────────
section "The orin's checkout"

"${ON_ORIN}" true </dev/null >/dev/null 2>&1
rc=$?
if [ "${rc}" -eq 255 ]; then
    todo "ssh to ${ORIN} failed between checks; is the link up?"
    summary
elif [ "${rc}" -ne 0 ]; then
    todo "no checkout at ${ws_shown} on the orin"
    info "on the orin:"
    info "    git clone --recurse-submodules ${origin_url} ${ws_shown}"
    info "    cd ${ws_shown} && ./setup.sh --role orin"
    info "or point ORIN_WORKSPACE in config/multi_machine.conf at where it is."
    summary
fi
ok "checkout present: ${ws_shown}"

# Remote facts, gathered read-only. Each is one short BatchMode ssh, with stdin
# closed so none of them swallows what is typed at the y/N prompt below.
remote_role=""
remote_json=""
remote_has_checklist=0
probe_orin() {
    remote_role="$("${ON_ORIN}" cat config/host </dev/null 2>/dev/null | tr -d '[:space:]')"
    remote_json="$("${ON_ORIN}" python3 setup/main.py --checklist --json </dev/null 2>/dev/null)"
    if printf '%s' "${remote_json}" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        remote_has_checklist=1
    else
        remote_has_checklist=0
    fi
}

# Read one field from the orin's checklist JSON: `item_ok host-services`.
item_ok() {
    printf '%s' "${remote_json}" | python3 -c '
import json, sys
data = json.load(sys.stdin)
item = next((i for i in data["items"] if i["id"] == sys.argv[1]), None)
print("missing" if item is None else ("yes" if item["ok"] else "no"))
' "$1" 2>/dev/null
}

# Is the orin's own setup done, as far as pairing cares? Prints the reasons.
orin_ready=0
assess_orin() {
    orin_ready=1
    if [ "${remote_role}" = "orin" ]; then
        ok "orin config/host: orin"
    else
        orin_ready=0
        todo "orin config/host: ${remote_role:-missing} (must be orin)"
        if [ -n "${remote_role}" ]; then
            info "on the orin:  cd ${ws_shown} && ./setup.sh --role orin --force-role"
        else
            info "on the orin:  cd ${ws_shown} && ./setup.sh --role orin"
        fi
    fi
    if [ "${remote_has_checklist}" -eq 0 ]; then
        orin_ready=0
        todo "the orin's checkout has no 'setup/main.py --checklist': it is behind this one"
        info "on the orin:  cd ${ws_shown} && git pull && git submodule update --init --recursive"
        info "then:         ./setup.sh --role orin"
        return
    fi
    case "$(item_ok host-services)" in
        yes) ok "orin systemd units installed, lingering on" ;;
        no)
            orin_ready=0
            todo "orin systemd units not installed (or lingering off, or for another checkout)"
            info "on the orin:  cd ${ws_shown} && ./setup.sh --rerun host-services"
            info "(or the whole role: ./setup.sh --role orin)"
            ;;
        *)  : ;;   # no role on the orin yet: already reported above
    esac
}

probe_orin
section "The orin's role and units"
mark=${#todo_list[@]}
assess_orin

# Offer the orin's setup over ssh, but only for the cases it can fix without a
# decision: no role yet, or role orin with units missing. A checkout that says
# `master` needs a human to say --force-role, and an old checkout needs a pull.
if [ "${orin_ready}" -eq 0 ] && [ "${CHECK}" -eq 0 ] && [ -t 0 ] \
        && [ "${remote_has_checklist}" -eq 1 ] \
        && { [ -z "${remote_role}" ] || [ "${remote_role}" = "orin" ]; }; then
    printf '\n'
    read -r -p "Run './setup.sh --run --role orin -y' on the orin now, over ssh (asks for its sudo)? [y/N] " answer
    if [ "${answer}" = "y" ] || [ "${answer}" = "Y" ] || [ "${answer}" = "yes" ]; then
        "${ON_ORIN}" --tty ./setup.sh --run --role orin -y
        printf '\nRe-checking the orin...\n'
        todo_list=("${todo_list[@]:0:${mark}}")
        probe_orin
        assess_orin
    fi
fi

# ── 6. same commit ───────────────────────────────────────────────────────────
section "Same commit on both hosts"
local_sha="$(git -C "${REPO_DIR}" rev-parse HEAD 2>/dev/null)"
remote_sha="$("${ON_ORIN}" git rev-parse HEAD </dev/null 2>/dev/null)"
if [ -z "${remote_sha}" ]; then
    warn "could not read the orin's commit (not a git checkout?)"
elif [ "${local_sha}" = "${remote_sha}" ]; then
    ok "both at ${local_sha:0:9} ($(git -C "${REPO_DIR}" log -1 --format=%s | cut -c1-60))"
else
    warn "master at ${local_sha:0:9}, orin at ${remote_sha:0:9}"
    info "the link topics, launch arguments and unit scripts must agree; on the orin:"
    info "    cd ${ws_shown} && git pull && git submodule update --init --recursive && just build"
fi
if [ -n "$(git -C "${REPO_DIR}" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
    info "(the master's checkout has uncommitted changes, which the orin does not see)"
fi

# ── 7. checklists and doctor ─────────────────────────────────────────────────
section "Setup checklist: master"
if ! python3 "${REPO_DIR}/setup/main.py" --checklist; then
    todo "the master's setup checklist has outstanding items (above)"
fi

section "Setup checklist: orin"
if [ "${remote_has_checklist}" -eq 1 ]; then
    if ! "${ON_ORIN}" python3 setup/main.py --checklist </dev/null; then
        todo "the orin's setup checklist has outstanding items (above; run those on the orin)"
    fi
else
    info "skipped: the orin's checkout predates the checklist"
fi

section "Doctor: master"
GOLFCART_DOCTOR_CHECKLIST=0 "${REPO_DIR}/scripts/doctor.sh" || warn "doctor found problems on the master (above)"

section "Doctor: orin"
"${ON_ORIN}" env GOLFCART_DOCTOR_CHECKLIST=0 ./scripts/doctor.sh </dev/null || warn "doctor found problems on the orin (above)"

summary
