#!/usr/bin/env bash
set -e
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$script_dir"
repo_dir="$script_dir/../.."
if [[ ! -f "$repo_dir/install/setup.bash" ]]; then
    echo "Error: install/setup.bash not found. Run 'just build' first."
    exit 1
fi
source "$repo_dir/install/setup.bash"
ros2 launch sensors.launch.xml
