#!/usr/bin/env bash
# Install Autoware's RViz theme for this user, as Autoware's own setup does.
#
# The apt install ships it under /opt/autoware/<ver>/theme/ but leaves the
# per-user half undone, so RViz started with QT_QPA_PLATFORMTHEME=qt5ct (as
# autoware.launch.xml and scripts/rviz/rviz.sh do) finds no ~/.config/qt5ct and
# draws stock Qt. This writes:
#   ~/.config/qt5ct/qss/autoware.qss  the stylesheet, /icons_path -> the shipped icons
#   ~/.config/qt5ct/qt5ct.conf        Fusion + dark palette + that stylesheet
# An existing qt5ct.conf that differs is kept as qt5ct.conf.bak.<time>.
# No sudo. Idempotent.
set -euo pipefail

AW="${AUTOWARE_ROOT:-/opt/autoware/1.5.0}"
THEME="$AW/theme"
for f in "$THEME/qt5ct.conf" "$THEME/autoware.qss" "$THEME/autoware-rviz-icons"; do
    [[ -e "$f" ]] || { echo "install_theme: $f not found (Autoware apt install?)" >&2; exit 1; }
done
command -v qt5ct >/dev/null || echo "install_theme: note: qt5ct is not installed (apt install qt5ct); RViz falls back to stock Qt" >&2

DEST="${XDG_CONFIG_HOME:-$HOME/.config}/qt5ct"
mkdir -p "$DEST/qss"
QSS="$DEST/qss/autoware.qss"

tmp=$(mktemp)
sed "s#/icons_path#$THEME/autoware-rviz-icons#g" "$THEME/autoware.qss" > "$tmp"
if ! cmp -s "$tmp" "$QSS" 2>/dev/null; then mv "$tmp" "$QSS"; echo "wrote $QSS"; else rm -f "$tmp"; echo "ok    $QSS"; fi

tmp=$(mktemp)
sed "s#stylesheets=autoware_stylesheet_path#stylesheets=$QSS#" "$THEME/qt5ct.conf" > "$tmp"
CONF="$DEST/qt5ct.conf"
if [[ -f "$CONF" ]] && ! cmp -s "$tmp" "$CONF"; then
    cp -p "$CONF" "$CONF.bak.$(date +%Y%m%d%H%M%S)"; echo "kept the old $CONF as a .bak"
fi
if ! cmp -s "$tmp" "$CONF" 2>/dev/null; then mv "$tmp" "$CONF"; echo "wrote $CONF"; else rm -f "$tmp"; echo "ok    $CONF"; fi
