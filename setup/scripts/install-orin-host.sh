#!/usr/bin/env bash
# install-orin-host.sh - one-time provisioning of the orin (slave) host.
#
# Run ON THE ORIN, as the normal user. Installs the two systemd user units that
# the master starts over ssh, and enables lingering so they can run without an
# active login session.
#
# Requires sudo only for `loginctl enable-linger`.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
UNIT_SRC="${REPO_DIR}/setup/files/systemd"
UNIT_DST="${HOME}/.config/systemd/user"

UNITS=(golfcart-orin.service golfcart-orin-watchdog.service)

if [[ "${REPO_DIR}" != "${HOME}/2026-golf-cart" ]]; then
    echo "WARNING: repository is at ${REPO_DIR}, but the units reference" >&2
    echo "         %h/2026-golf-cart. Edit ExecStart in ${UNIT_DST} after install," >&2
    echo "         or set GOLFCART_WORKSPACE in the unit environment." >&2
fi

echo "Installing systemd user units to ${UNIT_DST}..."
mkdir -p "${UNIT_DST}"
for unit in "${UNITS[@]}"; do
    install -m 644 "${UNIT_SRC}/${unit}" "${UNIT_DST}/${unit}"
    echo "  ${unit}"
done

echo "Reloading the user systemd manager..."
systemctl --user daemon-reload

# Without lingering, the user manager exits when the last session closes, taking
# the units with it - and the master drives them over a non-interactive ssh, which
# is exactly such a session.
if loginctl show-user "${USER}" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    echo "Lingering already enabled for ${USER}."
else
    echo "Enabling lingering for ${USER} (needs sudo)..."
    sudo loginctl enable-linger "${USER}"
fi

echo
echo "Done. The units are installed but NOT enabled - the master starts them on"
echo "demand. Check with:"
echo "  systemctl --user status golfcart-orin.service"
