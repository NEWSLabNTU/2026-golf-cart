#!/usr/bin/env bash
# install-autoware-debian.sh - install one Autoware release from the localrepo.
#
#   install-autoware-debian.sh [VERSION] [--dry-run] [--force] [--reinstall]
#
# VERSION is X.Y.Z (default: the selected one, scripts/autoware_version.sh).
# The release, deb name and sha256 come from the catalogue, versions.yaml, via
# setup/golfcart_setup/autoware.py; nothing about a release is written here.
#
#   --dry-run    print what would be downloaded and installed; no sudo, no
#                download, no apt beyond a simulation
#   --force      run every stage even when this release is already installed
#   --reinstall  allow replacing an OLDER revision of the same version (e.g.
#                1.5.0-1 -> 1.5.0-3). That removes the version's packages with
#                its own uninstall-autoware.sh and installs them again, because
#                the packages keep their version numbers between revisions and
#                apt would otherwise keep the old ones.
#
# Several versions live side by side: every localrepo package is suffixed per
# version (autoware-full-2-1-0, /opt/autoware/2.1.0, ...), and from 1.5.0-3 on
# no file is shared between versions. Installing one never removes another:
# the apt plan is simulated first and refused if it would remove a package of
# another Autoware version.
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

VERSION=""
DRY_RUN=0
FORCE=0
REINSTALL=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        --reinstall) REINSTALL=1 ;;
        -h|--help) sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option: $arg" >&2; exit 2 ;;
        *)
            [ -z "$VERSION" ] || { echo "one VERSION only (got $VERSION and $arg)" >&2; exit 2; }
            VERSION="$arg" ;;
    esac
done

CATALOGUE_OUT=$(python3 "${REPO_ROOT}/setup/golfcart_setup/autoware.py" shell ${VERSION:+"$VERSION"}) \
    || exit 2
# AW_VERSION AW_RELEASE AW_DEB_RELEASE AW_SUFFIX AW_PLATFORM AW_DEB AW_SHA256 AW_URL
# AW_LOCALREPO_PACKAGE AW_LOCALREPO_VERSION, all shell-quoted by autoware.py.
eval "${CATALOGUE_OUT}"

PREFIX="/opt/autoware/${AW_VERSION}"
SHARE="/usr/share/autoware/${AW_VERSION}"
FULL_PACKAGE="autoware-full-${AW_SUFFIX}"

echo "→ Autoware ${AW_VERSION}: localrepo ${AW_RELEASE} (${AW_PLATFORM})"

DATA_DIR="${DATA_DIR:-${REPO_ROOT}/data}"
DEB_DOWNLOAD_DIR="${DATA_DIR}/autoware-debian"
TEMP_DEB="${DEB_DOWNLOAD_DIR}/${AW_DEB}"

pkg_version() {  # installed version of $1, empty when not installed
    { dpkg-query -W -f='${db:Status-Abbrev} ${Version}\n' "$1" 2>/dev/null || true; } \
        | awk '$1 ~ /^ii/ { print $2 }'
}

INSTALLED_LOCALREPO=$(pkg_version "${AW_LOCALREPO_PACKAGE}")
INSTALLED_FULL=$(pkg_version "${FULL_PACKAGE}")

# What is there now, compared on the whole Debian version: the revision is
# what tells 1.5.0-1 from 1.5.0-3, whose packages are otherwise identical in
# name and version.
# The deb's Version is <deb release><platform> (1.5.0-4ubuntu2204, from the
# tag 1.5.0-humble-4): compare the release part, and say so when the platform
# part differs. AW_RELEASE is the tag, which names the ROS distro.
LOCALREPO_STATE=absent
if [ -n "${INSTALLED_LOCALREPO}" ]; then
    INSTALLED_RELEASE=$(sed -E 's/^([0-9]+\.[0-9]+\.[0-9]+-[0-9]+).*/\1/' <<<"${INSTALLED_LOCALREPO}")
    if dpkg --compare-versions "${INSTALLED_RELEASE}" eq "${AW_DEB_RELEASE}"; then
        LOCALREPO_STATE=current
    elif dpkg --compare-versions "${INSTALLED_RELEASE}" gt "${AW_DEB_RELEASE}"; then
        LOCALREPO_STATE=newer
    else
        LOCALREPO_STATE=older
    fi
    if [ "${INSTALLED_LOCALREPO}" != "${INSTALLED_RELEASE}${AW_PLATFORM}" ]; then
        echo "  WARNING: installed ${INSTALLED_LOCALREPO} is not the ${AW_PLATFORM} build" >&2
    fi
fi

echo "  installed: ${AW_LOCALREPO_PACKAGE} ${INSTALLED_LOCALREPO:-none} (${LOCALREPO_STATE}),"\
     "${FULL_PACKAGE} ${INSTALLED_FULL:-none}"

OTHERS=()
for d in /opt/autoware/*/; do
    v=$(basename "$d")
    [ "$v" != "${AW_VERSION}" ] && [ -f "${d}setup.bash" ] && OTHERS+=("$v")
done
[ "${#OTHERS[@]}" -eq 0 ] || echo "  other versions installed (kept): ${OTHERS[*]}"

if [ "${LOCALREPO_STATE}" = older ] && [ "${REINSTALL}" -ne 1 ]; then
    cat >&2 <<EOF
  ${AW_LOCALREPO_PACKAGE} ${INSTALLED_LOCALREPO} is older than the catalogue's
  ${AW_LOCALREPO_VERSION}. Its packages keep their version numbers between
  revisions, so upgrading the repository alone changes nothing: the version's
  packages have to be removed and installed again. Other Autoware versions are
  not touched, and neither are downloaded models. Re-run with --reinstall:

      ${SCRIPT_DIR}/install-autoware-debian.sh ${AW_VERSION} --reinstall

EOF
    [ "${DRY_RUN}" -eq 1 ] && exit 0
    exit 1
fi

if [ "${LOCALREPO_STATE}" != older ] && [ "${LOCALREPO_STATE}" != absent ] \
   && [ -n "${INSTALLED_FULL}" ] && [ -f "${PREFIX}/setup.bash" ] && [ "${FORCE}" -ne 1 ]; then
    echo "✓ Autoware ${AW_VERSION} (${INSTALLED_LOCALREPO}) is already installed; nothing to do."
    echo "  (--force runs every stage again.)"
    exit 0
fi

# Refuse a plan that would remove another version's packages. Needs the
# localrepo to be registered already, so it runs after the deb on a first
# install and here, in advance, when the repository is already there.
check_apt_plan() {
    local plan removed
    plan=$(apt-get -s install "${FULL_PACKAGE}" 2>/dev/null || true)
    removed=$(printf '%s\n' "$plan" | awk '/^Remv / { print $2 }' \
        | grep -E '^(ros-humble|autoware)-.*-[0-9]+-[0-9]+-[0-9]+$' \
        | grep -v -- "-${AW_SUFFIX}\$" || true)
    if [ -n "$removed" ]; then
        echo "  ERROR: installing ${FULL_PACKAGE} would remove packages of another Autoware version:" >&2
        printf '    %s\n' $removed >&2
        echo "  Refusing. The versions are meant to coexist; this is a packaging bug." >&2
        return 1
    fi
    return 0
}

if [ "${DRY_RUN}" -eq 1 ]; then
    echo "  dry run, nothing changed. Would:"
    if [ "${LOCALREPO_STATE}" = current ] || [ "${LOCALREPO_STATE}" = newer ]; then
        echo "    download nothing: ${AW_LOCALREPO_PACKAGE} ${INSTALLED_LOCALREPO} is installed"
    elif [ -f "${TEMP_DEB}" ] && [ ! -f "${TEMP_DEB}.aria2" ]; then
        echo "    use ${TEMP_DEB} (sha256 checked against ${AW_SHA256})"
    else
        echo "    download ${AW_URL}"
        echo "          to ${TEMP_DEB}, sha256 ${AW_SHA256}"
    fi
    if [ "${LOCALREPO_STATE}" = older ]; then
        echo "    sudo ${SHARE}/uninstall-autoware.sh -y   (after the new localrepo deb; keeps the repository)"
    fi
    case "${LOCALREPO_STATE}" in
        current|newer) echo "    keep ${AW_LOCALREPO_PACKAGE} ${INSTALLED_LOCALREPO}" ;;
        *)             echo "    sudo apt install ${TEMP_DEB}" ;;
    esac
    echo "    sudo ${SHARE}/setup-prerequisites.sh --no-ros --non-interactive (+ the NVIDIA flags for ${AW_PLATFORM})"
    echo "    sudo apt install ${FULL_PACKAGE}"
    if [ "${LOCALREPO_STATE}" != absent ]; then
        check_apt_plan && echo "    apt simulation: removes no other Autoware version"
    fi
    exit 0
fi

mkdir -p "${DEB_DOWNLOAD_DIR}"

# Download helper: prefer aria2c (parallel download + inline checksum), then
# fall back to wget, then curl. aria2c is only a speed optimisation, so its
# absence — or failure — is not fatal as long as one fetcher is available.
download_deb() {
    local url="$1" dir="$2" out="$3" sha="$4"
    local dest="${dir}/${out}"

    if command -v aria2c &> /dev/null; then
        echo "  Downloading with aria2c (parallel)..."
        # --continue: pick up an interrupted run from its .aria2 control file
        # rather than starting 2 GB over.
        local args=(--dir="$dir" --out="$out" -x 10 -s 10 -k 1M --continue=true)
        [[ -n "$sha" ]] && args+=(--checksum=sha-256="$sha")
        local rc=0
        aria2c "$url" "${args[@]}" || rc=$?
        if [[ $rc -eq 0 ]]; then
            return 0  # aria2c verified the checksum inline
        fi
        # Exit 7 means aria2c was signalled (SIGINT, SIGTERM or SIGHUP) with
        # the download unfinished: a Ctrl-C, a closed terminal. The bytes on
        # disk are sound and the control file can resume them, so deleting
        # them is the one thing not to do -- that is how 1.9 GB got thrown
        # away and re-fetched before. Stop instead, and let the next run
        # resume.
        if [[ $rc -eq 7 ]]; then
            echo "  aria2c was interrupted before it finished (exit 7)."
            echo "  What it downloaded is kept, with its progress in ${out}.aria2."
            echo "  Re-run this step to resume from where it stopped."
            return 1
        fi
        echo "  aria2c failed (exit ${rc}); falling back to wget/curl..."
        # The control file goes too: left behind without its data file, it
        # would make the next run think a resumable download is in progress.
        rm -f "$dest" "${dest}.aria2"
    fi

    if command -v wget &> /dev/null; then
        echo "  Downloading with wget..."
        wget -O "$dest" "$url" || { echo "  wget failed."; rm -f "$dest"; return 1; }
    elif command -v curl &> /dev/null; then
        echo "  Downloading with curl..."
        curl -fL -o "$dest" "$url" || { echo "  curl failed."; rm -f "$dest"; return 1; }
    else
        echo "Error: need aria2c, wget, or curl to download ${out}, none found."
        return 1
    fi

    # aria2c checks the hash during transfer; the wget/curl path verifies after.
    echo "  Verifying checksum..."
    local actual
    actual=$(sha256sum "$dest" | awk '{print $1}')
    if [[ "$actual" != "$sha" ]]; then
        echo "  ERROR: checksum mismatch for ${dest}"
        echo "  Expected: ${sha}"
        echo "  Actual:   ${actual}"
        rm -f "$dest"
        return 1
    fi
    echo "  Checksum matches."
}

DOWNLOAD_REQUIRED=false
if [[ "${LOCALREPO_STATE}" = current || "${LOCALREPO_STATE}" = newer ]]; then
    echo "  ${AW_LOCALREPO_PACKAGE} ${INSTALLED_LOCALREPO} is installed; no download."
elif [[ -f "${TEMP_DEB}.aria2" ]]; then
    # aria2c deletes its control file when a download completes, so its presence
    # means the last run was interrupted. aria2c preallocates the full size and
    # fills segments in parallel, so such a file has the right length and a
    # valid .deb header while holes remain mid-file: it fails the checksum and
    # used to be refused below as a "possibly custom" build. It is neither.
    echo "  ${AW_DEB} is an interrupted download (found ${AW_DEB}.aria2)."
    if command -v aria2c &> /dev/null; then
        echo "  Resuming it..."
    else
        # Only aria2c can read its control file; wget or curl would append to a
        # preallocated file and corrupt it. Start over.
        echo "  aria2c is not installed to resume it, so starting over..."
        rm -f "$TEMP_DEB" "${TEMP_DEB}.aria2"
    fi
    DOWNLOAD_REQUIRED=true
elif [[ -f "$TEMP_DEB" ]]; then
    echo "  File ${AW_DEB} already exists. Verifying checksum..."
    ACTUAL_SHA256SUM=$(sha256sum "$TEMP_DEB" | awk '{print $1}')
    if [[ "$ACTUAL_SHA256SUM" == "$AW_SHA256" ]]; then
        echo "  Checksum matches. Skipping download."
    else
        echo "--------------------------------------------------------------------------------"
        echo "  ERROR: Checksum mismatch for existing file: ${TEMP_DEB}"
        echo "  Expected SHA256: ${AW_SHA256} (versions.yaml)"
        echo "  Actual SHA256:   ${ACTUAL_SHA256SUM}"
        echo "  The expected value is the one GitHub publishes for the release asset:"
        echo "    gh release view ${AW_RELEASE} -R NEWSLabNTU/autoware-localrepo \\"
        echo "      --json assets --jq '.assets[] | \"\\(.name) \\(.digest)\"'"
        echo "  If it matches, this file is damaged. Delete it and re-run:"
        echo "    rm '${TEMP_DEB}'"
        echo "  Do not edit the checksum to match the file; that disables the check."
        echo "  Not deleted automatically, in case it is a deliberate local build."
        echo "--------------------------------------------------------------------------------"
        exit 1
    fi
else
    echo "  ${AW_DEB} not found. Downloading ${AW_URL}..."
    DOWNLOAD_REQUIRED=true
fi

if [[ "$DOWNLOAD_REQUIRED" == "true" ]]; then
    download_deb "${AW_URL}" "${DEB_DOWNLOAD_DIR}" "${AW_DEB}" "${AW_SHA256}"
fi

# 1.5.0-1's newslab-ros-config overwrite (--force-overwrite for
# 10-cyclone-max.conf and multicast-lo.service) is gone: those two files were
# unsuffixed only in 1.5.0-1, which the catalogue no longer installs. From
# 1.5.0-2 on they are 10-cyclone-max-<suffix>.conf and
# multicast-lo-<suffix>.service and collide with nothing. A file conflict now
# is an error worth stopping for.

# A run that died mid-install leaves packages unpacked but not configured, and
# from then on EVERY apt install on the machine -- including the one at the top
# of setup-prerequisites.sh -- first tries to finish the broken set. Finish it
# here, before anything else calls apt, so the failure shows as itself.
if [ -n "$(sudo dpkg --audit 2>/dev/null)" ]; then
    echo "  dpkg reports an interrupted install; completing it first..."
    sudo apt-get install -f -y
fi

echo "  Installing the Autoware ${AW_VERSION} localrepo..."
case "${LOCALREPO_STATE}" in
    current|newer)
        # A newer localrepo can be installed on a machine provisioned from a
        # newer release; there is no reason to downgrade it to this asset.
        echo "  Keeping ${AW_LOCALREPO_PACKAGE} ${INSTALLED_LOCALREPO}." ;;
    *)
        sudo apt install -y "$TEMP_DEB" ;;
esac
sudo apt update

if [ "${LOCALREPO_STATE}" = older ]; then
    # Same package names and versions as the old revision's: remove them so the
    # install below takes this revision's. Only this version is touched, and
    # without --purge the repository just installed stays.
    echo "  Removing the ${INSTALLED_LOCALREPO} packages before reinstalling from ${AW_RELEASE}..."
    sudo "${SHARE}/uninstall-autoware.sh" -y
fi

# Run setup-prerequisites.sh, this version's copy.
#
# --non-interactive (1.5.0-3 and 2.1.0, both platforms) answers every question
# it is not given a flag for with "no" and skips the final "Proceed?" prompt,
# so the flags below are the whole answer. They differ by platform:
#
#   amd64 (ubuntu2204)  --all-nvidia / --no-nvidia: CUDA, cuDNN, TensorRT and
#                       SpConv together. Decided from what the machine has:
#                       already present -> --no-nvidia (nothing to install, no
#                       SpConv built for another CUDA); missing -> --all-nvidia.
#                       Override with AUTOWARE_PREREQ_NVIDIA=y|n.
#   arm64 (jetpack62)   JetPack provides CUDA, cuDNN and TensorRT, so there is
#                       no NVIDIA question; --spconv / --no-spconv only, and
#                       --all-nvidia would be "Unknown option". SpConv is not
#                       optional: autoware_tensorrt_plugins links libspconv.so.
#                       Override with AUTOWARE_PREREQ_SPCONV=n.
#
# ROS 2: the ros2 step installs it before this one, so --no-ros, and the guard
# keeps that promise honest. AUTOWARE_PREREQ_ROS=y lets this script install it.
PREREQ="${SHARE}/setup-prerequisites.sh"
if [ -f "${PREREQ}" ]; then
    PREREQ_ARGS=(--non-interactive)
    if [ "${AUTOWARE_PREREQ_ROS:-n}" = "y" ]; then
        PREREQ_ARGS+=(--install-ros)
    else
        if [ ! -f /opt/ros/humble/setup.bash ]; then
            echo "ROS 2 Humble is not installed, and this step is configured not to" >&2
            echo "install it (AUTOWARE_PREREQ_ROS is not 'y')." >&2
            echo "Run the ros2 step first:  ./setup.sh --only ros2" >&2
            exit 1
        fi
        PREREQ_ARGS+=(--no-ros)
    fi
    if [[ "${AW_PLATFORM}" == jetpack* ]]; then
        if [ "${AUTOWARE_PREREQ_SPCONV:-y}" = "y" ]; then
            PREREQ_ARGS+=(--spconv)
        else
            PREREQ_ARGS+=(--no-spconv)
        fi
    else
        if [ -n "${AUTOWARE_PREREQ_NVIDIA:-}" ]; then
            nvidia_wanted="$AUTOWARE_PREREQ_NVIDIA"
        elif command -v nvcc >/dev/null 2>&1 && \
             ls /usr/lib/*-linux-gnu/libnvinfer.so* >/dev/null 2>&1; then
            echo "  CUDA and TensorRT are already installed; skipping the NVIDIA step."
            nvidia_wanted=n
        else
            echo "  CUDA or TensorRT missing; installing the full NVIDIA set."
            nvidia_wanted=y
        fi
        if [ "$nvidia_wanted" = "y" ]; then
            PREREQ_ARGS+=(--all-nvidia)
        else
            PREREQ_ARGS+=(--no-nvidia)
        fi
    fi
    echo "  Running ${PREREQ} ${PREREQ_ARGS[*]}..."
    sudo "${PREREQ}" "${PREREQ_ARGS[@]}"
else
    echo "  ERROR: ${PREREQ} not found; the localrepo deb did not install it." >&2
    exit 1
fi

echo "  Updating apt cache after the prerequisites..."
sudo apt update

# If time-daemon is not provided by any package, install chrony: autoware-full
# depends on it.
if ! apt-cache search --names-only '^time-daemon$' | grep -q 'time-daemon'; then
    echo "  'time-daemon' not found in any package. Installing 'chrony' as a replacement."
    sudo apt install -y chrony
fi

check_apt_plan || exit 1
echo "  Installing ${FULL_PACKAGE}..."
sudo apt install -y "${FULL_PACKAGE}"

for v in "${OTHERS[@]}"; do
    [ -f "/opt/autoware/${v}/setup.bash" ] \
        || echo "  WARNING: Autoware ${v} lost /opt/autoware/${v}/setup.bash during this install." >&2
done

echo "✓ Autoware ${AW_VERSION} (localrepo ${AW_RELEASE}) installed."
