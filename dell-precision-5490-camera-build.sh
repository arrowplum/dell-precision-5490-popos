#!/usr/bin/env bash
# Build and install the Intel IPU6 camera userspace stack from source on
# Pop!_OS 24.04 (Ubuntu noble), for a Dell Precision 5490 with the OV01A10
# sensor on Meteor Lake (IPU_VER=ipu6epmtl).
#
# Plan A (Canonical OEM apt archive) is gated, so we build from Intel's GitHub:
#   - intel/ipu6-camera-bins  (proprietary binaries: firmware, ISP libs)
#   - intel/ipu6-camera-hal   (HAL on top of the bins)
#   - intel/icamerasrc        (GStreamer source element for the HAL)
#
# Everything goes under /usr/local, so removal is a matter of deleting those
# files plus the source tree. The system libcamera 0.2.0 is left alone.
#
# After this completes you should be able to:
#   gst-launch-1.0 icamerasrc ! videoconvert ! autovideosink
#
# Apps that only speak v4l2 (Slack, Zoom, Chrome before PipeWire camera
# portal, etc.) still need a v4l2loopback bridge on top. That step is
# documented at the end of this script's output, not run automatically.
#
# Run as: sudo ./dell-precision-5490-camera-build.sh
# Roll back with: sudo ./dell-precision-5490-camera-build.sh --uninstall

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_PREFIX="[camera-build]"
# /usr to match the bins' shipped pkg-config files (prefix=/usr) and upstream
# build instructions for HAL and icamerasrc. Uninstall removes only the very
# specific filenames the Intel stack ships, so this is safe.
PREFIX="/usr"

# Resolve the invoking user's ~/src so we don't clone into /root/src.
INVOKING_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER}")}"
if [[ -z "${INVOKING_USER}" || "${INVOKING_USER}" == "root" ]]; then
    echo "[camera-build] ERROR: could not determine the invoking non-root user. Run via sudo as your normal user." >&2
    exit 1
fi
INVOKING_HOME="$(getent passwd "${INVOKING_USER}" | cut -d: -f6)"
[[ -d "${INVOKING_HOME}" ]] || { echo "[camera-build] ERROR: home dir for ${INVOKING_USER} (${INVOKING_HOME}) not found." >&2; exit 1; }
SRC_DIR="${INVOKING_HOME}/src/ipu6-build"
IPU_VER="ipu6epmtl"   # Meteor Lake-P EP
OEM_SOURCES_FILE="/etc/apt/sources.list.d/canonical-oem-ipu6.sources"

# Pin to known-good tags / branches. These are conservative defaults; bump as needed.
BINS_REPO="https://github.com/intel/ipu6-camera-bins.git"
BINS_BRANCH="main"        # main carries bins for TGL/ADL/RPL/MTL together
HAL_REPO="https://github.com/intel/ipu6-camera-hal.git"
HAL_BRANCH="main"
ICAM_REPO="https://github.com/intel/icamerasrc.git"
ICAM_BRANCH="icamerasrc_slim_api"   # the branch used with current HAL

log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root. Try: sudo $0 $*"

# ---------------------------------------------------------------------------
# Uninstall path.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    log "Removing installed files."
    # Files installed by ipu6-camera-bins (copied into /usr/include and /usr/lib).
    rm -rf "/usr/include/ipu6epmtl" "/usr/include/ipu6"
    rm -f /usr/lib/x86_64-linux-gnu/libipu6epmtl*.so* \
          /usr/lib/x86_64-linux-gnu/libgcss*.so* \
          /usr/lib/x86_64-linux-gnu/libbroxton_ia_pal*.so* 2>/dev/null || true
    # HAL + icamerasrc went to /usr/local.
    for d in lib lib/x86_64-linux-gnu lib64 include/libcamhal share/pkgconfig; do
        rm -rf "${PREFIX}/${d}/libcamhal"* "${PREFIX}/${d}/icamerasrc"* 2>/dev/null || true
    done
    rm -rf "${SRC_DIR}"
    ldconfig
    log "Uninstalled. Restart pipewire / gstreamer apps to forget the plugin."
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 0: clean up the failed Plan A apt source (harmless if already gone).
# ---------------------------------------------------------------------------
if [[ -f "${OEM_SOURCES_FILE}" ]]; then
    log "Step 0: removing the Canonical OEM apt source from Plan A (it is gated and unreachable)."
    rm -f "${OEM_SOURCES_FILE}"
    apt-get update -qq || true
fi

# ---------------------------------------------------------------------------
# Step 1: install build dependencies.
# ---------------------------------------------------------------------------
log "Step 1: installing build dependencies."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    git \
    build-essential \
    cmake \
    pkg-config \
    autoconf \
    automake \
    libtool \
    libexpat1-dev \
    libdrm-dev \
    libudev-dev \
    libssl-dev \
    libtbb-dev \
    libva-dev \
    libgstreamer1.0-dev \
    libgstreamer-plugins-base1.0-dev \
    libgstreamer-plugins-bad1.0-dev \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly

# ---------------------------------------------------------------------------
# Step 2: fetch source trees as the invoking user (so the working tree is owned
# by you, not root).
# ---------------------------------------------------------------------------
log "Step 2: fetching source into ${SRC_DIR} as ${INVOKING_USER}."
install -d -o "${INVOKING_USER}" -g "${INVOKING_USER}" "${INVOKING_HOME}/src"
install -d -o "${INVOKING_USER}" -g "${INVOKING_USER}" "${SRC_DIR}"

fetch_repo() {
    local url="$1" branch="$2" dest="$3"
    if [[ -d "${dest}/.git" ]]; then
        log "  -> updating ${dest}"
        sudo -u "${INVOKING_USER}" -H git -C "${dest}" fetch --depth 1 origin "${branch}" && \
            sudo -u "${INVOKING_USER}" -H git -C "${dest}" checkout "${branch}" && \
            sudo -u "${INVOKING_USER}" -H git -C "${dest}" reset --hard "origin/${branch}"
    else
        log "  -> cloning ${url} (${branch}) into ${dest}"
        sudo -u "${INVOKING_USER}" -H git clone --depth 1 --branch "${branch}" "${url}" "${dest}"
    fi
}

fetch_repo "${BINS_REPO}" "${BINS_BRANCH}" "${SRC_DIR}/ipu6-camera-bins"
fetch_repo "${HAL_REPO}"  "${HAL_BRANCH}"  "${SRC_DIR}/ipu6-camera-hal"
fetch_repo "${ICAM_REPO}" "${ICAM_BRANCH}" "${SRC_DIR}/icamerasrc"

# ---------------------------------------------------------------------------
# Step 3: install camera-bins (just copies files into the system).
# ---------------------------------------------------------------------------
log "Step 3: installing ipu6-camera-bins for ${IPU_VER} (per upstream README)."
BINS_DIR="${SRC_DIR}/ipu6-camera-bins"
if [[ ! -d "${BINS_DIR}/lib" || ! -d "${BINS_DIR}/include" ]]; then
    warn "expected ${BINS_DIR}/{lib,include} not present. Listing:"
    ls "${BINS_DIR}" >&2 || true
    die "ipu6-camera-bins layout is not recognized."
fi

# Headers and pkgconfig go to /usr (HAL build looks there).
mkdir -p /usr/include /usr/lib/pkgconfig
cp -r "${BINS_DIR}/include/." /usr/include/
if [[ -d "${BINS_DIR}/lib/pkgconfig" ]]; then
    cp -r "${BINS_DIR}/lib/pkgconfig/." /usr/lib/pkgconfig/
fi

# Libraries: copy both shared (.so*) and static (.a) libs, and synthesize the
# unversioned `.so` symlinks the README requires.
# Note: install to /usr/lib (matches the bins' .pc files which use libdir=${prefix}/lib),
# not the multiarch dir. The linker still finds them via the standard search path.
log "  copying lib/*.so* and lib/*.a, creating unversioned symlinks."
mkdir -p /usr/lib
shopt -s nullglob
for src in "${BINS_DIR}"/lib/lib*.so* "${BINS_DIR}"/lib/lib*.a; do
    [[ -e "${src}" ]] || continue
    base="$(basename "${src}")"
    cp -P "${src}" /usr/lib/
    # Create the unversioned symlink: foo.so.0 -> foo.so
    if [[ "${base}" == *.so.* ]]; then
        unversioned="${base%.so.*}.so"
        ln -sf "${base}" "/usr/lib/${unversioned}"
    fi
done
shopt -u nullglob

# IPU6 firmware: the kernel package already ships ipu6epmtl_fw.bin under
# /lib/firmware/intel/ipu/. Don't overwrite the working kernel firmware. If the
# HAL later complains about firmware mismatch, we can swap then.
if [[ -d "${BINS_DIR}/lib/firmware/intel/ipu" ]]; then
    log "  bins repo ships firmware too; leaving system firmware in /lib/firmware/intel/ipu alone (kernel already loads it)."
fi

ldconfig

# ---------------------------------------------------------------------------
# Step 4: build and install ipu6-camera-hal.
# ---------------------------------------------------------------------------
log "Step 4: building ipu6-camera-hal (this is the long step, several minutes)."
# Invocation taken verbatim from the upstream HAL README, which is multi-IPU.
# IPU_VERSIONS picks the right per-IPU bins automatically at configure time.
HAL_BUILD="${SRC_DIR}/ipu6-camera-hal/build"
mkdir -p "${HAL_BUILD}"
cd "${HAL_BUILD}"
cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_CAMHAL_ADAPTOR=ON \
    -DBUILD_CAMHAL_PLUGIN=ON \
    -DIPU_VERSIONS="ipu6;ipu6ep;ipu6epmtl" \
    -DUSE_PG_LITE_PIPE=ON \
    ..
make -j"$(nproc)"
make install
ldconfig

# ---------------------------------------------------------------------------
# Step 5: build and install icamerasrc (GStreamer source plugin).
# ---------------------------------------------------------------------------
log "Step 5: building icamerasrc (GStreamer plugin)."
cd "${SRC_DIR}/icamerasrc"
export PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
# Required env per icamerasrc README so the plugin links against the slim HAL
# adaptor variant we built above.
export CHROME_SLIM_CAMHAL=ON
# autogen.sh upstream is buggy: it ignores its CLI args and forces
# `./configure --prefix=/usr`. Run it, then explicitly re-configure with the
# flags we actually want (gstdrmformat for DMA buffer support on
# gstreamer >= 1.22).
./autogen.sh
./configure --prefix="${PREFIX}" --enable-gstdrmformat=yes
make -j"$(nproc)"
make install
ldconfig

# ---------------------------------------------------------------------------
# Step 6: register the GStreamer plugin in the system search path.
# ---------------------------------------------------------------------------
log "Step 6: making the icamerasrc plugin findable system-wide."
PLUGIN_FILE="$(find "${PREFIX}/lib" -name 'libgsticamerasrc.so' 2>/dev/null | head -1)"
if [[ -n "${PLUGIN_FILE}" ]]; then
    log "  found ${PLUGIN_FILE}"
    # Tell GStreamer about /usr/local plugin dir for all user sessions.
    cat > /etc/profile.d/icamerasrc.sh <<EOF
# Added by ${SCRIPT_NAME}. Lets GStreamer find icamerasrc and HAL libs.
export GST_PLUGIN_PATH="\${GST_PLUGIN_PATH:+\$GST_PLUGIN_PATH:}${PREFIX}/lib/x86_64-linux-gnu/gstreamer-1.0"
export LD_LIBRARY_PATH="\${LD_LIBRARY_PATH:+\$LD_LIBRARY_PATH:}${PREFIX}/lib:${PREFIX}/lib/x86_64-linux-gnu"
EOF
    chmod 644 /etc/profile.d/icamerasrc.sh
else
    warn "did not find libgsticamerasrc.so under ${PREFIX}. Skipping system-wide plugin registration."
fi

# ---------------------------------------------------------------------------
# Step 7: quick smoke test.
# ---------------------------------------------------------------------------
log "Step 7: smoke test via gst-inspect."
TARGET_USER="${SUDO_USER:-$(logname 2>/dev/null || true)}"
if [[ -n "${TARGET_USER}" && "${TARGET_USER}" != "root" ]]; then
    sudo -u "${TARGET_USER}" \
        GST_PLUGIN_PATH="${PREFIX}/lib/x86_64-linux-gnu/gstreamer-1.0" \
        LD_LIBRARY_PATH="${PREFIX}/lib:${PREFIX}/lib/x86_64-linux-gnu" \
        gst-inspect-1.0 icamerasrc 2>&1 | head -20 | sed "s/^/  /"
fi

cat <<TIPS

${LOG_PREFIX} Build finished.

Test the camera (replace 'autovideosink' with 'glimagesink' if 'auto' fails):

  source /etc/profile.d/icamerasrc.sh
  gst-launch-1.0 icamerasrc ! video/x-raw,format=NV12,width=1280,height=720 \\
      ! videoconvert ! autovideosink

If that shows a live preview, the HAL stack is good.

Browsers and meeting apps (Slack, Zoom, Firefox, Chrome) talk v4l2, NOT
GStreamer. To bridge icamerasrc into a fake /dev/video* node those apps can
see, install v4l2loopback:

  sudo apt-get install -y v4l2loopback-dkms v4l2loopback-utils
  sudo modprobe v4l2loopback devices=1 video_nr=98 \\
      card_label="IPU6 Bridge" exclusive_caps=1

then keep a pipeline alive that copies frames into it:

  source /etc/profile.d/icamerasrc.sh
  gst-launch-1.0 icamerasrc ! video/x-raw,format=NV12,width=1280,height=720 \\
      ! videoconvert ! v4l2sink device=/dev/video98

(For long-term use, wrap that gst-launch in a systemd --user unit.)

Roll back the whole stack with:

  sudo ${SCRIPT_NAME} --uninstall
TIPS
