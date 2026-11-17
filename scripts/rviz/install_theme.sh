#!/usr/bin/env bash
# Install Autoware's RViz theme for this user, as Autoware's own setup does.
#
# The apt install ships it under /opt/autoware/<ver>/theme/ but leaves the
# per-user half undone, so RViz started with QT_QPA_PLATFORMTHEME=qt5ct (as
# autoware.launch.xml and scripts/rviz/rviz.sh do) finds no ~/.config/qt5ct and
# draws stock Qt. This writes, for the selected Autoware version:
#   ~/.config/qt5ct/qss/autoware-<ver>.qss  the stylesheet, /icons_path -> that
#                                           version's shipped icons
#   ~/.config/qt5ct/qt5ct.conf              Fusion + dark palette + that stylesheet
# One stylesheet per version, because each points at its own
# /opt/autoware/<ver>/theme and either version can be removed. qt5ct reads one
# conf per user, so it names the version last installed; scripts/rviz/rviz.sh
# re-runs this when it names another. A qt5ct.conf this script did not write
# is kept as qt5ct.conf.bak.<time>. No sudo. Idempotent.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../autoware_version.sh"  # GOLFCART_AUTOWARE_PREFIX
AW="${AUTOWARE_ROOT:-${GOLFCART_AUTOWARE_PREFIX}}"
THEME="$AW/theme"
for f in "$THEME/qt5ct.conf" "$THEME/autoware.qss" "$THEME/autoware-rviz-icons"; do
    [[ -e "$f" ]] || { echo "install_theme: $f not found (Autoware apt install?)" >&2; exit 1; }
done
command -v qt5ct >/dev/null || echo "install_theme: note: qt5ct is not installed (apt install qt5ct); RViz falls back to stock Qt" >&2

DEST="${XDG_CONFIG_HOME:-$HOME/.config}/qt5ct"
mkdir -p "$DEST/qss"
QSS="$DEST/qss/autoware-${GOLFCART_AUTOWARE_VERSION}.qss"

tmp=$(mktemp)
sed "s#/icons_path#$THEME/autoware-rviz-icons#g" "$THEME/autoware.qss" > "$tmp"
if ! cmp -s "$tmp" "$QSS" 2>/dev/null; then mv "$tmp" "$QSS"; echo "wrote $QSS"; else rm -f "$tmp"; echo "ok    $QSS"; fi

tmp=$(mktemp)
sed "s#stylesheets=autoware_stylesheet_path#stylesheets=$QSS#" "$THEME/qt5ct.conf" > "$tmp"
CONF="$DEST/qt5ct.conf"
if [[ -f "$CONF" ]] && ! cmp -s "$tmp" "$CONF" && ! grep -q '/qt5ct/qss/autoware' "$CONF"; then
    cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"; echo "kept the old $CONF as a .bak"
fi
if ! cmp -s "$tmp" "$CONF" 2>/dev/null; then mv "$tmp" "$CONF"; echo "wrote $CONF"; else rm -f "$tmp"; echo "ok    $CONF"; fi
