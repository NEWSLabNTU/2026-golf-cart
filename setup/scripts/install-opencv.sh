#!/usr/bin/env bash
# Make OpenCV consistent: one version for headers and runtime, with contrib.
#
# The requirement is NOT "OpenCV must be 4.5.4". It is:
#
#   1. the headers a build compiles against are the same version as the
#      library it links, and
#   2. the contrib modules are present, because golfcart_aruco_detector and
#      golfcart_aruco_localizer need find_package(OpenCV COMPONENTS aruco).
#
# Any version satisfying both is fine and this script leaves it alone. That
# matters in two directions: stock Ubuntu already satisfies it (4.5.4 headers,
# 4.5.4 runtime, contrib from libopencv-contrib-dev), and a future JetPack that
# ships a coherent OpenCV will satisfy it too, at whatever version NVIDIA
# picks. Neither should be forced down to 4.5.4.
#
# What is broken today, on JetPack 6.2 only: NVIDIA's repo ships
# libopencv/libopencv-dev at 4.8.0 while Ubuntu's libopencv-*4.5d runtime stays
# at 4.5.4. Nothing on the system links 4.8.0 -- cv_bridge, Autoware and
# python3-opencv all use 4.5.4 -- but libopencv-dev owns /usr/include/opencv4
# and the /usr/lib/*/libopencv_*.so symlinks, so every local build compiles
# against 4.8.0 headers and links a 4.5.4 runtime. A silent ABI mismatch. It
# also costs the contrib modules: NVIDIA's build carries no aruco.
#
# The remedy for that case is to put Ubuntu's 4.5.4 back on both sides. It runs
# only when the invariant above is actually violated.
#
# Safe to re-run. It REFUSES to purge a library that something still links,
# rather than pulling it out from under a running system.
#
# Usage:
#   install-opencv.sh            fix it if it is broken
#   install-opencv.sh --check    report only, change nothing
#
# Test seams: OPENCV_INCLUDE_DIR and OPENCV_LIB_DIRS override where the headers
# and libraries are looked for, so the decision logic can be exercised against
# a fake tree without a Jetson.

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

INCLUDE_DIR="${OPENCV_INCLUDE_DIR:-/usr/include/opencv4}"

# Every multiarch library directory, discovered rather than hardcoded. The
# previous version looked only in /usr/lib/aarch64-linux-gnu, and because that
# glob was piped into `head` under `set -o pipefail`, on an x86_64 host the
# whole script exited 2 at that line -- before reaching the check that would
# have said "already consistent". A Jetson-only assumption that turned into a
# failure on every other machine.
if [[ -n "${OPENCV_LIB_DIRS:-}" ]]; then
    read -r -a LIB_DIRS <<< "$OPENCV_LIB_DIRS"
else
    LIB_DIRS=()
    for d in /usr/lib/*-linux-gnu /usr/lib /usr/local/lib; do
        [[ -d $d ]] && LIB_DIRS+=("$d")
    done
fi

# The version OpenCV's own headers declare. This is what a build compiles
# against, whoever packaged them.
header_version() {
    local hdr="${INCLUDE_DIR}/opencv2/core/version.hpp"
    [[ -f $hdr ]] || return 0
    local major minor revision
    major=$(awk '/define CV_VERSION_MAJOR/ {print $3; exit}' "$hdr")
    minor=$(awk '/define CV_VERSION_MINOR/ {print $3; exit}' "$hdr")
    revision=$(awk '/define CV_VERSION_REVISION/ {print $3; exit}' "$hdr")
    [[ -n $major && -n $minor ]] || return 0
    printf '%s.%s.%s' "$major" "$minor" "${revision:-0}"
}

# The library a build actually links: follow the unversioned .so symlink that
# the -dev package owns, not whatever versioned files happen to be installed.
# Debian's Ubuntu build suffixes its soname with 'd' (libopencv_core.so.4.5d),
# so strip any trailing letters before comparing.
linked_runtime_version() {
    local dir target base
    for dir in "${LIB_DIRS[@]}"; do
        [[ -e "${dir}/libopencv_core.so" ]] || continue
        target=$(readlink -f "${dir}/libopencv_core.so" 2>/dev/null) || continue
        base=${target##*/libopencv_core.so.}
        [[ -n $base && $base != "$target" ]] || continue
        printf '%s' "${base%%[a-zA-Z]*}"
        return 0
    done
    return 0
}

# Every runtime version present, for the report and for spotting two at once.
runtime_versions() {
    local dir f base
    for dir in "${LIB_DIRS[@]}"; do
        for f in "${dir}"/libopencv_core.so.*; do
            [[ -f $f ]] || continue
            base=${f##*/libopencv_core.so.}
            base=${base%%[a-zA-Z]*}
            # Keep only full x.y.z sonames, not the x.y compatibility symlink.
            [[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && printf '%s\n' "$base"
        done
    done | sort -u
}

installed_version() {  # installed_version <pkg>
    dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

is_installed() {  # is_installed <pkg>
    [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}

# Two versions are "the same OpenCV" when major.minor match. The patch level
# moves with point releases of the same ABI, and comparing it would report a
# mismatch where none exists.
same_abi() {  # same_abi <a> <b>
    [[ -n $1 && -n $2 && ${1%.*} == "${2%.*}" ]]
}

# The NVIDIA-only packages. libopencv-dev is NOT here: it is replaced in place
# by Ubuntu's, because ~40 ros-humble-* and autoware-* packages declare
# `Depends: libopencv-dev` and purging it would take them with it.
#
# These come off BEFORE the install, not after, and the reason is opencv-licenses.
# It owns /usr/share/licenses/opencv4/*, Ubuntu's libopencv-dev ships the same
# paths, and NVIDIA's libopencv-dev does not declare Replaces for it. dpkg then
# refuses to overwrite:
#
#   trying to overwrite '/usr/share/licenses/opencv4/SoftFloat-COPYING.txt',
#   which is also in package opencv-licenses
#
# The unpack of libopencv-dev fails, so NVIDIA's 4.8.0 stays installed, and its
# `Conflicts: libopencv-core-dev, libopencv-dnn-dev, ...` -- it is a monolithic
# dev package that conflicts with every one of Ubuntu's split ones -- then
# rejects the other fifteen packages in the same run. One file conflict, fifteen
# failures, and an apt that will not do anything else until it is repaired.
NVIDIA_PKGS=(libopencv libopencv-python libopencv-samples opencv-licenses opencv-samples-data)

# ── report what is there ────────────────────────────────────────────────────
dev_version=$(installed_version libopencv-dev)
contrib_version=$(installed_version libopencv-contrib-dev)
hdr_version=$(header_version)
link_version=$(linked_runtime_version)
mapfile -t present_runtimes < <(runtime_versions)
aruco_header="${INCLUDE_DIR}/opencv2/aruco.hpp"

printf "${YELLOW}→${NC} Current state\n"
printf "    libopencv-dev          %s\n" "${dev_version:-(not installed)}"
printf "    libopencv-contrib-dev  %s\n" "${contrib_version:-(not installed)}"
printf "    headers                %s\n" "${hdr_version:-(none found)}"
printf "    linked runtime         %s\n" "${link_version:-(no libopencv_core.so)}"
printf "    runtimes present       %s\n" "${present_runtimes[*]:-(none)}"
printf "    contrib (aruco.hpp)    %s\n" "$([[ -f $aruco_header ]] && echo present || echo MISSING)"

# A previous run that hit the file conflict leaves packages unpacked but not
# configured. Say so, because every apt command then fails with an error that
# names dependencies rather than the cause.
broken=$(dpkg -l 2>/dev/null | grep -c '^iU.*opencv' || true)
if [[ ${broken:-0} -gt 0 ]]; then
    printf "${YELLOW}!${NC} %s opencv package(s) are unpacked but not configured;\n" "$broken"
    printf "    an earlier attempt was interrupted. This run repairs that.\n"
fi

# ── decide ──────────────────────────────────────────────────────────────────
if [[ -z $hdr_version && -z $link_version ]]; then
    printf "${YELLOW}⊘${NC} No OpenCV development files installed at all.\n"
    printf "    Nothing to make consistent. rosdep installs libopencv-dev for the\n"
    printf "    workspace; add contrib if you build the aruco packages:\n"
    printf "        sudo apt-get install libopencv-dev libopencv-contrib-dev\n"
    exit 0
fi

mismatch=0
[[ -n $hdr_version ]] && ! same_abi "$hdr_version" "$link_version" && mismatch=1
contrib_missing=0
[[ -f $aruco_header ]] || contrib_missing=1

# Is NVIDIA's OpenCV the one installed? That decides which repair applies: the
# mismatch is theirs to undo, while a plain missing contrib on Ubuntu is one
# apt-get away and needs no pinning or purging.
nvidia_flavour=0
for pkg in "${NVIDIA_PKGS[@]}"; do
    is_installed "$pkg" && nvidia_flavour=1
done

if [[ $mismatch -eq 0 && $contrib_missing -eq 0 ]]; then
    printf "${GREEN}✓${NC} OpenCV is consistent: headers %s, runtime %s, contrib present\n" \
        "$hdr_version" "$link_version"
    if [[ -f $PREF_DST ]]; then
        printf "    The apt pin at %s is in place, holding this.\n" "$PREF_DST"
    fi
    # Deliberately no pin is installed here. Pinning a machine that is already
    # coherent would freeze it at this version, which is the wrong answer if a
    # later JetPack ships a coherent OpenCV of its own. The pin belongs to the
    # remedy below, where it is what keeps the repair from being undone.
    exit 0
fi

# ── it is inconsistent: say exactly how, then repair ────────────────────────
printf "${RED}✗${NC} OpenCV is not consistent:\n"
if [[ -n $hdr_version ]] && ! same_abi "$hdr_version" "$link_version"; then
    printf "    headers are %s but builds link %s -- a silent ABI mismatch\n" \
        "$hdr_version" "${link_version:-nothing}"
fi
if [[ ! -f $aruco_header ]]; then
    printf "    contrib is missing: no %s, so the aruco packages cannot build\n" "$aruco_header"
fi

# Only contrib is missing, and this is not NVIDIA's OpenCV: the versions
# already agree, so there is nothing to pin, purge or downgrade. Installing the
# contrib package for the version already present is the whole repair, and it
# is the case every stock Ubuntu machine lands in.
if [[ $mismatch -eq 0 && $nvidia_flavour -eq 0 ]]; then
    if [[ $CHECK_ONLY -eq 1 ]]; then
        printf "${YELLOW}→${NC} --check: would install libopencv-contrib-dev to match %s\n" "$hdr_version"
        exit 0
    fi
    printf "${YELLOW}→${NC} Installing libopencv-contrib-dev for OpenCV %s...\n" "$hdr_version"
    sudo apt-get update -qq
    sudo apt-get install -y libopencv-contrib-dev
    if [[ -f $aruco_header ]]; then
        printf "${GREEN}✓${NC} contrib headers present (aruco.hpp); OpenCV consistent at %s\n" \
            "$(header_version)"
        exit 0
    fi
    printf "${RED}✗${NC} %s still missing after installing libopencv-contrib-dev\n" "$aruco_header"
    exit 1
fi

# The remaining case is NVIDIA's OpenCV displacing Ubuntu's. The repair is
# Ubuntu's 4.5.4 on both sides, which is only meaningful where Ubuntu's
# packages are the other half of the problem.
if [[ ! -f $PREF_SRC ]]; then
    printf "${RED}✗${NC} Missing %s; cannot pin Ubuntu's OpenCV.\n" "$PREF_SRC"
    exit 1
fi

# ── the safety gate ─────────────────────────────────────────────────────────
#
# On this repo's hardware nothing links NVIDIA's build, which is what makes the
# purge safe. That is a fact about a machine, not a law, so check it here rather
# than assume it: if something IS linked, purging the library breaks it at the
# next launch with an unrelated-looking loader error.
#
# The soname to look for is derived from the headers being displaced (4.8.0 ->
# libopencv_core.so.408) instead of being hardcoded, so this keeps working if
# NVIDIA moves to another version.
displaced_soname=""
if [[ -n $hdr_version ]]; then
    IFS=. read -r dmaj dmin _ <<< "$hdr_version"
    displaced_soname=$(printf 'libopencv_core.so.%d%02d' "$dmaj" "$dmin")
fi

if [[ -n $displaced_soname ]]; then
    printf "${YELLOW}→${NC} Checking whether anything links %s...\n" "$displaced_soname"
    linked=0
    for dir in /opt/ros/humble/lib /opt/autoware/*/lib /usr/local/zed/lib \
               "${LIB_DIRS[@]}" /opt/nvidia/deepstream/*/lib; do
        [[ -d $dir ]] || continue
        count=$(find "$dir" -maxdepth 2 -name '*.so*' -type f 2>/dev/null \
                | xargs -r -n20 readelf -d 2>/dev/null \
                | grep -c "${displaced_soname}" || true)
        [[ ${count:-0} -gt 0 ]] && { printf "${RED}✗${NC} %s: %s object(s)\n" "$dir" "$count"; linked=$((linked + count)); }
    done

    if [[ $linked -gt 0 ]]; then
        printf "${RED}✗${NC} %s object(s) link %s.\n" "$linked" "$displaced_soname"
        printf "    Removing it would break them. Rebuild or repackage them against\n"
        printf "    the runtime first; this script will not purge underneath a\n"
        printf "    library that is in use.\n"
        exit 1
    fi
    printf "${GREEN}✓${NC} Nothing links %s; it only owns the include path\n" "$displaced_soname"
fi

if [[ $CHECK_ONLY -eq 1 ]]; then
    printf "${YELLOW}→${NC} --check: would install the pin, put Ubuntu's 4.5.4 on both sides\n"
    printf "    with contrib, and purge %s\n" "${NVIDIA_PKGS[*]}"
    exit 0
fi

# ── fix it ──────────────────────────────────────────────────────────────────
#
# Pin first. It is what makes the downgrade legal: apt permits one only at a
# priority above 1000, and without it this needs --allow-downgrades and comes
# straight back on the next upgrade.
printf "${YELLOW}→${NC} Installing apt pin at %s\n" "$PREF_DST"
sudo install -m 644 "$PREF_SRC" "$PREF_DST"

# Take the NVIDIA-only packages off FIRST, for the file-conflict reason above.
# dpkg rather than apt, and deliberately: if a previous attempt already broke
# the transaction, apt refuses to do anything except --fix-broken, while dpkg
# still operates per package. Nothing on the system depends on any of these --
# checked with apt-cache rdepends --installed, all five come back empty.
purge_list=()
for pkg in "${NVIDIA_PKGS[@]}"; do
    is_installed "$pkg" && purge_list+=("$pkg")
done
if [[ ${#purge_list[@]} -gt 0 ]]; then
    printf "${YELLOW}→${NC} Removing the NVIDIA-only packages first: %s\n" "${purge_list[*]}"
    sudo dpkg --purge "${purge_list[@]}"
fi

sudo apt-get update -qq

# --fix-broken FIRST, and this ordering is the second thing that caught this
# script out. While any package is half-unpacked, apt refuses every ordinary
# install with "You might want to run 'apt --fix-broken install'" and a wall of
# unmet dependencies: it will not install the very packages that would satisfy
# them. So repair, then install.
printf "${YELLOW}→${NC} Repairing any interrupted transaction...\n"
sudo apt-get -f install -y

printf "${YELLOW}→${NC} Installing Ubuntu's OpenCV development packages...\n"
# libopencv-dev is replaced in place here, so the ros-humble-* and autoware-*
# packages that depend on it are never left unsatisfied.
#
# --allow-downgrades is required and the pin does NOT make it unnecessary. The
# two act at different stages: Pin-Priority above 1000 is what lets the resolver
# CHOOSE an older version as the candidate at all, and then apt-get applies a
# separate safety check that refuses to carry out a downgrade under -y unless
# this flag is given as well. Without it the run dies at the last step with
#
#   E: Packages were downgraded and -y was used without --allow-downgrades.
#
# after the NVIDIA packages have already been removed.
sudo apt-get install -y --allow-downgrades libopencv-dev libopencv-contrib-dev

sudo ldconfig

# ── verify ──────────────────────────────────────────────────────────────────
# Against the invariant, not against a version number.
printf "${YELLOW}→${NC} Verifying...\n"
failed=0

hdr_version=$(header_version)
link_version=$(linked_runtime_version)

if [[ -n $hdr_version ]] && same_abi "$hdr_version" "$link_version"; then
    printf "${GREEN}✓${NC} headers %s and runtime %s agree\n" "$hdr_version" "$link_version"
else
    printf "${RED}✗${NC} headers %s, runtime %s\n" "${hdr_version:-missing}" "${link_version:-missing}"
    failed=1
fi

if [[ -f $aruco_header ]]; then
    printf "${GREEN}✓${NC} contrib headers present (aruco.hpp)\n"
else
    printf "${RED}✗${NC} %s missing\n" "$aruco_header"
    failed=1
fi

if command -v pkg-config &>/dev/null; then
    pc_version=$(pkg-config --modversion opencv4 2>/dev/null || true)
    if [[ -n $pc_version ]] && same_abi "$pc_version" "$hdr_version"; then
        printf "${GREEN}✓${NC} pkg-config opencv4 %s\n" "$pc_version"
    else
        printf "${RED}✗${NC} pkg-config reports %s, headers say %s\n" \
            "${pc_version:-nothing}" "${hdr_version:-nothing}"
        failed=1
    fi
fi

if [[ $failed -ne 0 ]]; then
    printf "${RED}✗${NC} OpenCV is still not consistent\n"
    exit 1
fi

printf "${GREEN}✓${NC} OpenCV consistent at %s, headers and runtime together\n" "$hdr_version"
printf "${YELLOW}Note:${NC} anything already compiled against the previous headers must be\n"
printf "      rebuilt. From the repository root: just clean && just build\n"
