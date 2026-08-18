# Recording lifecycle, independent of the launch
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

# Start recording on both hosts, each to its own local disk.
start:
    #!/usr/bin/env bash
    set -o pipefail
    # Works whether or not the launch service is running: the recorder is its own
    # unit and shares no process tree with play_launch.
    RC=0
    # This host first: if the orin is unreachable we still want this bag. Unlike
    # the launch, a missing orin IS a failure here - half a recording is a result
    # you need to know about before you drive.
    just record up || RC=1
    ./scripts/multi_machine/on_orin.sh just record up || RC=1
    exit $RC

# Stop recording on both hosts and let each finalize its bag.
stop:
    #!/usr/bin/env bash
    set -o pipefail
    RC=0
    # Stop both even if the first fails - a half-stopped pair is worse than either.
    just record down || RC=1
    ./scripts/multi_machine/on_orin.sh just record down || RC=1
    exit $RC

# Is either host recording?
status:
    #!/usr/bin/env bash
    printf '%s: record %s\n' "$(hostname)" "$(systemctl --user is-active golfcart-record.service)"
    ./scripts/multi_machine/on_orin.sh systemctl --user is-active golfcart-record.service \
        | sed 's/^/orin: record /' || echo "orin: unreachable" >&2

# Start this host's recorder.
up:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user restart golfcart-record.service
    RC=$?
    echo "$(hostname): record $(systemctl --user is-active golfcart-record.service)"
    exit $RC

# Stop this host's recorder and let it finalize its bag.
down:
    #!/usr/bin/env bash
    set -uo pipefail
    systemctl --user stop golfcart-record.service
    RC=$?
    echo "$(hostname): record $(systemctl --user is-active golfcart-record.service)"
    exit $RC
