#!/usr/bin/env bash
# ExecStart for iox-roudi.service.
#
# A wrapper rather than an ExecStart straight at the binary, for the same reason
# launch_unit_exec.sh is one: the installer's drop-in writes a bare
# "ExecStart=<path>" with no arguments, so anything that needs flags needs a
# script. It also lets the mempool config live in config/ with everything else.
#
# RouDi is a HARD dependency of every ROS process once SharedMemory is enabled
# in the CycloneDDS profiles. With SHM on and RouDi absent, participant creation
# does not fail - it HANGS, with no message (measured: still blocked at 60s).
# That is why golfcart-launch.service and golfcart-record.service both carry
# Requires= on this unit, and why scripts/env.sh refuses to start ROS without it.
set -euo pipefail

WORKSPACE="${GOLFCART_WORKSPACE:-$(cd "$(dirname "$0")/../.." && pwd)}"

export GOLFCART_ENV_QUIET=1
# RouDi itself creates no DDS participant, so the DDS readiness gate would be
# circular here: env.sh's check requires RouDi, and RouDi would be waiting on it.
export GOLFCART_SKIP_DDS_CHECK=1
# shellcheck source=/dev/null
source "${WORKSPACE}/scripts/env.sh"

CONFIG="${WORKSPACE}/config/iceoryx/roudi.toml"
if [ ! -f "${CONFIG}" ]; then
    echo "roudi_unit_exec: no mempool config at ${CONFIG}" >&2
    exit 1
fi

ROUDI="$(command -v iox-roudi || echo /opt/ros/humble/bin/iox-roudi)"
if [ ! -x "${ROUDI}" ]; then
    echo "roudi_unit_exec: iox-roudi not found. Install it with:" >&2
    echo "                 ./setup.sh iceoryx" >&2
    exit 1
fi

# -m off disables process-alive monitoring. On by default, RouDi SIGKILLs a
# client that misses its keepalive - and this stack has nodes that legitimately
# block for minutes on first start while TensorRT compiles ONNX models to CUDA
# engines. Losing a node mid-compile to a liveness timeout would be a very
# expensive way to reclaim chunks nothing was waiting for.
exec "${ROUDI}" -c "${CONFIG}" -m off -l warning
