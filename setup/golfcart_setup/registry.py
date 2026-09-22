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
* `nebula-driver`, `ublox-driver`, `gscam` (2026-09-11) -- three apt steps that
  `rosdep install --from-paths src` already answers, or that another step
  already installs. `ublox_gps` at the time resolved to `ros-humble-ublox-gps`.
  **Since 2026-09-19 it must not**: the driver is built from source, from the
  `ublox_f9p_ws` submodule under `src/sensor_component/external`, whose fork
  of KumarRobotics/ublox takes RTCM as `mavros_msgs/RTCM` (what its vendored
  `ntrip_client` publishes) where the apt build takes `rtcm_msgs/Message`.
  `rosdep --ignore-src` sees the package in the tree and installs its
  *dependencies* instead -- `ros-humble-mavros-msgs`, `ros-humble-rtcm-msgs`,
  `ros-humble-nmea-msgs`, `ros-humble-diagnostic-updater`, `libasio-dev` --
  so there is still no step for it. A machine set up before that date has the
  apt driver installed; the workspace overlay takes precedence, but
  `sudo apt remove ros-humble-ublox-gps ros-humble-ublox-msgs
  ros-humble-ublox-serialization` removes the ambiguity, and
  `scripts/check/run.sh` warns while it is there. `gscam`
  resolved the same way; the GStreamer *plugin* packages it did not depend on
  are declared in the sensor kit's package.xml, which is where a runtime
  dependency belongs, and stayed there when gscam itself was replaced by the
  in-tree `gmslcam` (2026-09-21). Nebula is the one that cannot work this way
  -- there is no rosdep rule for `nebula_ros`, and apt carries only the versioned
  `ros-humble-nebula-ros-1-5-0` from the Autoware localrepo -- but it needs
  none: `autoware-full-1-5-0` pulls it through `autoware-ros-packages-1-5-0`,
  which is why all eight nebula packages are already marked auto-installed.
* `isaac-ros` -- cuVSLAM/cuVGL are out of the plan, and `pose_source` has
  already lost its `isaac` and `visual` options.

`just` is new here. It used to be a prerequisite the user installed by hand from
a piped curl before `setup.sh` would run at all; setup no longer needs it, but
the rest of the repo does, so it becomes an ordinary step.
"""

from __future__ import annotations

from .model import (
    DECLARED, FILES_DIR, HARDWARE_DIR, REPO_ROOT, SCRIPTS_DIR, Requires, Step,
)

_S = lambda name: str(SCRIPTS_DIR / name)          # noqa: E731
_BASH = lambda body: ["bash", "-euc", body]        # noqa: E731


# Preflight fragments. A step that needs something an EARLIER step installs
# must say so itself, because `after` is ordering only -- it never pulls the
# dependency into the selection. `--only tensorrt-engines` on a bare machine,
# or a run whose autoware-debian was unticked, both arrive here with nothing
# installed, and the failure then happens inside a third-party file:
#
#     /opt/ros/humble/setup.bash: No such file or directory
#
# which names neither the step nor the step that would fix it.
_REQUIRE_ROS = """
if [[ ! -f /opt/ros/humble/setup.sh ]]; then
    echo "ROS 2 Humble is not installed: /opt/ros/humble/setup.sh is missing." >&2
    echo "Run the ros2 step first, or let a full setup run reach it:" >&2
    echo "    ./setup.sh --only ros2" >&2
    exit 1
fi
"""

_REQUIRE_AUTOWARE = """
if [[ ! -f /opt/autoware/1.5.0/setup.bash ]]; then
    echo "Autoware 1.5.0 is not installed: /opt/autoware/1.5.0/setup.bash is missing." >&2
    echo "Run the autoware-debian step first, or let a full setup run reach it:" >&2
    echo "    ./setup.sh --only autoware-debian autoware-data" >&2
    exit 1
fi
"""

# The `just` step installs into ~/.local/bin, which Ubuntu's ~/.profile adds to
# PATH only at login and only when the directory already existed. On a first
# run the directory is created mid-pass, so a later step in the same pass
# inherits a PATH without it and `just` is not found. Prepend it rather than
# asking the user to log out and back in between two steps of one run.
_LOCAL_BIN_ON_PATH = """
export PATH="$HOME/.local/bin:$PATH"
if ! command -v just >/dev/null; then
    echo "just is not installed, and this step runs a just recipe." >&2
    echo "Run the just step first, or let a full setup run reach it:" >&2
    echo "    ./setup.sh --only just" >&2
    exit 1
fi
"""


def _ros_bash(body: str) -> list[str]:
    """Run `body` with ROS 2 Humble sourced.

    Two things this exists for, both learned the hard way.

    `set -u` has to come off around the sourcing. ROS's setup.sh and the ament
    shell hooks read variables that are deliberately unset, so under nounset
    the source aborts with

        /opt/ros/humble/setup.sh: line 124: AMENT_TRACE_SETUP_FILES: unbound
        variable

    which names a variable nobody set, says nothing about the step, and leaves
    `rosdep` looking like the thing that failed. It is restored immediately
    afterwards so the body itself still runs under nounset.

    And ROS may legitimately not be there yet -- see `_REQUIRE_ROS`.
    """
    return ["bash", "-euc", f"""
{_REQUIRE_ROS}
set +u
source /opt/ros/humble/setup.sh
set -u
{body}
"""]

# Only the three declared profiles appear here. `all` and `none` are answered
# by Step.default_for, so nothing has to remember to add a new step to them.
#
# The ladder is dev < vehicle: the vehicle is a development machine that also
# has the sensors and the bus wired to it, so every dev step is a vehicle step
# and the difference is exactly the "System config" group.
DEV = ("dev", "vehicle")
EVERY = ("dev", "vehicle", "ci")
VEHICLE = ("vehicle",)
OPT_IN: tuple[str, ...] = ()            # in no preset; tick it yourself


def _on(*profiles: str) -> dict[str, bool]:
    return {p: (p in profiles) for p in DECLARED}


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
        profiles=_on(*EVERY),
    ),
    Step(
        id="ros2",
        label="ROS 2 Humble",
        why="The base distribution everything else builds against.",
        group="Toolchain",
        run=[_S("install-ros2.sh")],
        requires=Requires(sudo=True),
        profiles=_on(*EVERY),
    ),
    Step(
        id="ros2-dev-tools",
        label="ROS 2 development tools",
        why="colcon, rosdep, vcstool. Needed to build the workspace at all.",
        group="Toolchain",
        run=[_S("install-ros2-dev-tools.sh")],
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on(*EVERY),
    ),
    Step(
        id="colcon-cargo-ros2",
        label="Rust build support (colcon-cargo-ros2, clang, libclang-dev)",
        why="The Rust workspace packages, the gmslcam camera driver among them, "
            "build with ament_cargo. Without the colcon extension it skips them "
            "silently and the build aborts later, confusingly; without libclang, "
            "bindgen panics mid-build.",
        group="Toolchain",
        run=[_S("install-colcon-cargo-ros2.sh")],
        requires=Requires(sudo=True),
        after=("ros2-dev-tools",),
        profiles=_on(*EVERY),
    ),
    Step(
        id="dev-tools",
        label="Developer tools",
        why="git-lfs, Go, pre-commit, clang-format, PlotJuggler, GNU parallel "
            "(which supervises the replay scripts).",
        group="Toolchain",
        run=_BASH(
            "sudo apt-get update && sudo apt-get install -y git-lfs golang parallel && "
            "pip3 install --user pre-commit 'clang-format==17.0.5' && "
            "if ! apt-mark showhold | grep -q ros-humble-plotjuggler-ros; then "
            "sudo apt-get install -y ros-humble-plotjuggler-ros || true; fi"
        ),
        requires=Requires(sudo=True),
        after=("ros2",),
        profiles=_on(*DEV),
    ),
    Step(
        id="python-deps",
        label="Python dependencies (play_launch)",
        why="play_launch is how the stack is launched and how its logs are kept.",
        group="Toolchain",
        # 0.10.0 is the floor, not a preference: 0.8.2 rendered the pose
        # initializer's array parameters as strings and killed
        # autoware_pose_initializer_node at startup, taking
        # /localization/initialize with it. No upper bound, so a fix released
        # tomorrow installs without editing this line.
        run=["pip3", "install", "--user", "play_launch>=0.10.0"],
        profiles=_on(*EVERY),
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
        profiles=_on(*EVERY),
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
        profiles=_on(*DEV),
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
        profiles=_on(*DEV),
    ),
    Step(
        id="tensorrt-engines",
        label="Pre-compile TensorRT engines",
        why="~11 min on an Orin, mostly the YOLOX traffic-light detector, and "
            "paid once here instead of inside each node's constructor on the "
            "first launch, where perception is down until it finishes.",
        group="Autoware",
        run=_BASH(
            f"{_REQUIRE_ROS}{_REQUIRE_AUTOWARE}{_LOCAL_BIN_ON_PATH}"
            f"cd {REPO_ROOT} && just build-engines"
        ),
        requires=Requires(hardware="cuda"),
        after=("autoware-data", "just"),
        # On by default despite being the slowest step here: the alternative is
        # not "no compile", it is the same compile during the first launch,
        # with perception down while it runs. `ci` skips it, and a machine with
        # no CUDA device shows it as not applicable.
        profiles=_on(*DEV),
    ),
    Step(
        id="opencv",
        label="OpenCV consistency (headers, runtime, contrib)",
        why="Checks that the headers a build compiles against match the library "
            "it links, and that contrib is there for aruco. JetPack 6.2 breaks "
            "the first (NVIDIA's 4.8.0 headers over Ubuntu's 4.5.4 runtime); on "
            "a machine where they already agree it does nothing.",
        group="Autoware",
        run=[_S("install-opencv.sh")],
        requires=Requires(sudo=True),
        after=("autoware-debian",),      # let apt settle first, then correct it
        profiles=_on(*DEV),
    ),
    Step(
        id="ros-deps",
        label="Workspace ROS dependencies (rosdep)",
        why="Resolves the declared dependencies of everything under src/, which "
            "is where the sensor drivers come from: the GStreamer plugins gmslcam "
            "needs, nmea_navsat_driver, and what the source-built ublox_gps "
            "and ntrip_client need (mavros_msgs, rtcm_msgs, nmea_msgs, asio).",
        group="Autoware",
        run=_ros_bash(
            f"cd {REPO_ROOT} && "
            "rosdep update --rosdistro=humble && "
            "rosdep install -y --from-paths src --ignore-src -r"
        ),
        # rosdep shells out to `sudo apt-get install` for what it resolves, so
        # this belongs in the up-front sudo rather than prompting mid-run.
        requires=Requires(sudo=True),
        after=("ros2-dev-tools",),
        profiles=_on(*EVERY),
    ),

    # ---- Networking, required to run ROS at all --------------------------
    Step(
        id="cyclonedds-sysctl",
        label="Kernel socket buffers for CycloneDDS",
        why="net.core.rmem_max=2GB plus ipfrag limits, written to "
            "/etc/sysctl.d. Below 10 MB no ros2 node can start at all.",
        group="Kernel and network",
        run=[_S("configure-cyclonedds-sysctl.sh")],
        requires=Requires(sudo=True),
        profiles=_on(*DEV),
    ),
    Step(
        id="multicast-lo",
        label="Multicast on loopback (persistent)",
        why="Installs multicast-lo.service. Without it lo loses MULTICAST across "
            "a reboot and the loopback DDS profile stops working.",
        group="Kernel and network",
        run=[_S("configure-multicast-lo.sh")],
        requires=Requires(sudo=True),
        profiles=_on(*DEV),
    ),

    # ---- System config: touches devices, device naming or the bus. This is
    #      the whole of what `vehicle` adds to `dev`. -----------------------
    Step(
        id="ublox-udev",
        label="u-blox udev rules",
        why="Gives the receiver a stable device name and adds you to dialout. "
            "Without it the driver opens whichever ttyACM enumerated first.",
        group="System config",
        run=_BASH(
            f"sudo cp {FILES_DIR / '99-ublox-gps.rules'} /etc/udev/rules.d/ && "
            "sudo chmod 644 /etc/udev/rules.d/99-ublox-gps.rules && "
            "sudo udevadm control --reload-rules && sudo udevadm trigger && "
            'sudo usermod -aG dialout "$USER" || true'
        ),
        requires=Requires(sudo=True, hardware="ublox-gnss"),
        profiles=_on(*VEHICLE),
        note="Log out and back in for the dialout group to take effect.",
    ),
    Step(
        id="tier4-camera",
        label="TIER IV camera udev rules + usb_cam",
        why="Stable naming for the C1 cameras over GMSL2-USB.",
        group="System config",
        run=[_S("install-tier4-camera.sh")],
        requires=Requires(sudo=True, hardware="tier4-camera"),
        after=("ros2",),
        profiles=_on(*VEHICLE),
    ),
    Step(
        id="hardware-config",
        label="CAN interfaces + LiDAR network profiles",
        why="Matches specific MAC addresses on this vehicle. Meaningless on any "
            "other machine.",
        group="System config",
        run=_BASH(
            f"sudo bash {HARDWARE_DIR / 'can' / 'setup-can.sh'} && "
            f"sudo bash {HARDWARE_DIR / 'lidar-network' / 'setup-lidar-network.sh'}"
        ),
        requires=Requires(sudo=True, hardware="can"),
        profiles=_on(*VEHICLE),
    ),
    Step(
        id="otocam",
        label="OTOCAM GMSL kernel modules",
        why="IMX390 + MAX9296 kmods and a DTB overlay. Needs the vendor blob and "
            "kernel 5.15.148-tegra.",
        group="System config",
        run=_BASH(f"sudo bash {HARDWARE_DIR / 'otocam' / 'setup-otocam.sh'}"),
        requires=Requires(sudo=True, arch=("aarch64",), reboot=True),
        profiles=_on(*OPT_IN),                  # opt-in: needs a blob and a reboot
        note="Reboot required for the DTB overlay to take effect.",
    ),
    Step(
        id="linuxptp",
        label="linuxptp (ptp4l + phc2sys)",
        why="Hardware time sync between the two machines.",
        group="System config",
        run=[_S("install-linuxptp.sh")],
        requires=Requires(sudo=True, hardware="ptp-nic"),
        profiles=_on(*OPT_IN),                  # opt-in until the interface is a parameter
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
        # Not in `dev`: a workstation has its own display. This is for the
        # machines that are only reachable over the network.
        profiles=_on(*VEHICLE),
    ),
    Step(
        id="chrony-master",
        label="chrony: serve time (master)",
        why="Two-machine operation. The master serves, the orin follows.",
        group="Optional",
        run=["sudo", _S("install-chrony-timesync.sh"), "master"],
        requires=Requires(sudo=True),
        profiles=_on(*OPT_IN),
    ),
    Step(
        id="chrony-orin",
        label="chrony: follow the master (orin)",
        why="The other half of the two-machine clock alignment.",
        group="Optional",
        run=["sudo", _S("install-chrony-timesync.sh"), "orin"],
        requires=Requires(sudo=True),
        profiles=_on(*OPT_IN),
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
