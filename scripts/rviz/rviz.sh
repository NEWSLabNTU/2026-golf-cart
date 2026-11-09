#!/usr/bin/env bash
# RViz the way Autoware starts it (autoware.launch.xml): the Autoware splash and
# the qt5ct theme. Every RViz recipe goes through here.
#
#   scripts/rviz/rviz.sh CONFIG.rviz [more rviz2 args]
#
# The theme itself is per user: scripts/rviz/install_theme.sh (setup step
# rviz-theme). Without it RViz still starts, in stock Qt colours.
#
# exec keeps the command line starting "rviz2 -d CONFIG", which `just down`
# matches to close the RViz `just up` opened.
set -euo pipefail
CFG="${1:?usage: rviz.sh CONFIG.rviz [args]}"; shift
AW="${AUTOWARE_ROOT:-/opt/autoware/1.5.0}"
SPLASH="$AW/share/autoware_launch/rviz/image/autoware.png"
export QT_QPA_PLATFORMTHEME=qt5ct
[[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/qt5ct/qt5ct.conf" ]] \
    || echo "rviz.sh: no ~/.config/qt5ct/qt5ct.conf; for the Autoware theme run scripts/rviz/install_theme.sh" >&2
if [[ -f "$SPLASH" ]]; then
    exec rviz2 -d "$CFG" -s "$SPLASH" "$@"
fi
exec rviz2 -d "$CFG" "$@"
