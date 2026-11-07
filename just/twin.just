# The cart in the NTU twin on Isaac Sim (Phase 10, docs/roadmaps/10-isaac-twin-demo.md)
#
# Host settings (TWIN_SWB, ISAAC_ROOT, TWIN_MAP, TWIN_DOMAIN, TWIN_DISPLAY, ...) come from the
# environment or config/twin.env: scripts/twin/twin.sh lists them.
set working-directory := '..'

# List this module's recipes
default:
    @just --list twin

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

# Stop Autoware, then Isaac Sim
stop:
    ./scripts/twin/twin.sh stop
