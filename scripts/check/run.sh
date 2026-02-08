#!/usr/bin/env bash
set -e
script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
cd "$script_dir"
repo_dir="$script_dir/../.."
source "$repo_dir/install/setup.bash"
ros2 launch sensors.launch.xml
