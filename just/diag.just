# Diagnostic graph: inspect it, and inject faults into it
#
# Phase 4-O sub-phase O-F. Full context in
# docs/roadmaps/4-diagnostics-observability.md.
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory and every ./scripts/... path
# breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so `default` has to come first and has to be the harmless one.
# List this module's recipes
default:
    @just --list diag

# What can be faulted: every leaf name in the RUNNING graph
list:
    ./scripts/check/diag_inject.py --list

# QoS of every graph topic, and whether a late joiner can read the structure
qos:
    ./scripts/check/diag_graph_qos.sh

# Same, against an already-running stack rather than bringing up its own
qos-attach:
    ./scripts/check/diag_graph_qos.sh --attach

# Rate and bandwidth of the graph feed through rosbridge
feed:
    ./scripts/check/rosbridge_graph_feed.sh

# Acceptance test for the mode strip: inject a fault, time the reaction
strip-test:
    ./scripts/check/mode_strip_test.sh

# `just diag inject 'aeb_emergency_stop=ERROR'` holds one leaf faulted until
# Ctrl-C. NAME is any substring of a leaf name (`just diag list` to see them)
# and LEVEL is OK, WARN, ERROR or STALE. Everything else is published healthy,
# so the graph converges instead of sitting stale.
#
# Refuses to run when something else already publishes /diagnostics, because
# both would write the same names and the aggregator takes whichever arrived
# last. Pass --allow-conflict through ARGS to override.
#
# A blank line separates this from the doc comment below, because just takes
# only the LAST contiguous comment block as the recipe's description.

# Force one diagnostic leaf to a level. ARGS: 'NAME=LEVEL' [extra flags]
inject SPEC *ARGS:
    ./scripts/check/diag_inject.py -f '{{SPEC}}' {{ARGS}}

# For watching a whole fault-and-recover cycle through the monitor page, or
# feeding an MRM timeline. Same SPEC format as `inject`.

# Fault at t+5s, recover at t+20s, exit at t+30s. ARGS: 'NAME=LEVEL'
inject-cycle SPEC:
    ./scripts/check/diag_inject.py -f '{{SPEC}}' --at 5 --clear-at 20 --stop-at 30
