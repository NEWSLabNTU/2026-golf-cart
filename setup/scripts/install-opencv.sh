#!/usr/bin/env bash
# Put OpenCV back on one version: Ubuntu's 4.5.4, headers and runtime together.
#
# JetPack 6.2 leaves two OpenCVs installed. NVIDIA's repo ships
# libopencv/libopencv-dev at 4.8.0; Ubuntu ships the libopencv-*4.5d runtime at
# 4.5.4. Nothing on the system links 4.8.0 -- cv_bridge, Autoware, Isaac and
# python3-opencv all use 4.5.4 -- but libopencv-dev owns /usr/include/opencv4
# and the /usr/lib/libopencv_*.so symlinks, so every local build compiles
# against 4.8.0 headers and links a 4.5.4 runtime. Silent ABI mismatch.
#
# It also costs the contrib modules. NVIDIA's build carries no aruco, which is
# why find_package(OpenCV REQUIRED COMPONENTS aruco) fails on a stock box and
# why golfcart_aruco_detector and golfcart_aruco_localizer cannot be built
# there.
#
# Safe to re-run: it detects a system that is already consistent and does
# nothing. It also REFUSES to run if anything is actually linked against 4.8.0,
# rather than purging the library out from under it.
#
# Usage:
#   install-opencv.sh            fix it
#   install-opencv.sh --check    report only, change nothing

set -eo pipefail

GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m'

CHECK_ONLY=0
[[ "${1:-}" == "--check" ]] && CHECK_ONLY=1

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
files_dir="${script_dir}/../files"

PREF_SRC="${files_dir}/99-opencv-ubuntu.pref"
PREF_DST=/etc/apt/preferences.d/99-opencv-ubuntu

# The NVIDIA-only packages. libopencv-dev is NOT here: it is replaced in place
# by Ubuntu's, because ~40 ros-humble-* and autoware-* packages declare
# `Depends: libopencv-dev` and purging it would take them with it.
NVIDIA_PKGS=(libopencv libopencv-python libopencv-samples opencv-licenses opencv-samples-data)

installed_version() {  # installed_version <pkg>
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

is_installed() {  # is_installed <pkg>
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}

# ── report what is there ────────────────────────────────────────────────────
dev_version=$(installed_version libopencv-dev)
contrib_version=$(installed_version libopencv-contrib-dev)

printf "${YELLOW}→${NC} Current state\n"
printf "    libopencv-dev          %s\n" "${dev_version:-(not installed)}"
printf "    libopencv-contrib-dev  %s\n" "${contrib_version:-(not installed)}"
runtime=$(ls /usr/lib/aarch64-linux-gnu/libopencv_core.so.* 2>/dev/null | head -1)
printf "    runtime                %s\n" "${runtime:-(none found)}"

nvidia_present=0
for pkg in libopencv-dev "${NVIDIA_PKGS[@]}"; do
    version=$(installed_version "$pkg")
    [[ $version == 4.8.0* ]] && nvidia_present=1
done

if [[ $nvidia_present -eq 0 && $dev_version == 4.5.4* && -n $contrib_version ]]; then
    printf "${GREEN}✓${NC} OpenCV is already consistent at 4.5.4 with contrib\n"
    # Still make sure the pin is in place, or the next apt upgrade undoes it.
    if [[ $CHECK_ONLY -eq 0 && ! -f $PREF_DST ]]; then
        printf "${YELLOW}→${NC} Installing the apt pin so it stays that way\n"
        sudo install -m 644 "$PREF_SRC" "$PREF_DST"
    fi
    exit 0
fi

if [[ $nvidia_present -eq 0 && -z $dev_version ]]; then
    printf "${YELLOW}⊘${NC} No libopencv-dev at all, and nothing from NVIDIA to clean up.\n"
    printf "    Install Ubuntu's if you need to build against OpenCV:\n"
    printf "        sudo apt-get install libopencv-dev libopencv-contrib-dev\n"
    exit 0
fi

# ── the safety gate ─────────────────────────────────────────────────────────
#
# On this repo's hardware nothing links 4.8.0, which is what makes the purge
# safe. That is a fact about a machine, not a law, so check it here rather than
# assume it: if something IS linked, purging the library breaks it at the next
# launch with an unrelated-looking loader error.
printf "${YELLOW}→${NC} Checking whether anything links OpenCV 4.8.0...\n"
linked=0
for dir in /opt/ros/humble/lib /opt/autoware/*/lib /usr/local/zed/lib \
           /usr/lib/aarch64-linux-gnu /opt/nvidia/deepstream/*/lib; do
    [[ -d $dir ]] || continue
    count=$(find "$dir" -maxdepth 2 -name '*.so*' -type f 2>/dev/null \
            | xargs -r -n20 readelf -d 2>/dev/null \
            | grep -c 'libopencv_core\.so\.408' || true)
    [[ ${count:-0} -gt 0 ]] && { printf "${RED}✗${NC} %s: %s object(s)\n" "$dir" "$count"; linked=$((linked + count)); }
done

if [[ $linked -gt 0 ]]; then
    printf "${RED}✗${NC} %s object(s) link libopencv_core.so.408.\n" "$linked"
    printf "    Removing 4.8.0 would break them. Rebuild or repackage them\n"
    printf "    against 4.5.4 first; this script will not purge underneath a\n"
    printf "    library that is in use.\n"
    exit 1
fi
printf "${GREEN}✓${NC} Nothing links 4.8.0; it only owns the include path\n"

if [[ $CHECK_ONLY -eq 1 ]]; then
    printf "${YELLOW}→${NC} --check: would install the pin, downgrade to 4.5.4 with contrib,\n"
    printf "    and purge %s\n" "${NVIDIA_PKGS[*]}"
    exit 0
fi

# ── fix it ──────────────────────────────────────────────────────────────────
#
# Pin first. It is what makes the downgrade legal: apt permits one only at a
# priority above 1000, and without it this needs --allow-downgrades and comes
# straight back on the next upgrade.
printf "${YELLOW}→${NC} Installing apt pin at %s\n" "$PREF_DST"
sudo install -m 644 "$PREF_SRC" "$PREF_DST"

printf "${YELLOW}→${NC} Installing Ubuntu's OpenCV 4.5.4 development packages...\n"
sudo apt-get update -qq
# libopencv-dev is replaced in place here, so the ros-humble-* and autoware-*
# packages that depend on it are never left unsatisfied.
sudo apt-get install -y libopencv-dev libopencv-contrib-dev

purge_list=()
for pkg in "${NVIDIA_PKGS[@]}"; do
    is_installed "$pkg" && purge_list+=("$pkg")
done
if [[ ${#purge_list[@]} -gt 0 ]]; then
    printf "${YELLOW}→${NC} Purging the leftover 4.8.0 packages: %s\n" "${purge_list[*]}"
    sudo apt-get purge -y "${purge_list[@]}"
fi

sudo ldconfig

# ── verify ──────────────────────────────────────────────────────────────────
printf "${YELLOW}→${NC} Verifying...\n"
failed=0

dev_version=$(installed_version libopencv-dev)
if [[ $dev_version == 4.5.4* ]]; then
    printf "${GREEN}✓${NC} libopencv-dev %s\n" "$dev_version"
else
    printf "${RED}✗${NC} libopencv-dev is %s, expected 4.5.4\n" "${dev_version:-missing}"
    failed=1
fi

if [[ -f /usr/include/opencv4/opencv2/aruco.hpp ]]; then
    printf "${GREEN}✓${NC} contrib headers present (aruco.hpp)\n"
else
    printf "${RED}✗${NC} /usr/include/opencv4/opencv2/aruco.hpp missing\n"
    failed=1
fi

if command -v pkg-config &>/dev/null; then
    pc_version=$(pkg-config --modversion opencv4 2>/dev/null || true)
    if [[ $pc_version == 4.5.4* ]]; then
        printf "${GREEN}✓${NC} pkg-config opencv4 %s\n" "$pc_version"
    else
        printf "${RED}✗${NC} pkg-config reports %s\n" "${pc_version:-nothing}"
        failed=1
    fi
fi

if [[ $failed -ne 0 ]]; then
    printf "${RED}✗${NC} OpenCV is still not consistent\n"
    exit 1
fi

printf "${GREEN}✓${NC} OpenCV consistent at 4.5.4, headers and runtime together\n"
printf "${YELLOW}Note:${NC} anything already compiled against the 4.8.0 headers must be\n"
printf "      rebuilt. From the repository root: just clean && just build\n"
