# topics.sh — the shell entry point to the recorded topics. Source it.
#
# The topics live in config/recording/topics.yaml, sorted into classes, and
# scripts/recording/session.py is their one reader; this only calls it, so a
# shell recorder cannot drift from what a session records. Before the lists had
# one reader, two scripts carried their own inline topic arrays that drifted —
# the Velodyne under a `top/` namespace that does not exist — and recorded empty
# channels that still looked right in `ros2 bag info`.
#
#   golfcart_recording_topics ROLE [SCOPE | CLASS...]
#       print one topic per line. ROLE: master | orin (anything else: the union).
#       With no second word, the default scope's (config/recording/scopes.yaml);
#       a word naming a scope selects that scope; otherwise each word is a class
#       or a kind (first-hand, computed).
#
#   golfcart_recording_topics orin              # what the orin records by default
#   golfcart_recording_topics master ros        # the first-hand topics
#   golfcart_recording_topics master localization tf

golfcart_recording_topics() {
    local role="${1:?golfcart_recording_topics ROLE [SCOPE | CLASS...]}"
    shift
    local py
    py="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/session.py"
    if [ $# -eq 1 ] && python3 "${py}" is-scope "$1"; then
        python3 "${py}" topics --role "${role}" --scope "$1"
    elif [ $# -eq 0 ]; then
        python3 "${py}" topics --role "${role}"
    else
        python3 "${py}" topics --role "${role}" "$@"
    fi
}
