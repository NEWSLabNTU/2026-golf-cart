#!/usr/bin/env bash
# Get a version value from versions.yaml
#
# Usage:
#   get-version.sh <key> [default]
#
# Examples:
#   get-version.sh golfcart.version          # Returns "1.0.0-dev"
#   get-version.sh nvidia_amd64.cuda         # Returns "12.3"
#   get-version.sh autoware.version          # Returns "1.5.0"
#   get-version.sh missing.key "default"     # Returns "default"
#
# This used to prefer `yq` and fall back to Python. It did not work: two
# unrelated programs are installed as `yq`, and the invocation suited neither
# of the ones you are likely to have. mikefarah's Go yq needs an explicit
# `eval`/`e` subcommand before 4.18 and rejects `-r`:
#
#   Error: unknown command "versions.yaml" for "yq"
#
# while kislyuk's Python yq wants jq syntax instead. The stderr was discarded
# and the empty result fell through, so every lookup exited 1 with no output.
# PyYAML is on every machine this repo runs on, so there is one path now.

set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
VERSIONS_FILE="${SCRIPT_DIR}/../../versions.yaml"

KEY="${1:-}"
DEFAULT="${2:-}"

if [[ -z "$KEY" ]]; then
    echo "Usage: get-version.sh <key> [default]" >&2
    echo "Example: get-version.sh autoware.version" >&2
    exit 1
fi

if [[ ! -f "$VERSIONS_FILE" ]]; then
    echo "Error: versions.yaml not found at $VERSIONS_FILE" >&2
    exit 1
fi

VALUE="$(KEY="$KEY" DEFAULT="$DEFAULT" VERSIONS_FILE="$VERSIONS_FILE" python3 - <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    sys.exit("get-version.sh needs PyYAML: sudo apt install python3-yaml")

with open(os.environ["VERSIONS_FILE"]) as handle:
    data = yaml.safe_load(handle) or {}

value = data
for key in os.environ["KEY"].split("."):
    if not isinstance(value, dict) or key not in value:
        value = None
        break
    value = value[key]

if value is None or isinstance(value, (dict, list)):
    default = os.environ["DEFAULT"]
    if not default:
        sys.exit(1)
    print(default)
else:
    print(value)
PY
)" || {
    echo "Error: key '$KEY' not found in versions.yaml" >&2
    exit 1
}

echo "$VALUE"
