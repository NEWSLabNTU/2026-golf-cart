# Synthetic cameras on v4l2loopback, for working without hardware attached
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory, and every `./scripts/...` path
# in the repo breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so `default` has to come first and has to be the harmless one.
# List this module's recipes
default:
    @just --list sim

# Create three v4l2loopback devices at the real camera geometry (needs sudo)
cameras-up:
    ./scripts/sim/cameras.sh up

# Start three UYVY test sources feeding those devices
cameras-feed:
    ./scripts/sim/cameras.sh feed

# Write gmslcam param files pointing at the synthetic devices
cameras-configs:
    ./scripts/sim/cameras.sh configs

# The NVJPG capacity check from docs/roadmaps/2-camera-image-pipeline.md
# sub-phase A. On the Advantech it is the real answer; anywhere else it measures
# CPU jpegenc and says so. A blank line separates this from the doc comment
# below, because just takes only the LAST contiguous comment block as the
# recipe's description in `just --list`.

# Encoder throughput, one stream against three. No devices or cameras needed.
cameras-bench SECS="10":
    SECS={{SECS}} ./scripts/sim/cameras.sh bench

# What is loaded, what exists, what is running
cameras-status:
    ./scripts/sim/cameras.sh status

# Stop the feeders and unload the module (needs sudo)
cameras-down:
    ./scripts/sim/cameras.sh down

# up + feed + configs, the usual starting sequence
cameras: cameras-up cameras-feed cameras-configs
