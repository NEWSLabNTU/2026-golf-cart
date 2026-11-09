# The cart in the NTU twin on Isaac Sim (Phase 10, docs/roadmaps/10-isaac-twin-demo.md)
#
# Host settings (TWIN_SWB, ISAAC_ROOT, TWIN_MAP, TWIN_DOMAIN, TWIN_DISPLAY, ...) come from the
# environment or config/twin.env: scripts/twin/twin.sh lists them.
set working-directory := '..'

# List this module's recipes
default:
    @just --list twin

# A fresh clone: config/twin.env, scenario-world-bridge (cloned and built when absent), the build
setup:
    ./scripts/twin/twin.sh setup

# What this host still lacks for the demo, and how to get it
doctor:
    ./scripts/twin/twin.sh doctor

# The demo: free drive, or --scenario NAME, or --showcase (`just twin help` for every option)
run *args:
    ./scripts/twin/twin.sh run {{args}}

# The routes and scenarios
list:
    ./scripts/twin/twin.sh list

# The commands and options
help:
    ./scripts/twin/twin.sh help

# Free drive: the whole stack (Isaac, the cart's Autoware, RViz) at a route's start; Ctrl-C ends it
drive ROUTE="1" *args:
    ./scripts/twin/twin.sh drive {{ROUTE}} {{args}}

# One scenario (route1..route4, showcase_*, or an .xosc); everything ends with it, then the verdict
scenario NAME *args:
    ./scripts/twin/twin.sh scenario {{NAME}} {{args}}

# The showcase scenarios in turn (pedestrian, lead vehicle, traffic), then their verdicts
showcase *names:
    ./scripts/twin/twin.sh showcase {{names}}

# Regenerate the cart's Isaac files (rig, lidar profiles, body) after a change; --check: the rig only
generate *args:
    ./scripts/twin/twin.sh generate {{args}}

# Isaac Sim with the twin and the cart at a route's start, its window following the cart
world ROUTE="1":
    ./scripts/twin/twin.sh world {{ROUTE}}

# The cart's own Autoware on the twin's map, with the demo's RViz
autoware:
    ./scripts/twin/twin.sh autoware

# Set a route's goal and engage, then report until the cart arrives (what RViz's goal and engage do)
go ROUTE="1":
    ./scripts/twin/twin.sh go {{ROUTE}}

# What is up
status:
    ./scripts/twin/twin.sh status

# Stop what twin.sh started: the stack, or Autoware and Isaac Sim
stop:
    ./scripts/twin/twin.sh stop
