# Recording sessions: ROS bags and raw packets (CAN, Ethernet), both hosts
#
#   just record start [SCOPE] [NAME]   both hosts, one session id; master first
#   just record status                 both hosts: session, files, growth
#   just record stop                   both hosts; prints the collect command
#   just record collect [ID] [merge=on] the orin's half onto this host
#   just record list                   sessions here
#   just record nuke [host=both|master|orin]  DELETE every session, after typing `nuke`
#
# Files land in recordings/<id>/<role>/ on each host (gitignored). Scopes are
# config/recording/scopes.yaml, the topics config/recording/topics.yaml (classes);
# docs/recording.md is the user guide.
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
    @just --list record

# Start a session on both hosts. SCOPE: drive (default)|autonomy|all|raw|can|ros|localize; NAME: [A-Za-z0-9-]+
[positional-arguments]
start *ARGS:
    #!/usr/bin/env bash
    set -uo pipefail
    ON_ORIN="${GOLFCART_ON_ORIN:-./scripts/multi_machine/on_orin.sh}"
    read -r SCOPE NAME < <(just record _parse "$@") || exit 2
    # The id is made once, here, and handed to both hosts: the two halves of a
    # session are paired by name, not by nearby timestamps.
    SID=$(python3 scripts/recording/session.py new-id "${NAME}") || exit 2
    echo "session ${SID}  scope ${SCOPE}"
    # Works whether or not the stack is running: the recorder is its own unit.
    RC=0
    # This host first: if the orin is unreachable we still want this half. Unlike
    # the launch, a missing orin IS a failure here - half a recording is a result
    # you need to know about before you drive.
    just record _up-local "${SID}" "${SCOPE}" || RC=1
    "${ON_ORIN}" just record _up-local "${SID}" "${SCOPE}" || { RC=1; echo "orin: FAILED to start (unreachable, or its checkout lacks sessions: git pull there)" >&2; }
    echo
    echo "status: just record status    stop: just record stop"
    exit $RC

# Stop both hosts' sessions (each finalizes its own files), then print the collect command.
stop *OPTS="":
    #!/usr/bin/env bash
    set -uo pipefail
    ON_ORIN="${GOLFCART_ON_ORIN:-./scripts/multi_machine/on_orin.sh}"
    MERGE=off
    for opt in {{OPTS}}; do
        case "$opt" in
            merge=on|merge=true)   MERGE=on ;;
            merge=off|merge=false) MERGE=off ;;
            *) echo "Usage: just record stop [merge=on|off]" >&2; exit 2 ;;
        esac
    done
    SID=$(python3 scripts/recording/session.py newest-id 2>/dev/null || true)
    [ -f .golfcart-record.args ] && SID=$(sed -n 's/^id=//p' .golfcart-record.args)
    RC=0
    # Stop both even if the first fails - a half-stopped pair is worse than either.
    just record _down-local || RC=1
    "${ON_ORIN}" just record _down-local || RC=1
    [ -n "${SID}" ] || exit $RC
    echo
    if [ "$RC" -eq 0 ] && [ "$MERGE" = on ]; then
        # Both runners have exited, so every file is finalized.
        just record collect "${SID}" merge=on || RC=1
    else
        echo "next: just record collect ${SID}            (the orin's half onto this host)"
        [ -d "recordings/${SID}/master/bag" ] && \
        echo "      just record collect ${SID} merge=on   (also merge the two bags)"
    fi
    exit $RC

# Is either host recording? Session id, each file and how fast it grows.
status:
    #!/usr/bin/env bash
    ON_ORIN="${GOLFCART_ON_ORIN:-./scripts/multi_machine/on_orin.sh}"
    just record _status-local
    "${ON_ORIN}" just record _status-local 2>&1 || echo "orin: unreachable, or its checkout lacks sessions" >&2

# Sessions on this host: scope, each half's state, collected?, merged?, size.
list:
    @python3 scripts/recording/session.py list

# Copy the orin's half of a session here (default newest; resumable). OPTS: merge=on
collect ID="" *OPTS="":
    #!/usr/bin/env bash
    case "{{ID}}" in
        master_*)
            # A bag from before sessions (master_<ts> in $GOLFCART_BAG_DIR).
            printf '\033[1;33mDEPRECATED:\033[0m %s is a pre-session bag; using the old pairing collector.\n\n' "{{ID}}" >&2
            exec ./scripts/multi_machine/record_collect.sh "{{ID}}" ;;
    esac
    exec ./scripts/recording/collect.sh "{{ID}}" {{OPTS}}

# Show the topic classes, each scope's classes and topic counts per host, and this host's plan
scopes:
    #!/usr/bin/env bash
    python3 scripts/recording/session.py scopes -v || exit 1
    echo; echo "default scope on $(hostname), as it would start now:"
    python3 scripts/recording/session.py plan

# Asks every time: lists both hosts, then wants the word `nuke` typed at the
# terminal. Only recordings/ is touched; old bags in $GOLFCART_BAG_DIR and
# rosbags/can/ are not. Refuses while either host records, or when the orin is
# unreachable (unless host=master). No bypass flag, on purpose.
# DELETE all sessions in recordings/ on both hosts (asks first). OPTS: host=both|master|orin
nuke *OPTS="":
    #!/usr/bin/env bash
    set -uo pipefail
    ON_ORIN="${GOLFCART_ON_ORIN:-./scripts/multi_machine/on_orin.sh}"
    HOST=both
    for opt in {{OPTS}}; do
        case "$opt" in
            host=both|host=master|host=orin) HOST="${opt#host=}" ;;
            *) echo "Usage: just record nuke [host=both|master|orin]" >&2; exit 2 ;;
        esac
    done
    # The question is the safety; without a terminal there is nobody to ask.
    if [ ! -t 0 ] || ! { : < /dev/tty; } 2>/dev/null; then
        echo "nuke: not a terminal; refusing (it always asks). Nothing deleted." >&2
        exit 1
    fi
    WANT=()
    [ "$HOST" = orin ] || WANT+=(master)
    [ "$HOST" = master ] || WANT+=(orin)
    run_on() { if [ "$1" = master ]; then shift; "$@"; else shift; "${ON_ORIN}" "$@"; fi; }
    REFUSE=0
    for h in "${WANT[@]}"; do
        echo "== $h"
        OUT=$(run_on "$h" just record _nuke-local list 2>&1); RC=$?
        OUT=$(grep -v "^error: Recipe .*_nuke-local" <<< "$OUT")
        case "$RC" in
            0) printf '%s\n' "$OUT" ;;
            3) printf '%s\n' "$OUT"; REFUSE=1 ;;
            *) echo "$h: UNREACHABLE or unusable (exit $RC): ${OUT##*$'\n'}" >&2
               echo "     to delete one host only: just record nuke host=master|orin" >&2
               REFUSE=1 ;;
        esac
    done
    echo "Not touched: bags from before sessions (\$GOLFCART_BAG_DIR, ~/rosbags) and rosbags/can/."
    if [ "$REFUSE" -ne 0 ]; then
        echo "nuke: refused (see above). Nothing deleted." >&2
        exit 1
    fi
    printf 'Delete ALL of the above on %s? This cannot be undone. Type nuke to confirm: ' "${WANT[*]}" > /dev/tty
    read -r ANSWER < /dev/tty || ANSWER=""
    if [ "$ANSWER" != nuke ]; then
        echo "Aborted; nothing deleted."
        exit 1
    fi
    RC=0
    # Orin first: if the link drops mid-way the master half is still here.
    for h in $(printf '%s\n' "${WANT[@]}" | sort -r); do
        run_on "$h" just record _nuke-local delete || { echo "$h: delete FAILED" >&2; RC=1; }
    done
    exit $RC

# Start a session on THIS host only. SCOPE and NAME as for start.
[positional-arguments]
up *ARGS:
    #!/usr/bin/env bash
    read -r SCOPE NAME < <(just record _parse "$@") || exit 2
    SID=$(python3 scripts/recording/session.py new-id "${NAME}") || exit 2
    exec just record _up-local "${SID}" "${SCOPE}"

# Stop THIS host's session and let it finalize its files.
down:
    @just record _down-local

# "SCOPE NAME" from [SCOPE] [NAME]: a first word that is not a scope is the name.
[private]
[positional-arguments]
_parse *ARGS:
    #!/usr/bin/env bash
    S="${1:-}"; N="${2:-}"
    if [ -n "$S" ] && ! python3 scripts/recording/session.py is-scope "$S"; then
        if [ -n "$N" ]; then
            echo "unknown scope '$S'; scopes:" >&2
            python3 scripts/recording/session.py scopes >&2; exit 2
        fi
        N="$S"; S=""
    fi
    [ -n "$S" ] || S=$(python3 scripts/recording/session.py scopes | awk '/\(default\)$/ {print $1}')
    if [ -n "$N" ] && ! [[ "$N" =~ ^[A-Za-z0-9-]+$ ]]; then
        echo "session name '$N': letters, digits and '-' only" >&2; exit 2
    fi
    echo "$S $N"

# This host's unit with a given id and scope; start runs it here and on the orin.
# They reach the unit through .golfcart-record.args (gitignored), rewritten on
# every start, the same pattern as .golfcart-launch.args.
[private]
_up-local ID SCOPE:
    #!/usr/bin/env bash
    set -uo pipefail
    U="${GOLFCART_RECORD_UNIT:-golfcart-record.service}"
    if systemctl --user is-active --quiet "$U"; then
        echo "$(hostname): already recording $(sed -n 's/^id=//p' .golfcart-record.args 2>/dev/null); just record stop first" >&2
        exit 1
    fi
    # Refuses (exit 3) for a scope marked disk: refuse below min_free_gb.
    python3 scripts/recording/session.py preflight --scope "{{SCOPE}}" || exit 1
    python3 scripts/recording/session.py write-args --id "{{ID}}" --scope "{{SCOPE}}" || exit 2
    if ! systemctl --user restart "$U"; then
        echo "$U failed to start on $(hostname). Not installed yet?  just service install <role>" >&2
        exit 1
    fi
    # The runner checks every recorder for an early exit (permission, missing
    # interface) at 2 s; show its verdict, not just "active".
    for _ in $(seq 1 30); do
        sleep 0.5
        ST=$(sed -n 's/^state: //p' "recordings/{{ID}}"/*/session.yaml 2>/dev/null | head -1)
        case "$ST" in recording|failed|stopped|ended) break ;; esac
        systemctl --user is-active --quiet "$U" || break
    done
    python3 scripts/recording/session.py show "{{ID}}" || true
    if ! systemctl --user is-active --quiet "$U"; then
        echo "$(hostname): recorder exited; journalctl --user -u $U -n 30" >&2
        exit 1
    fi

# This host's unit only; stop runs it here and on the orin.
[private]
_down-local:
    #!/usr/bin/env bash
    set -uo pipefail
    U="${GOLFCART_RECORD_UNIT:-golfcart-record.service}"
    if ! systemctl --user is-active --quiet "$U"; then
        echo "$(hostname): not recording"
        exit 0
    fi
    SID=$(sed -n 's/^id=//p' .golfcart-record.args 2>/dev/null)
    # Blocks until the runner exits, i.e. until every file is finalized.
    systemctl --user stop "$U"
    RC=$?
    [ -n "${SID}" ] && python3 scripts/recording/session.py show "${SID}"
    exit $RC

[private]
_status-local:
    #!/usr/bin/env bash
    printf '%s: unit %s\n' "$(hostname)" "$(systemctl --user is-active "${GOLFCART_RECORD_UNIT:-golfcart-record.service}")"
    python3 scripts/recording/session.py status

# list: sessions and sizes here, exit 3 if one is recording. delete: remove
# everything under recordings/ here (refuses the same way). nuke calls both.
[private]
_nuke-local MODE:
    #!/usr/bin/env bash
    set -uo pipefail
    REC="${GOLFCART_RECORDINGS_DIR:-$PWD/recordings}"
    U="${GOLFCART_RECORD_UNIT:-golfcart-record.service}"
    H=$(hostname)
    ACTIVE=$(python3 scripts/recording/session.py active 2>/dev/null | tr '\n' ' ')
    if systemctl --user is-active --quiet "$U" || [ -n "$ACTIVE" ]; then
        echo "$H: RECORDING NOW (${ACTIVE:-unit $U active}); just record stop first"
        exit 3
    fi
    total=$(du -sb "$REC" 2>/dev/null | cut -f1); total=${total:-0}
    case "{{MODE}}" in
        list)
            echo "$H: ${REC}"
            shopt -s nullglob
            n=0
            for d in "$REC"/*/; do
                n=$((n + 1))
                printf '  %-36s %s\n' "$(basename "$d")" "$(du -sh "$d" | cut -f1)"
            done
            [ "$n" -gt 0 ] || echo "  (no sessions)"
            echo "  total: $(numfmt --to=si "$total")B in $n session(s)" ;;
        delete)
            [ -d "$REC" ] || { echo "$H: nothing to delete"; exit 0; }
            find "$REC" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + || exit 1
            left=$(find "$REC" -mindepth 1 | wc -l)
            [ "$left" -eq 0 ] || { echo "$H: $left entries could not be removed" >&2; exit 1; }
            echo "$H: deleted every session in ${REC}, freed $(numfmt --to=si "$total")B" ;;
        *) echo "_nuke-local list|delete" >&2; exit 2 ;;
    esac
