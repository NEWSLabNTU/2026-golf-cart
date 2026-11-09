#!/usr/bin/env bash
# The packages this host cannot build, one per line on stdout (the reasons on stderr), for
# colcon's --packages-ignore: `just build`, and a workspace that builds this repository's
# src/ beside others (the twin demo's 2026-lsv-ntu-twin).
set -e
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
# Packages a given host cannot build get skipped rather than failing the
# whole build. One list, not one per reason: colcon's --packages-ignore
# takes the LAST occurrence and discards earlier ones, so passing the flag
# twice silently drops the first set. That is not hypothetical — the ZED
# skip stopped working the moment the DBC skip was added below it.
IGNORE_PKGS=()
# The ZED packages need the ZED SDK headers/libs; the master has no SDK.
#
# Test for the CMake config, not the directory. An uninstalled SDK can still
# leave /usr/local/zed behind holding only `resources/`, and the directory
# test then passes while `find_package(ZED)` fails -- zed_components dies
# mid-build instead of being skipped, which is what happens on this
# workstation today.
if ! compgen -G "/usr/local/zed/zed-config*.cmake" > /dev/null \
   && ! compgen -G "/usr/local/zed/lib/libsl_zed*" > /dev/null; then
    echo >&2 "→ ZED SDK not found at /usr/local/zed — skipping ZED packages"
    IGNORE_PKGS+=(zed_components zed_wrapper zed_ros2 zed_debug)
else
    # The wrapper submodule targets SDK 5.x (its README says v5.2) and uses
    # API that 4.x lacks: sl::MODEL::ZED_XONE_HDR, getSensorsDataBatch, the
    # custom-detector tracking fields. A 4.x SDK therefore fails mid-build,
    # dozens of errors deep, rather than being skipped.
    ZED_HDR=/usr/local/zed/include/sl/Camera.hpp
    ZED_MAJOR=$(sed -n 's/^#define ZED_SDK_MAJOR_VERSION \([0-9]*\).*/\1/p' "$ZED_HDR" 2>/dev/null)
    if [[ -n "$ZED_MAJOR" && "$ZED_MAJOR" -lt 5 ]]; then
        echo >&2 "→ ZED SDK ${ZED_MAJOR}.x at /usr/local/zed is older than the wrapper needs (5.x) — skipping ZED packages"
        IGNORE_PKGS+=(zed_components zed_wrapper zed_ros2 zed_debug)
    fi
fi
# golfcart_vehicle_interface generates its CAN bindings from the vendor DBC at
# build time, and that file is proprietary and gitignored. Only the machine
# wired to the CAN bus needs the package at all, so a host without the DBC
# skips it. Put the DBC in place and it builds again automatically.
VEHICLE_IF=src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface
if [[ -z "${CAX_ADS_DBC:-}" && ! -f "$root/${VEHICLE_IF}/CAX_ADS_CAN.dbc" ]]; then
    echo >&2 "→ CAX_ADS_CAN.dbc not found — skipping golfcart_vehicle_interface"
    echo >&2 "  (needed only on the machine driving the CAN bus; see README)"
    IGNORE_PKGS+=(golfcart_vehicle_interface)
fi
# The u-blox driver (NEWSLabNTU/ublox fork) takes its RTCM input as
# mavros_msgs/RTCM, an apt package. A host without it cannot configure
# ublox_gps; only the host the receiver is cabled to needs the driver.
if [[ ! -f /opt/ros/humble/share/mavros_msgs/package.xml ]]; then
    echo >&2 "→ mavros_msgs not installed — skipping the u-blox driver"
    echo >&2 "  (needed only on the host with the receiver: apt install ros-humble-mavros-msgs)"
    IGNORE_PKGS+=(ublox ublox_gps)
fi
# rig_localization (localization_preset:=rigloc) links NVIDIA's cuVSLAM, a
# binary fetched per architecture by the setup step `cuvslam` into the
# submodule's git-ignored third_party/cuvslam/<orin|x86_64>/. Only the host
# that runs the localizer needs it: the orin under host:=master/orin (it
# sits beside the ZED), the one machine under host:=all. CUVSLAM_ROOT in the
# environment points the build at another copy.
RIGLOC=src/localization/rig_localization
case "$(uname -m)" in aarch64) CUVSLAM_DIR=orin ;; *) CUVSLAM_DIR=x86_64 ;; esac
if [[ -d "$root/${RIGLOC}/src" ]] \
   && [[ ! -f "${CUVSLAM_ROOT:-$root/${RIGLOC}/third_party/cuvslam/${CUVSLAM_DIR}/bin}/libcuvslam.so" ]]; then
    echo >&2 "→ cuVSLAM not fetched — skipping rig_localization (localization_preset:=rigloc)"
    echo >&2 "  (needed only on the host that runs it: ./setup.sh --only cuvslam)"
    IGNORE_PKGS+=(rigloc_core rigloc_pipeline rigloc_localizer rigloc_launch rigloc_replay)
fi
[ ${#IGNORE_PKGS[@]} -eq 0 ] || printf '%s\n' "${IGNORE_PKGS[@]}"
