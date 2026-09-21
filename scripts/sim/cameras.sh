#!/usr/bin/env bash
# Synthetic oToBrite cameras: three v4l2loopback devices carrying UYVY at the
# real geometry, so the ROS side of the camera pipeline can be developed with no
# hardware attached.
#
# WHAT THIS CANNOT DO, read before trusting a green result:
#
#   v4l2loopback has no dmabuf support. Not a version issue -- the module
#   exposes no dmabuf parameter and the .ko contains no dmabuf code at all.
#   `nvv4l2camerasrc` accepts only V4L2_MEMORY_DMABUF in importer role, so it
#   cannot open a loopback device on any machine, Jetson included. The
#   zero-copy capture change in docs/roadmaps/2-camera-image-pipeline.md
#   sub-phase A is therefore NOT testable here and needs a real camera.
#
# What it does cover, by machine:
#
#   any host      topic plumbing, CompressedImage.format handling, the rclrs
#                 crate, the detector, bag replay, gmslcam config shape, and the
#                 appsink stall behaviour that killed cameras in the field
#   Jetson        additionally the real nvvidconv/nvjpegenc caps, and NVJPG
#                 encoder capacity with three streams at once -- which is the
#                 open capacity risk, and does not care where pixels came from
#   real cameras  only there: nvv4l2camerasrc binding and the CPU delta
#
# Usage:
#   scripts/sim/cameras.sh up        # create the loopback devices (needs sudo)
#   scripts/sim/cameras.sh feed      # start the three UYVY sources
#   scripts/sim/cameras.sh configs   # write gmslcam param files for them
#   scripts/sim/cameras.sh bench     # encoder throughput, 1 stream vs 3
#   scripts/sim/cameras.sh status
#   scripts/sim/cameras.sh down
#
# bench needs no devices and no cameras: it sources from videotestsrc. On the
# Advantech it answers the NVJPG capacity question directly.
set -uo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
repo_dir=$(cd -- "$script_dir/../.." &>/dev/null && pwd)

# Real stream geometry. Changing these makes the simulation stop simulating.
WIDTH=${WIDTH:-1920}
HEIGHT=${HEIGHT:-1280}
FPS=${FPS:-30}

# Deliberately far from any real index. The oToBrite by-path names carry
# index0/10/12, and reusing those numbers here invites reading a synthetic
# result as a hardware one.
BASE_NR=${BASE_NR:-40}

CAMS=(left right rear)
# Distinct patterns so three windows are telling you which camera is which
# rather than three identical colour bars.
PATTERNS=(smpte ball snow)

RUNDIR=${RUNDIR:-${repo_dir}/.sim-cameras}
PIDFILE="${RUNDIR}/feeders.pid"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; }
err()  { echo -e "  ${RED}[FAIL]${NC} $1"; }
hdr()  { echo -e "\n${CYAN}== $1 ==${NC}"; }

dev_for() {  # dev_for <index>
    echo "/dev/video$((BASE_NR + $1))"
}

# Read /proc/modules rather than `lsmod | grep -q`: grep -q exits on the first
# match, lsmod then dies of SIGPIPE, and under `pipefail` the whole test reads
# as "not loaded". v4l2loopback is usually the most recently loaded module, so
# it sits at the top of the list and the race was lost every time: `up` re-ran
# modprobe over a loaded module and `down` refused to unload one.
module_loaded() {
    grep -q '^v4l2loopback ' /proc/modules 2>/dev/null
}

require() {
    local missing=0
    for c in "$@"; do
        command -v "$c" &>/dev/null || { err "$c not found"; missing=1; }
    done
    return $missing
}

# The encoder differs per machine, and the point of naming it out loud is that a
# CPU jpegenc result must never be mistaken for a hardware one.
pick_encoder() {
    if gst-inspect-1.0 nvjpegenc &>/dev/null && gst-inspect-1.0 nvvidconv &>/dev/null; then
        echo "nvvidconv ! video/x-raw(memory:NVMM),format=NV12 ! nvjpegenc quality=90|jetson-hardware"
    elif gst-inspect-1.0 jpegenc &>/dev/null; then
        echo "videoconvert ! video/x-raw,format=I420 ! jpegenc quality=90|cpu-fallback"
    else
        echo "|none"
    fi
}

cmd_up() {
    require modprobe v4l2-ctl || return 1
    if module_loaded; then
        warn "v4l2loopback already loaded; run 'down' first to change geometry"
    else
        local nrs labels
        nrs=$(printf '%s,' $(seq "$BASE_NR" $((BASE_NR + ${#CAMS[@]} - 1))) ); nrs=${nrs%,}
        labels=$(printf 'sim_camera_%s,' "${CAMS[@]}"); labels=${labels%,}
        echo "  sudo modprobe v4l2loopback devices=${#CAMS[@]} video_nr=${nrs} ..."
        # exclusive_caps=1 makes each node advertise OUTPUT until a producer
        # attaches and CAPTURE afterwards. gmslcam needs CAPTURE, which is why
        # 'feed' has to run before any consumer, not after.
        sudo modprobe v4l2loopback \
            devices="${#CAMS[@]}" \
            video_nr="$nrs" \
            card_label="$labels" \
            exclusive_caps=1 \
            max_width="$WIDTH" \
            max_height="$HEIGHT" || { err "modprobe failed"; return 1; }
    fi
    mkdir -p "$RUNDIR"
    for i in "${!CAMS[@]}"; do
        local d; d=$(dev_for "$i")
        [[ -e $d ]] && ok "${CAMS[$i]} -> $d" || err "${CAMS[$i]} -> $d missing"
    done
}

cmd_feed() {
    require gst-launch-1.0 || return 1
    mkdir -p "$RUNDIR"
    if [[ -f $PIDFILE ]] && kill -0 $(cat "$PIDFILE") 2>/dev/null; then
        warn "feeders already running (pids $(tr '\n' ' ' < "$PIDFILE")); 'down' first"
        return 1
    fi
    : > "$PIDFILE"
    for i in "${!CAMS[@]}"; do
        local d; d=$(dev_for "$i")
        if [[ ! -e $d ]]; then err "$d missing, run 'up' first"; return 1; fi
        # leaky queue for the same reason the real pipeline needs one: a slow
        # sink must cost a frame, not wedge the source.
        #
        # v4l2sink is left on its DEFAULT io-mode. `io-mode=rw` looks harmless
        # and is not: the loopback node then never flips from OUTPUT to CAPTURE
        # and never advertises its format, so `v4l2-ctl --list-formats` comes
        # back empty and every consumer dies with either "Device '/dev/videoN'
        # is not a capture device" or "not-negotiated". Through gmslcam that
        # surfaces as "failed to set pipeline to Playing", which sends you to
        # look at the wrong file.
        # nohup: these are meant to outlive the script that starts them, and
        # `down` is what stops them.
        nohup gst-launch-1.0 -q -e \
            videotestsrc is-live=true pattern="${PATTERNS[$i]}" \
            ! "video/x-raw,format=UYVY,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1" \
            ! queue leaky=downstream max-size-buffers=2 \
            ! identity drop-allocation=true \
            ! v4l2sink device="$d" sync=false async=false \
            >"${RUNDIR}/${CAMS[$i]}.log" 2>&1 &
        echo $! >> "$PIDFILE"
        ok "${CAMS[$i]} feeding $d  ${WIDTH}x${HEIGHT}@${FPS} UYVY  pattern=${PATTERNS[$i]}"
    done
    sleep 2
    local dead=0
    while read -r p; do kill -0 "$p" 2>/dev/null || dead=1; done < "$PIDFILE"
    [[ $dead -eq 0 ]] && ok "all feeders alive" || err "a feeder died; see ${RUNDIR}/*.log"
}

cmd_configs() {
    mkdir -p "$RUNDIR"
    local spec enc tier
    spec=$(pick_encoder); enc=${spec%|*}; tier=${spec##*|}
    if [[ $tier == none ]]; then err "no JPEG encoder element available"; return 1; fi

    hdr "Encoder tier: $tier"
    case $tier in
        jetson-hardware) ok "nvvidconv + nvjpegenc present, this is the real encode path" ;;
        cpu-fallback)    warn "no nvjpegenc here: CPU jpegenc. Shape only. A CPU number
         measured from these configs says NOTHING about the hardware path." ;;
    esac

    # One complete gmslcam parameter file per camera: what the sensor kit
    # splits across camera_<cam>.yaml, the capture profile and the launch
    # file's camera_info_url, folded into one so a single `ros2 run` works.
    # The calibration URL is the source checkout's file, because gmslcam takes
    # file:// or an absolute path and not package://.
    local calib_dir="${repo_dir}/src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config"
    for i in "${!CAMS[@]}"; do
        local c=${CAMS[$i]} d; d=$(dev_for "$i")
        cat > "${RUNDIR}/camera_${c}.yaml" <<EOF
# GENERATED by scripts/sim/cameras.sh -- do not commit, do not edit.
# Synthetic camera on a v4l2loopback device. Encoder tier: ${tier}.
/**:
  ros__parameters:
    device: "${d}"
    width: ${WIDTH}
    height: ${HEIGHT}
    fps: ${FPS}
    codec: "jpeg"
    frame_id: "camera_${c}_optical_link"
    image_topic: "image_raw/compressed"
    camera_info_topic: "camera_info"
    camera_info_url: "file://${calib_dir}/camera_${c}_calibration.yaml"
    pipeline: "v4l2src device=${d} ! video/x-raw,format=UYVY,width=${WIDTH},height=${HEIGHT},framerate=${FPS}/1 ! queue leaky=downstream max-size-buffers=2 max-size-bytes=0 max-size-time=0 ! ${enc} ! appsink name=ros_sink emit-signals=false sync=false max-buffers=2 drop=true"
EOF
        ok "wrote ${RUNDIR}/camera_${c}.yaml"
    done

    hdr "Run one"
    echo "  ros2 run gmslcam gmslcam --ros-args \\"
    echo "    -r __ns:=/sensing/camera/left -r __node:=camera_left \\"
    echo "    --params-file ${RUNDIR}/camera_left.yaml"
    echo
    echo "  Or all three through the real launch file, which is what these"
    echo "  devices are for (the committed profile encodes in software; on a"
    echo "  Jetson, capture_profile:=sim-nvjpeg uses NVJPG):"
    echo "    ros2 launch golfcart_sensor_kit_launch camera.launch.xml \\"
    echo "        camera_model:=gmslcam capture_profile:=sim"
    echo
    echo "  ros2 topic hz /sensing/camera/left/image_raw/compressed"
    echo "  ros2 topic echo --field format /sensing/camera/left/image_raw/compressed --once"
    echo
    echo "  That last one is the point: it prints what gmslcam writes into"
    echo "  CompressedImage.format, which is the contract the rclrs crate has to"
    echo "  parse. Expect the bare \"jpeg\", not the compound form."
}

# NVJPG is one shared block and three cameras contend for it. Three streams at
# 1920x1280 and 30 fps is 221 MP/s of JPEG encode on a single engine, and the
# failure mode is not an error: it is dropped frames, or a silent software
# fallback that puts the load back on the CPU this whole exercise exists to
# unload. This measures it, and it does not need cameras -- the encoder does not
# care where the pixels came from, only how many arrive.
#
# TWO measurements, because one answers a question the other cannot:
#
#   sustain   the real question. Live 30 fps sources, one stream then three:
#             does the encoder keep up with the cameras? A live source cannot
#             exceed 30 fps, so this can only ever say "met" or "short".
#   ceiling   how much headroom there is. Free-running sources, so the encoder
#             is the only limit. Needed because "met" with 5% to spare and "met"
#             with 4x to spare are different plans for the same phase.
#
# Both warm up first and discard it. NVJPG's first frames in a process include
# engine init, and a cold 10-second run reports a number that says more about
# startup than about throughput -- the earlier version of this recipe reported
# one stream as SHORT and three as met, which is not a thing an encoder can do.
cmd_bench() {
    require gst-launch-1.0 || return 1
    local spec enc tier secs=${SECS:-10}
    spec=$(pick_encoder); enc=${spec%|*}; tier=${spec##*|}
    if [[ $tier == none ]]; then err "no JPEG encoder element available"; return 1; fi

    hdr "Encoder tier: $tier"
    if [[ $tier != jetson-hardware ]]; then
        warn "This is NOT the hardware encoder. The numbers below measure CPU"
        warn "jpegenc and answer nothing about NVJPG. Run this on the Advantech."
    fi

    mkdir -p "$RUNDIR"
    local mp; mp=$(awk -v w="$WIDTH" -v h="$HEIGHT" 'BEGIN{printf "%.2f", w*h/1000000}')
    echo "  ${WIDTH}x${HEIGHT} = ${mp} MP per frame, ${FPS} fps target"

    local caps="video/x-raw,format=UYVY,width=${WIDTH},height=${HEIGHT}"

    # A live source, rate-limited to FPS, exactly like a camera.
    run_live() {
        local n=$1 frames=$((FPS * secs)) pids=() i
        for ((i = 0; i < n; i++)); do
            # -v, not -q: fpsdisplaysink reports through the `last-message`
            # property, and gst-launch only prints property changes when it is
            # verbose. With -q the log is empty and every rate reads as zero.
            gst-launch-1.0 -v \
                videotestsrc is-live=true num-buffers="$frames" \
                ! "${caps},framerate=${FPS}/1" \
                ! ${enc} \
                ! fpsdisplaysink video-sink=fakesink text-overlay=false sync=false \
                >"${RUNDIR}/bench_live_${n}_${i}.log" 2>&1 &
            pids+=("$!")
        done
        wait "${pids[@]}" 2>/dev/null
    }

    # One generated buffer, repeated as fast as the pipeline will take it.
    # `imagefreeze` costs nothing per frame, so the encoder is the only limit --
    # `videotestsrc` drawing a pattern 900 times is not.
    run_free() {
        local n=$1 frames=$2 pids=() i
        for ((i = 0; i < n; i++)); do
            gst-launch-1.0 -q \
                videotestsrc num-buffers=1 pattern=solid-color \
                ! "${caps},framerate=0/1" \
                ! imagefreeze num-buffers="$frames" \
                ! ${enc} \
                ! fakesink sync=false \
                >"${RUNDIR}/bench_free_${n}_${i}.log" 2>&1 &
            pids+=("$!")
        done
        wait "${pids[@]}" 2>/dev/null
    }

    echo "  warming up (discarded)"
    run_free 1 120 >/dev/null 2>&1

    hdr "Sustain: can it keep up with the cameras?"
    local n
    for n in 1 3; do
        run_live "$n"
        local total=0 dropped=0 i r d
        for ((i = 0; i < n; i++)); do
            # Mean of the instantaneous rates, with the first four reports
            # dropped: at the default half-second reporting interval those cover
            # the first two seconds, which are pipeline startup rather than
            # throughput. The cumulative `average:` field cannot be trimmed that
            # way, which is why it is not the one used.
            r=$(grep -o 'current: *[0-9.]*' "${RUNDIR}/bench_live_${n}_${i}.log" 2>/dev/null \
                | grep -o '[0-9.]*$' \
                | awk 'NR>4 { sum += $1; count++ } END { if (count) printf "%.2f", sum/count }')
            [[ -z $r ]] && r=0
            total=$(awk -v t="$total" -v r="$r" 'BEGIN{print t+r}')
            d=$(grep -o 'dropped: *[0-9]*' "${RUNDIR}/bench_live_${n}_${i}.log" 2>/dev/null \
                | grep -o '[0-9]*$' | tail -1)
            dropped=$((dropped + ${d:-0}))
        done
        awk -v t="$total" -v m="$mp" -v n="$n" -v f="$FPS" -v dr="$dropped" 'BEGIN{
            printf "    %d stream(s): %.1f fps, %.0f MP/s, %d dropped", n, t, t*m, dr
            want = n*f
            # Dropped frames first: that is the encoder failing to keep up, and
            # it is unambiguous. The rate is a mean of half-second samples and
            # carries a couple of fps of jitter on a source that is capped at
            # the target anyway, so it only decides the verdict when it misses
            # by a margin no jitter explains.
            if (dr > 0) printf "   <-- SHORT: dropped frames at %d fps\n", want
            else if (t < want*0.90) printf "   <-- SHORT of %d fps\n", want
            else printf "   (target %d fps, met)\n", want
        }'
    done

    hdr "Ceiling: how much headroom is there?"
    local frames=$((FPS * secs * 3))
    for n in 1 3; do
        local t0 t1
        t0=$(date +%s.%N); run_free "$n" "$frames"; t1=$(date +%s.%N)
        awk -v n="$n" -v f="$frames" -v a="$t0" -v b="$t1" -v m="$mp" -v fps="$FPS" 'BEGIN{
            d = b - a; total = n*f/d
            printf "    %d process(es): %.1f fps, %.0f MP/s  (%.1fx the %d fps this camera set needs)\n",
                   n, total, total*m, total/(3*fps), 3*fps
        }'
    done

    echo
    echo "  Read the two together. SHORT in the first block with headroom in"
    echo "  the second means the bottleneck is upstream of the encoder, not the"
    echo "  encoder. SHORT in both means NVJPG is saturated, and the plan"
    echo "  changes: lower quality, lower resolution, or fewer cameras on the"
    echo "  hardware path. Record the numbers either way."
}

cmd_status() {
    hdr "Module"
    grep '^v4l2loopback ' /proc/modules 2>/dev/null || echo "  not loaded"
    hdr "Devices"
    for i in "${!CAMS[@]}"; do
        local d; d=$(dev_for "$i")
        if [[ -e $d ]]; then
            ok "${CAMS[$i]} $d  $(v4l2-ctl -d "$d" --list-formats 2>/dev/null | grep -c "'" ) format(s)"
        else
            echo "  ${CAMS[$i]} $d absent"
        fi
    done
    hdr "Feeders"
    if [[ -f $PIDFILE ]]; then
        while read -r p; do
            kill -0 "$p" 2>/dev/null && ok "pid $p alive" || err "pid $p dead"
        done < "$PIDFILE"
    else
        echo "  none started"
    fi
    hdr "Encoder available here"
    local spec; spec=$(pick_encoder); echo "  tier: ${spec##*|}"
}

cmd_down() {
    if [[ -f $PIDFILE ]]; then
        while read -r p; do kill "$p" 2>/dev/null && ok "stopped $p"; done < "$PIDFILE"
        sleep 1
        while read -r p; do kill -9 "$p" 2>/dev/null; done < "$PIDFILE"
        rm -f "$PIDFILE"
    fi
    if module_loaded; then
        sudo modprobe -r v4l2loopback && ok "module unloaded" || err "rmmod failed, a consumer may still hold a device open"
    else
        ok "module not loaded"
    fi
}

usage() {
    # Print the header block only: every line from 2 until the first that is
    # not a comment. Bounded by content rather than a line number, so adding a
    # subcommand cannot make this spill into the code below it.
    awk 'NR>1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

case "${1:-}" in
    up)      cmd_up ;;
    feed)    cmd_feed ;;
    configs) cmd_configs ;;
    bench)   cmd_bench ;;
    status)  cmd_status ;;
    down)    cmd_down ;;
    *)       usage; exit 1 ;;
esac
