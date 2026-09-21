# GNSS / RTK: check the setup, then test the receiver against the caster.
#
#   just gnss check      # everything a run needs, before going to the field
#   just gnss test       # bring the receiver up, measure 60s, say what is wrong
#
# `check` talks to nothing -- it verifies packages, config, the device node and
# that the caster's port answers. `test` runs the receiver for real. Run check
# first; it names a missing piece in one line where test would take a minute to
# reach the same conclusion.
#
# The test starts and stops its own standalone gnss.launch.xml, which is the
# lightest path that still exercises driver, NTRIP client and remaps. To test
# the receiver as the full stack sees it, start the stack and use `attach`.
#
# Reading the result: exit 2 ("no sky") is the expected INDOOR outcome and is
# not a fault. The receiver needs satellites before a network VRS will send
# corrections, because it places its virtual base from the position in the GGA
# the client uplinks. Full reasoning, and the indoor run this was written
# against, in docs/handover/2026-09-21-f9p-ntrip-bringup.md.
#
# The exit code is deliberately not swallowed, so `just` prints its own
# "Recipe `test` failed with exit code 2" under the verdict. Read the verdict,
# not that line: the codes separate a broken chain (1) from an unusable sky
# (2), and which of those counts as a failure depends on whether you are
# indoors. Nothing here can decide that for you.
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory and every ./scripts/... path
# breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so this is `default` on purpose: `just gnss` lists, it does not open a serial
# port.
# List this module's recipes
default:
    @just --list gnss

# Packages, message types, sensor kit config, the account file, the device and
# the caster's port. Nothing here touches the receiver, so it is safe to run
# while the stack is up.
# Verify everything `just launch use_ntrip:=true` needs, without running it
check:
    ./scripts/testing/ntrip/check_ntrip_setup.sh

# Counts messages over a fixed window rather than sampling `ros2 topic hz`:
# the RTCM stream is bursty, so a short hz window misreads it, and hz cannot
# tell a silent caster from an absent topic.
#
#   just gnss test              # 60s, with NTRIP
#   just gnss test 120          # longer window, for a marginal link
#   just gnss test 60 --no-ntrip   # driver only, isolate receiver from caster
# Bring the receiver up, measure it, and diagnose the first broken link
test SECONDS="60" *ARGS="":
    ./scripts/testing/gnss/gnss_test.py --seconds {{SECONDS}} {{ARGS}}

# For a receiver already running under `just launch` or the systemd unit. It
# autodetects /sensing/gnss there, where the standalone launch is /gnss.
# Measure a GNSS stack that is already running, and leave it running
attach SECONDS="60" *ARGS="":
    ./scripts/testing/gnss/gnss_test.py --attach --seconds {{SECONDS}} {{ARGS}}

# The driver orphans ublox_gps_node on a launch kill, which keeps /dev/ttyACM0
# and makes the next run fail to open the port. `test` cleans up after itself;
# this is for a run that was interrupted some other way.
# Kill orphaned GNSS nodes and free the serial port
kill:
    #!/usr/bin/env bash
    pkill -f gnss.launch.xml 2>/dev/null || true
    sleep 1
    pkill -9 -f ublox_gps_node 2>/dev/null || true
    pkill -9 -f ntrip_ros.py 2>/dev/null || true
    pkill -9 -f gnss_poser 2>/dev/null || true
    sleep 2
    if fuser /dev/ttyACM0 2>/dev/null; then
        echo "port STILL held by the pid above"
    else
        echo "stopped, /dev/ttyACM0 free"
    fi
