"""Every setup step, in the order they must run.

Dropped from the previous system, by decision on 2026-09-02:

* `iceoryx` -- installed unconditionally and absent from the menu, defended by a
  comment calling it "required, like the RMW itself". It is not: iceoryx caps
  publisher ports at a count this stack exceeds, and the cap is compiled in, so
  the failure is a hard abort at participant creation rather than a fallback to
  the network transport. Iceoryx was then removed from the whole project, not
  only from setup -- `config/iceoryx/`, `scripts/iceoryx/`, the
  `iox-roudi.service` unit, the `<SharedMemory>` blocks in all three CycloneDDS
  profiles, and the guards in `scripts/env.sh` and the justfile. Re-enabling it
  means rebuilding iceoryx from source with a raised limit, which the deleted
  installer did not do either. See `config/README.md`.
* `pacmod` -- an AutonomouStuff apt source, added with `trusted=yes` so
  signatures are not checked. Nothing under `src/` references pacmod; the
  vehicle interface is Turing Drive.
* `gdown` -- installed and never used by anything in the repo.
* `isaac-ros` -- cuVSLAM/cuVGL are out of the plan, and `pose_source` has
  already lost its `isaac` and `visual` options.

`just` is new here. It used to be a prerequisite the user installed by hand from
a piped curl before `setup.sh` would run at all; setup no longer needs it, but
the rest of the repo does, so it becomes an ordinary step.
"""

from __future__ import annotations

from .model import FILES_DIR, HARDWARE_DIR, REPO_ROOT, SCRIPTS_DIR, Requires, Step

_S = lambda name: str(SCRIPTS_DIR / name)          # noqa: E731
_BASH = lambda body: ["bash", "-euc", body]        # noqa: E731

ALL = "laptop orin vehicle ci".split()


def _on(*profiles: str) -> dict[str, bool]:
    return {p: (p in profiles) for p in ALL}


STEPS: list[Step] = [
    # ---- Toolchain -------------------------------------------------------
    Step(
        id="just",
        label="just (command runner)",
        why="Every other workflow in this repo is a just recipe: build, launch, "
            "record, diagnostics. Setup itself no longer needs it.",
        group="Toolchain",
        run=_BASH(
            "command -v just >/dev/null && { just --version; exit 0; }; "
            "curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh "
            "| bash -s -- --to \"$HOME/.local/bin\""
        ),
        profiles=_on(*ALL),
    ),
    Step(
        id="ros2",
        label="ROS 2 Humble",
        why="The base distribution everything else builds against.",
        group="Toolchain",
        run=[_S("install-ros2.sh")],
        requires=Requires(sudo=True),
        profiles=_on(*ALL),
    ),
    Step(
        id="ros2-dev-tools",
        label="ROS 2 development tools",
        why="colcon, rosdep, vcstool. Needed to build the workspace at all.",
        group="Toolchain",
        run=[_S("install-ros2-dev-tools.sh")],
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on(*ALL),
    ),
    Step(
        id="colcon-cargo-ros2",
        label="Rust build support (colcon-cargo-ros2, clang, libclang-dev)",
        why="Two workspace packages build with ament_cargo. Without the colcon "
            "extension it skips them silently and the build aborts later, "
            "confusingly; without libclang, bindgen panics mid-build.",
        group="Toolchain",
        run=[_S("install-colcon-cargo-ros2.sh")],
        requires=Requires(sudo=True),
        after=("ros2-dev-tools",),
        profiles=_on(*ALL),
    ),
    Step(
        id="dev-tools",
        label="Developer tools",
        why="git-lfs, Go, pre-commit, clang-format, PlotJuggler.",
        group="Toolchain",
        run=_BASH(
            "sudo apt-get update && sudo apt-get install -y git-lfs golang && "
            "pip3 install --user pre-commit 'clang-format==17.0.5' && "
            "if ! apt-mark showhold | grep -q ros-humble-plotjuggler-ros; then "
            "sudo apt-get install -y ros-humble-plotjuggler-ros || true; fi"
        ),
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on("laptop", "orin", "vehicle"),
    ),
    Step(
        id="python-deps",
        label="Python dependencies (play_launch)",
        why="play_launch is how the stack is launched and how its logs are kept.",
        group="Toolchain",
        run=["pip3", "install", "--user", "play_launch>=0.5.0,<0.6.0"],
        profiles=_on(*ALL),
    ),
    Step(
        id="geographiclib",
        label="GeographicLib + geoid data",
        why="Geoid model for GNSS altitude. The egm2008-1 grid is a separate "
            "download the package does not pull.",
        group="Toolchain",
        run=_BASH(
            "sudo apt-get update && sudo apt-get install -y geographiclib-tools && "
            "[[ -f /usr/share/GeographicLib/geoids/egm2008-1.pgm ]] || "
            "sudo geographiclib-get-geoids egm2008-1"
        ),
        requires=Requires(sudo=True),
        profiles=_on(*ALL),
    ),

    # ---- Autoware --------------------------------------------------------
    Step(
        id="autoware-debian",
        label="Autoware Debian packages",
        why="~2-3 GB. Skip only to build Autoware from source instead.",
        group="Autoware",
        run=[_S("install-autoware-debian.sh")],
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on("laptop", "orin", "vehicle"),
    ),
    Step(
        id="autoware-data",
        label="Writable Autoware data directory",
        why="Seconds. The packaged /opt/autoware data is root-owned and TensorRT "
            "writes each .engine beside its .onnx, so without this every model "
            "fails to cache and rebuilds on every launch.",
        group="Autoware",
        run=[str(REPO_ROOT / "scripts" / "setup_autoware_data.sh")],
        after=("autoware-debian",),
        profiles=_on("laptop", "orin", "vehicle"),
    ),
    Step(
        id="tensorrt-engines",
        label="Pre-compile TensorRT engines",
        why="~11 min on an Orin, mostly the YOLOX traffic-light detector. "
            "Skipping is fine: the first launch builds them instead, but it does "
            "so inside each node's constructor, so perception is down until then.",
        group="Autoware",
        run=_BASH(f"cd {REPO_ROOT} && just build-engines"),
        requires=Requires(hardware="cuda"),
        after=("autoware-data", "just"),
        profiles=_on(),                  # off everywhere by default: it is slow
    ),
    Step(
        id="opencv",
        label="OpenCV consistency (4.5.4)",
        why="JetPack ships NVIDIA's 4.8.0 headers over Ubuntu's 4.5.4 runtime, so "
            "local builds compile against one and link the other. Also what makes "
            "aruco and the contrib modules available.",
        group="Autoware",
        run=[_S("install-opencv.sh")],
        requires=Requires(sudo=True),
        after=("autoware-debian",),      # let apt settle first, then correct it
        profiles=_on("orin", "vehicle"),
    ),
    Step(
        id="ros-deps",
        label="Workspace ROS dependencies (rosdep)",
        why="Resolves the declared dependencies of everything under src/.",
        group="Autoware",
        run=_BASH(
            f"cd {REPO_ROOT} && source /opt/ros/humble/setup.sh && "
            "rosdep update --rosdistro=humble && "
            "rosdep install -y --from-paths src --ignore-src -r"
        ),
        after=("ros2-dev-tools",),
        profiles=_on(*ALL),
    ),

    # ---- Networking, required to run ROS at all --------------------------
    Step(
        id="cyclonedds-sysctl",
        label="Kernel socket buffers for CycloneDDS",
        why="net.core.rmem_max=2GB plus ipfrag limits, written to "
            "/etc/sysctl.d. Below 10 MB no ros2 node can start at all.",
        group="Networking",
        run=[_S("configure-cyclonedds-sysctl.sh")],
        requires=Requires(sudo=True),
        profiles=_on("laptop", "orin", "vehicle"),
    ),
    Step(
        id="multicast-lo",
        label="Multicast on loopback (persistent)",
        why="Installs multicast-lo.service. Without it lo loses MULTICAST across "
            "a reboot and the loopback DDS profile stops working.",
        group="Networking",
        run=[_S("configure-multicast-lo.sh")],
        requires=Requires(sudo=True),
        profiles=_on("laptop", "orin", "vehicle"),
    ),

    # ---- Sensor drivers: packages, no hardware needed to install ---------
    Step(
        id="nebula-driver",
        label="Nebula LiDAR driver",
        why="Velodyne VLP-32C support. Also inside autoware-debian; installed "
            "separately so the driver is available without it.",
        group="Sensors",
        run=_BASH(
            "sudo apt-get update && sudo apt-get install -y "
            "ros-humble-nebula-ros-1-5-0 ros-humble-nebula-decoders-1-5-0 "
            "ros-humble-nebula-common-1-5-0 ros-humble-nebula-hw-interfaces-1-5-0 "
            "ros-humble-nebula-msgs-1-5-0"
        ),
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on("orin", "vehicle"),
    ),
    Step(
        id="ublox-driver",
        label="u-blox GNSS driver",
        why="Also inside autoware-debian; installed separately for the same reason.",
        group="Sensors",
        run=_BASH(
            "sudo apt-get update && sudo apt-get install -y "
            "ros-humble-ublox-gps ros-humble-ublox-msgs ros-humble-ublox-serialization"
        ),
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on("orin", "vehicle"),
    ),
    Step(
        id="gscam",
        label="gscam (GStreamer camera bridge)",
        why="Drives the GMSL cameras through GStreamer.",
        group="Sensors",
        run=[_S("install-gscam.sh")],
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on("vehicle"),
    ),

    # ---- Hardware: touches devices or device naming ----------------------
    Step(
        id="ublox-udev",
        label="u-blox udev rules",
        why="Gives the receiver a stable device name and adds you to dialout. "
            "Without it the driver opens whichever ttyACM enumerated first.",
        group="Hardware",
        run=_BASH(
            f"sudo cp {FILES_DIR / '99-ublox-gps.rules'} /etc/udev/rules.d/ && "
            "sudo chmod 644 /etc/udev/rules.d/99-ublox-gps.rules && "
            "sudo udevadm control --reload-rules && sudo udevadm trigger && "
            'sudo usermod -aG dialout "$USER" || true'
        ),
        requires=Requires(sudo=True, hardware="ublox-gnss"),
        profiles=_on("vehicle"),
        note="Log out and back in for the dialout group to take effect.",
    ),
    Step(
        id="tier4-camera",
        label="TIER IV camera udev rules + usb_cam",
        why="Stable naming for the C1 cameras over GMSL2-USB.",
        group="Hardware",
        run=[_S("install-tier4-camera.sh")],
        requires=Requires(sudo=True, hardware="tier4-camera"),
        after=("ros2",),
        profiles=_on("vehicle"),
    ),
    Step(
        id="hardware-config",
        label="CAN interfaces + LiDAR network profiles",
        why="Matches specific MAC addresses on this vehicle. Meaningless on any "
            "other machine.",
        group="Hardware",
        run=_BASH(
            f"sudo bash {HARDWARE_DIR / 'can' / 'setup-can.sh'} && "
            f"sudo bash {HARDWARE_DIR / 'lidar-network' / 'setup-lidar-network.sh'}"
        ),
        requires=Requires(sudo=True, hardware="can"),
        profiles=_on("vehicle"),
    ),
    Step(
        id="otocam",
        label="OTOCAM GMSL kernel modules",
        why="IMX390 + MAX9296 kmods and a DTB overlay. Needs the vendor blob and "
            "kernel 5.15.148-tegra.",
        group="Hardware",
        run=_BASH(f"sudo bash {HARDWARE_DIR / 'otocam' / 'setup-otocam.sh'}"),
        requires=Requires(sudo=True, arch=("aarch64",), reboot=True),
        profiles=_on(),                  # opt-in: needs a blob and a reboot
        note="Reboot required for the DTB overlay to take effect.",
    ),
    Step(
        id="linuxptp",
        label="linuxptp (ptp4l + phc2sys)",
        why="Hardware time sync between the two machines.",
        group="Hardware",
        run=[_S("install-linuxptp.sh")],
        requires=Requires(sudo=True, hardware="ptp-nic"),
        profiles=_on(),                  # opt-in until the interface is a parameter
        note="ptp4l.conf is currently hardcoded to interface enP5p5s0.",
    ),

    # ---- Optional --------------------------------------------------------
    Step(
        id="turbovnc-virtualgl",
        label="TurboVNC + VirtualGL",
        why="GPU-accelerated rendering over VNC. Needed for RViz on a headless "
            "machine; the ZED SDK also refuses to run under plain VNC.",
        group="Optional",
        run=[_S("install-turbovnc-virtualgl.sh")],
        requires=Requires(sudo=True),
        profiles=_on("orin", "vehicle"),
    ),
    Step(
        id="chrony-master",
        label="chrony: serve time (master)",
        why="Two-machine operation. The master serves, the orin follows.",
        group="Optional",
        run=["sudo", _S("install-chrony-timesync.sh"), "master"],
        requires=Requires(sudo=True),
        profiles=_on(),
    ),
    Step(
        id="chrony-orin",
        label="chrony: follow the master (orin)",
        why="The other half of the two-machine clock alignment.",
        group="Optional",
        run=["sudo", _S("install-chrony-timesync.sh"), "orin"],
        requires=Requires(sudo=True),
        profiles=_on(),
    ),
]

BY_ID = {s.id: s for s in STEPS}


def ordered(selected: set[str]) -> list[Step]:
    """Selected steps in registry order, which already respects `after`.

    `after` is declared per step and asserted here rather than used to build a
    graph: the list is short, hand-ordered for readability, and a mismatch is a
    bug worth failing loudly on rather than silently reordering around.
    """
    seen: set[str] = set()
    out: list[Step] = []
    for step in STEPS:
        if step.id not in selected:
            continue
        for dep in step.after:
            if dep in selected and dep not in seen:
                raise AssertionError(
                    f"registry order is wrong: {step.id} runs before {dep}"
                )
        seen.add(step.id)
        out.append(step)
    return out
