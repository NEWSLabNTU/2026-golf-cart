#!/usr/bin/env bash
# What the camera transcode path can actually do on THIS machine.
#
# Answers, in order, the questions docs/roadmaps/2-camera-image-pipeline.md
# lists as blockers, and prints a verdict for each rather than a wall of caps:
#
#   3  does nvv4l2camerasrc exist, and will it bind to the oToBrite driver?
#   4  does nvjpegenc accept an NVMM buffer here, or is the committed pipeline
#      quietly falling back to software?
#      - plus what DeepStream contributes, which the plan says is nothing
#
# Everything except the last section runs with no cameras attached. The camera
# section is skipped, loudly, when there are no /dev/video* devices.
#
# Usage: scripts/check/camera_pipeline.sh [device]
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
repo_dir=$(cd -- "$script_dir/../.." &>/dev/null && pwd)

WIDTH=${WIDTH:-1920}
HEIGHT=${HEIGHT:-1280}
FPS=${FPS:-30}
DEVICE=${1:-}

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "  ${RED}[FAIL]${NC} $1"; }
hdr()  { echo -e "\n${CYAN}== $1 ==${NC}"; }

command -v gst-inspect-1.0 &>/dev/null || { err "gst-inspect-1.0 not found"; exit 1; }

# ── platform ────────────────────────────────────────────────────────────────
hdr "Platform"
if [[ -r /etc/nv_tegra_release ]]; then
    ok "$(head -1 /etc/nv_tegra_release)"
else
    warn "not a Jetson: no /etc/nv_tegra_release. Nothing below transfers to
         one -- nvvidconv and nvv4l2camerasrc are L4T-only, VIC and NVJPG are
         fixed-function blocks sharing memory with the CPU, and a dGPU crosses
         PCIe both ways."
fi
ds=$(dpkg-query -W -f='${Version}' deepstream-7.1 2>/dev/null \
     || dpkg-query -W -f='${Package} ${Version}' 'deepstream-*' 2>/dev/null)
[[ -n $ds ]] && ok "DeepStream $ds" || warn "no DeepStream package"
command -v nvpmodel &>/dev/null && ok "$(nvpmodel -q 2>/dev/null | head -1)"

# ── elements ────────────────────────────────────────────────────────────────
hdr "Elements"
for element in v4l2src nvvidconv nvjpegenc nvjpegdec nvv4l2camerasrc nvvideoconvert; do
    if gst-inspect-1.0 "$element" &>/dev/null; then
        ok "$element"
    else
        err "$element missing"
    fi
done

caps_of() {  # caps_of <element> <SINK|SRC>
    gst-inspect-1.0 "$1" 2>/dev/null \
        | awk -v want="$2 template" '$0 ~ want {grab=1} grab && /template:/ && $0 !~ want {grab=0} grab'
}

# ── blocker 4: does nvjpegenc take an NVMM buffer? ──────────────────────────
hdr "Blocker 4 - nvjpegenc NVMM sink caps"
enc_sink=$(caps_of nvjpegenc SINK)
if grep -q 'video/x-raw(memory:NVMM)' <<<"$enc_sink"; then
    ok "accepts video/x-raw(memory:NVMM): $(grep -A1 'memory:NVMM' <<<"$enc_sink" | grep -o 'format:.*' | head -1)"
    ok "the committed pipeline hands it a dmabuf, so this is the hardware path"
else
    err "no NVMM sink caps: nvvidconv would have to copy back to system memory,
         and the encode is not the zero-copy path the pipeline assumes"
fi
grep -q 'GRAY8' <<<"$enc_sink" \
    && warn "GRAY8 is accepted in SYSTEM memory only -- a mono JPEG at the source
         (see the open question in the roadmap) cannot stay in NVMM"

# ── blocker 3: nvv4l2camerasrc ───────────────────────────────────────────────
hdr "Blocker 3 - nvv4l2camerasrc"
if gst-inspect-1.0 nvv4l2camerasrc &>/dev/null; then
    src_caps=$(caps_of nvv4l2camerasrc SRC)
    if grep -q 'UYVY' <<<"$src_caps" && grep -q 'memory:NVMM' <<<"$src_caps"; then
        ok "emits UYVY in NVMM, which is what nvvidconv wants"
    else
        err "unexpected src caps: $src_caps"
    fi
    warn "element presence is NOT the answer. It accepts only V4L2_MEMORY_DMABUF
         in importer role, so this binds to the oToBrite nv_imx390 driver or it
         does not, and only a real camera settles it. v4l2loopback cannot stand
         in: the module has no dmabuf support at all."
else
    err "nvv4l2camerasrc missing"
fi

# ── DeepStream ──────────────────────────────────────────────────────────────
hdr "DeepStream"
if gst-inspect-1.0 nvvideoconvert &>/dev/null; then
    if grep -q 'UYVY' <<<"$(caps_of nvvideoconvert SINK)"; then
        ok "nvvideoconvert accepts UYVY on this install"
    else
        warn "nvvideoconvert does not list UYVY here"
    fi
fi
gst-inspect-1.0 2>/dev/null | grep -q 'nvdsgst_infer' && ok "nvinfer present"
echo "  DeepStream contributes nothing to this pipeline and is not in the plan:"
echo "  nvvidconv already does the conversion on the same VIC hardware, and"
echo "  DeepStream's asset is nvstreammux batching for nvinfer, which a JPEG"
echo "  transcode has no use for. There is no DeepStream JPEG encoder --"
echo "  nvjpegenc is L4T multimedia, not DeepStream. Revisit when perception"
echo "  runs on these cameras."

# ── negotiation, with no camera ─────────────────────────────────────────────
hdr "Negotiation (videotestsrc, no camera needed)"
probe() {  # probe <label> <pipeline...>
    local label=$1; shift
    if timeout 60 gst-launch-1.0 -q "$@" &>/dev/null; then
        ok "$label"
    else
        err "$label"
        return 1
    fi
}
probe "v4l2src-shaped: UYVY(sysmem) -> nvvidconv -> NV12(NVMM) -> nvjpegenc" \
    videotestsrc num-buffers=30 \
    ! "video/x-raw,format=UYVY,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
    ! nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" \
    ! nvjpegenc quality=90 ! fakesink
probe "decode back: nvjpegdec" \
    videotestsrc num-buffers=10 \
    ! "video/x-raw,format=UYVY,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
    ! nvvidconv ! "video/x-raw(memory:NVMM),format=NV12" \
    ! nvjpegenc quality=90 ! jpegparse ! nvjpegdec ! fakesink

echo
echo "  Capacity is a separate question and has its own recipe:"
echo "      just sim cameras-bench"
echo "  It needs no cameras either, and measures both whether NVJPG keeps up"
echo "  with three 30 fps streams and how much headroom is left."

# ── capture profiles ────────────────────────────────────────────────────────
#
# Each file in camera_capture/ is one capture path. This runs them, so the
# question "which profile does this vehicle need" has an answer that came from
# the hardware rather than from a guess.
hdr "Capture profiles"

profile_dir=""
for candidate in \
    "${repo_dir}/install/golfcart_sensor_kit_launch/share/golfcart_sensor_kit_launch/config/camera_capture" \
    "${repo_dir}/src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config/camera_capture"; do
    [[ -d $candidate ]] && { profile_dir=$candidate; break; }
done
if [[ -z $profile_dir ]]; then
    err "no camera_capture/ directory found; build golfcart_sensor_kit_launch"
    exit 0
fi

# The profile is camera.launch.xml's `capture_profile` argument and nothing else
# — the CAMERA_CAPTURE_PROFILE environment variable it used to also read is gone.
# Read the default out of the launch file rather than repeating it here, so this
# report cannot claim a profile the launch would not run.
launch_xml=""
for candidate in \
    "${repo_dir}/install/golfcart_sensor_kit_launch/share/golfcart_sensor_kit_launch/launch/camera.launch.xml" \
    "${repo_dir}/src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/camera.launch.xml"; do
    [[ -f $candidate ]] && { launch_xml=$candidate; break; }
done
active=$(sed -n 's/.*name="capture_profile"[^>]*default="\([^"]*\)".*/\1/p' "${launch_xml}" 2>/dev/null | head -1)
if [[ -z $active ]]; then
    warn "could not read capture_profile's default out of camera.launch.xml"
    active=nvv4l2camerasrc
else
    ok "active profile: ${active}  (capture_profile default in camera.launch.xml)"
fi
echo "  from ${profile_dir#"${repo_dir}/"}"

# The pipeline for one camera, out of one profile. Reading the YAML rather than
# reconstructing the string keeps this honest: it tests what launch will run.
pipeline_of() {  # pipeline_of <profile-file> <camera>
    python3 - "$1" "$2" <<'PYEOF'
import sys, yaml
with open(sys.argv[1]) as handle:
    doc = yaml.safe_load(handle) or {}
key = f"/**/camera_{sys.argv[2]}"
print(doc.get(key, {}).get("ros__parameters", {}).get("gscam_config", ""))
PYEOF
}

# A loopback device to borrow when the profile's own device is absent. Tests the
# element chain and the caps, which is everything except the binding itself.
stand_in=""
for candidate in /dev/video40 /dev/video41 /dev/video42; do
    [[ -e $candidate ]] && { stand_in=$candidate; break; }
done

cleared=()
for profile_file in "$profile_dir"/*.yaml; do
    profile=$(basename "$profile_file" .yaml)
    pipeline=$(pipeline_of "$profile_file" left)
    if [[ -z $pipeline ]]; then
        err "$profile: no gscam_config for camera_left"
        continue
    fi
    device=$(grep -oE 'device=[^ ]+' <<<"$pipeline" | head -1 | cut -d= -f2-)

    marker="$profile"
    run_pipeline=$pipeline
    if [[ ! -e $device ]]; then
        if [[ -z $stand_in ]]; then
            warn "$profile: $device absent, and no loopback to stand in. Skipped."
            continue
        fi
        # The substitution makes this a test of the element chain, NOT of the
        # profile: v4l2loopback has no dmabuf at all, so io-mode=4 and
        # nvv4l2camerasrc are EXPECTED to fail here and that says nothing about
        # a real camera.
        run_pipeline=${pipeline//$device/$stand_in}
        marker="$profile (device absent, shape only on $stand_in)"
    fi

    # shellcheck disable=SC2086
    if timeout 60 gst-launch-1.0 -q $run_pipeline ! fakesink num-buffers=30 &>/dev/null; then
        ok "$marker"
        # `sim` is never a candidate: its device exists by construction, and a
        # loopback clearing proves nothing about a camera.
        [[ -e $device && $profile != sim ]] && cleared+=("$profile")
    else
        if [[ -e $device ]]; then
            err "$profile: did not negotiate against $device"
        else
            warn "$marker: did not negotiate. Expected for dmabuf profiles on a
         loopback device, which has no dmabuf support; meaningless either way
         until a real camera is attached."
        fi
    fi
done

echo
if [[ ${#cleared[@]} -eq 0 ]]; then
    warn "no camera profile was tested against a real device. Rerun this on the
         vehicle; until then the only thing proved here is that the element
         chain negotiates."
else
    # Ladder order, not the order the files happened to be read in: the whole
    # point is to take the cheapest capture path that works.
    best=""
    for candidate in nvv4l2camerasrc v4l2-dmabuf v4l2-mmap; do
        for entry in "${cleared[@]}"; do
            [[ $entry == "$candidate" && -z $best ]] && best=$candidate
        done
    done
    ok "cleared against a real device: ${cleared[*]}"
    echo "  Take the first one that works on the ladder. For one run:"
    echo "      ros2 launch golfcart_sensor_kit_launch camera.launch.xml \\"
    echo "          camera_model:=gscam capture_profile:=${best}"
    echo "  To make it what the vehicle runs, change capture_profile's default"
    echo "  in camera.launch.xml: \`just launch\` cannot pass the argument through."
fi

hdr "Devices"
shopt -s nullglob
devices=(/dev/video*)
if [[ ${#devices[@]} -eq 0 ]]; then
    warn "no /dev/video* at all. For a box with no cameras: \`just sim cameras\`,
         then launch camera.launch.xml with capture_profile:=sim."
else
    ok "${devices[*]}"
    [[ -d /dev/v4l/by-path ]] && echo "  by-path: $(ls /dev/v4l/by-path 2>/dev/null | tr '\n' ' ')"
    for device in "${devices[@]}"; do
        command -v v4l2-ctl &>/dev/null || break
        printf '    %s: %s\n' "$device" \
            "$(v4l2-ctl -d "$device" --list-formats 2>/dev/null | grep -oE "'[A-Z0-9]+'" | tr '\n' ' ')"
    done
fi
