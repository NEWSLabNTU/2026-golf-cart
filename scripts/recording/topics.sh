# topics.sh — the one reader of config/recording/*_topics.txt. Source it.
#
# Every recorder in the repo takes its topics from those lists through this
# function: the systemd unit (record_unit_exec.sh), the terminal recorder
# (record_foreground.sh, `just bag record`) and the link simulation. Before
# this, two scripts carried their own inline topic arrays that drifted from the
# lists — the Velodyne under a `top/` namespace that does not exist, its packets
# at /sensing/lidar/velodyne_packets instead of /sensing/lidar/vlp32/... — and
# recorded empty channels that still looked right in `ros2 bag info`.
#
#   golfcart_recording_topics FILE...   print one topic per line
#
# `#` starts a comment, whole-line or trailing; surrounding whitespace and blank
# lines are dropped. A topic listed in more than one FILE is printed once.

golfcart_recording_topics() {
    local file line
    # Checked up front: inside the loop below a failure would be the exit status
    # of the left side of a pipe, and the function would return awk's 0.
    for file in "$@"; do
        if [ ! -f "${file}" ]; then
            echo "golfcart_recording_topics: topic list not found: ${file}" >&2
            return 1
        fi
    done
    for file in "$@"; do
        while IFS= read -r line || [ -n "${line}" ]; do
            line="${line%%#*}"
            line="${line#"${line%%[![:space:]]*}"}"
            line="${line%"${line##*[![:space:]]}"}"
            [ -n "${line}" ] && echo "${line}"
        done < "${file}"
    done | awk '!seen[$0]++'
}
