#!/usr/bin/env bash
# Bridge the IPU6 internal camera (OV01A10) into a fake UVC-like /dev/video98
# device via v4l2loopback. Works without PSYS by reading raw Bayer directly
# from the ISYS capture node /dev/video32, software-debayering in GStreamer,
# and pushing the result into v4l2loopback.
#
# QUALITY CAVEATS
# * No PSYS means no auto-exposure / auto-white-balance / denoising / lens
#   shading correction. Expect a usable but dim and green-tinted image.
# * The script sets static exposure / gain / vblank values suitable for
#   typical indoor desk lighting. Tweak the SENSOR_* vars below if needed.
# * Frame rate is capped by sensor exposure; default settings give ~30-60 fps.
#
# Run as: sudo ./dell-precision-5490-camera-bridge.sh
# Roll back with: sudo ./dell-precision-5490-camera-bridge.sh --uninstall

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
LOG_PREFIX="[camera-bridge]"
log()  { echo "${LOG_PREFIX} $*"; }
warn() { echo "${LOG_PREFIX} WARN: $*" >&2; }
die()  { echo "${LOG_PREFIX} ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root. Try: sudo $0 $*"

INVOKING_USER="${SUDO_USER:-$(logname 2>/dev/null || echo "${USER}")}"
[[ -n "${INVOKING_USER}" && "${INVOKING_USER}" != "root" ]] || die "could not determine the invoking non-root user. Run via sudo as your normal user."
INVOKING_HOME="$(getent passwd "${INVOKING_USER}" | cut -d: -f6)"
USER_UID="$(id -u "${INVOKING_USER}")"

# ---------------------------------------------------------------------------
# Tunables. Edit these and re-run if image quality needs tweaking.
# ---------------------------------------------------------------------------
SENSOR_SUBDEV="/dev/v4l-subdev7"   # OV01A10 sensor sub-device
CAPTURE_DEV="/dev/video32"          # ISYS capture endpoint linked from IVSC CSI
LOOPBACK_DEV="/dev/video98"
LOOPBACK_LABEL="IPU6 Bridge"
WIDTH=1280
HEIGHT=798                          # Sensor capture height (IVSC crop output)
OUT_WIDTH=1280                      # What we expose to v4l2loopback consumers
OUT_HEIGHT=720                      # Standard 16:9 height; PipeWire/cheese rejects non-standard
BAYER_FORMAT="grbg10le"             # GStreamer caps; matches v4l2 BA10
FRAMERATE=30                        # target output fps
SENSOR_EXPOSURE=500                 # in sensor lines; max=888 at default vblank
SENSOR_GAIN=8192                    # analogue gain, default 256 (=1.0x), max 65535
SENSOR_DIGITAL_GAIN=4096            # default 1024 (=1.0x), max 262143
SENSOR_VBLANK=96                    # default 96; larger = lower fps + longer exposure budget

FRAME_BYTES=$(( WIDTH * HEIGHT * 2 ))
LOOPBACK_VIDEO_NR="${LOOPBACK_DEV##*video}"

# ---------------------------------------------------------------------------
# Uninstall path.
# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--uninstall" ]]; then
    log "Stopping and disabling the user streaming service."
    sudo -u "${INVOKING_USER}" \
        XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
        systemctl --user disable --now camera-bridge.service 2>/dev/null || true
    rm -f "${INVOKING_HOME}/.config/systemd/user/camera-bridge.service"
    rm -f "${INVOKING_HOME}/.config/wireplumber/wireplumber.conf.d/51-ipu6-isys-disable.conf"
    rm -f /etc/modprobe.d/zz-v4l2loopback-ipu6.conf
    rm -f /etc/modules-load.d/zz-v4l2loopback-ipu6.conf
    rm -f /usr/local/bin/camera-bridge-ipu6
    modprobe -r v4l2loopback 2>/dev/null || true
    apt-get remove --purge -y v4l2loopback-dkms v4l2loopback-utils 2>/dev/null || true
    apt-get autoremove --purge -y || true
    log "Uninstalled. Camera state returns to ISYS-only on next reboot."
    exit 0
fi

# ---------------------------------------------------------------------------
# Preflight.
# ---------------------------------------------------------------------------
[[ -c "${CAPTURE_DEV}" ]] || die "${CAPTURE_DEV} does not exist; the ISYS topology is not what we expect."
[[ -c "${SENSOR_SUBDEV}" ]] || die "${SENSOR_SUBDEV} does not exist; sensor sub-device path may have changed."
command -v gst-launch-1.0 >/dev/null || die "gst-launch-1.0 not on PATH. Install gstreamer1.0-tools."
command -v v4l2-ctl >/dev/null || die "v4l2-ctl not on PATH. Install v4l-utils."

# ---------------------------------------------------------------------------
# Step 1: install v4l2loopback (DKMS).
# ---------------------------------------------------------------------------
log "Step 1: installing v4l2loopback-dkms + v4l2loopback-utils."
DEBIAN_FRONTEND=noninteractive apt-get install -y v4l2loopback-dkms v4l2loopback-utils
log "  DKMS status after install:"
dkms status v4l2loopback 2>&1 | sed "s/^/    /"

# ---------------------------------------------------------------------------
# Step 2: configure modprobe so v4l2loopback loads with the right options.
# ---------------------------------------------------------------------------
log "Step 2: writing modprobe and modules-load config for v4l2loopback."
cat > /etc/modprobe.d/zz-v4l2loopback-ipu6.conf <<EOF
# Added by ${SCRIPT_NAME}. One virtual device at ${LOOPBACK_DEV}.
# This file is prefixed "zz-" so it sorts after Pop's v4l2loopback.conf and
# any v4l2-relayd config; modprobe's last-write-wins behavior on scalar params
# means we must come last to actually take effect.
# exclusive_caps=1 is REQUIRED for Chromium-based apps (Slack, Chrome,
# Electron) to enumerate the device. Without it, Chromium sees both
# Capture and Output caps and refuses the device as ambiguous.
# max_buffers=8 is needed for v4l2sink's MMAP bufferpool to activate;
# default of 2 is too few.
options v4l2loopback devices=1 video_nr=${LOOPBACK_VIDEO_NR} card_label="${LOOPBACK_LABEL}" exclusive_caps=1 max_buffers=8
EOF
echo "v4l2loopback" > /etc/modules-load.d/zz-v4l2loopback-ipu6.conf
# Clean up the old, mis-sorted file from an earlier run of this script.
rm -f /etc/modprobe.d/v4l2loopback-ipu6.conf /etc/modules-load.d/v4l2loopback-ipu6.conf

# WirePlumber rule: hide the dozens of raw IPU6 ISYS subdev nodes from PipeWire's
# camera list. Without this, PipeWire-using apps (Firefox PipeWire mode, cheese)
# see /dev/video0..47 as separate "ipu6 (V4L2)" cameras that don't produce frames.
log "  installing WirePlumber rule to hide raw ISYS endpoints from PipeWire's camera list."
WP_DIR="${INVOKING_HOME}/.config/wireplumber/wireplumber.conf.d"
install -d -o "${INVOKING_USER}" -g "${INVOKING_USER}" "${INVOKING_HOME}/.config" "${INVOKING_HOME}/.config/wireplumber" "${WP_DIR}"
cat > "${WP_DIR}/51-ipu6-isys-disable.conf" <<'WPEOF'
# Hide raw IPU6 ISYS subdev nodes from PipeWire's camera list. These show up as
# "ipu6 (V4L2)" via /dev/video0..47 and never produce usable frames; only the
# /dev/video98 v4l2loopback ("IPU6 Bridge") is a real camera.
monitor.v4l2.rules = [
  {
    matches = [
      {
        node.nick = "ipu6"
      }
    ]
    actions = {
      update-props = {
        node.disabled = true
      }
    }
  }
]
WPEOF
chown "${INVOKING_USER}:${INVOKING_USER}" "${WP_DIR}/51-ipu6-isys-disable.conf"

log "  reloading v4l2loopback (stops bridge service first so the module isn't held)."
sudo -u "${INVOKING_USER}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user stop camera-bridge.service 2>/dev/null || true
# Kill any leftover v4l2-ctl/gst-launch from previous restart loops.
pkill -f "v4l2-ctl -d ${CAPTURE_DEV} --stream" 2>/dev/null || true
pkill -f "gst-launch.*v4l2sink.*${LOOPBACK_DEV}" 2>/dev/null || true
sleep 1
modprobe -r v4l2loopback 2>/dev/null || true
modprobe v4l2loopback || die "modprobe v4l2loopback failed. Check DKMS build state."
sleep 1
[[ -c "${LOOPBACK_DEV}" ]] || die "${LOOPBACK_DEV} not created. Check 'lsmod | grep v4l2loopback' and dkms status."
log "  ${LOOPBACK_DEV} created."

# ---------------------------------------------------------------------------
# Step 3: write a launcher script the systemd service will exec.
# ---------------------------------------------------------------------------
LAUNCHER="/usr/local/bin/camera-bridge-ipu6"
log "Step 3: installing launcher at ${LAUNCHER}."
cat > "${LAUNCHER}" <<EOF
#!/usr/bin/env bash
# Stream raw Bayer from ${CAPTURE_DEV} into ${LOOPBACK_DEV} as YUY2.
# Generated by ${SCRIPT_NAME}.
set -euo pipefail

# Apply sensor settings. These reset whenever streaming stops, so we reapply
# every time the service starts.
v4l2-ctl -d ${SENSOR_SUBDEV} -c vertical_blanking=${SENSOR_VBLANK} || true
v4l2-ctl -d ${SENSOR_SUBDEV} -c exposure=${SENSOR_EXPOSURE} || true
v4l2-ctl -d ${SENSOR_SUBDEV} -c analogue_gain=${SENSOR_GAIN} || true
v4l2-ctl -d ${SENSOR_SUBDEV} -c digital_gain=${SENSOR_DIGITAL_GAIN} || true

# IVSC warm-up: icamerasrc opens libcamhal which initializes IVSC + IPU6 CSI2
# pads as a side effect, even though icamerasrc itself then crashes opening
# PSYS (which we don't have on kernel 6.18). The IVSC init persists after the
# crash. Without this step, STREAMON on ${CAPTURE_DEV} fails with "Link has
# been severed" because IVSC pad0 stays at Y8/1x1.
# The errors printed by icamerasrc are EXPECTED. Do not investigate them.
timeout 3 gst-launch-1.0 icamerasrc ! 'video/x-raw,format=NV12,width=1280,height=720' ! fakesink 2>/dev/null || true

# Force the capture node format. This must match upstream sub-devices.
v4l2-ctl -d ${CAPTURE_DEV} --set-fmt-video=width=${WIDTH},height=${HEIGHT},pixelformat=BA10

# Stream forever (count=0). Pipe through GStreamer to debayer and push to
# v4l2loopback. Use a named pipe so v4l2-ctl and gst-launch are decoupled.
FIFO="\$(mktemp -u /tmp/camera-bridge.XXXXXX.fifo)"
mkfifo "\$FIFO"
trap 'rm -f "\$FIFO"; kill 0' EXIT

v4l2-ctl -d ${CAPTURE_DEV} --stream-mmap=8 --stream-count=0 --stream-to="\$FIFO" &
CAP_PID=\$!
sleep 0.3

exec gst-launch-1.0 -q \
    filesrc location="\$FIFO" blocksize=${FRAME_BYTES} \
    ! "video/x-bayer,format=${BAYER_FORMAT},width=${WIDTH},height=${HEIGHT},framerate=${FRAMERATE}/1,interlace-mode=progressive" \
    ! bayer2rgb \
    ! videoconvert \
    ! videocrop top=39 bottom=39 \
    ! videoconvert \
    ! "video/x-raw,format=YUY2,width=${OUT_WIDTH},height=${OUT_HEIGHT},framerate=${FRAMERATE}/1,interlace-mode=progressive" \
    ! v4l2sink device=${LOOPBACK_DEV} sync=false io-mode=mmap
EOF
chmod +x "${LAUNCHER}"

# ---------------------------------------------------------------------------
# Step 4: install the systemd --user unit so the bridge auto-starts on login.
# ---------------------------------------------------------------------------
log "Step 4: installing systemd --user unit for ${INVOKING_USER}."
USER_UNIT_DIR="${INVOKING_HOME}/.config/systemd/user"
install -d -o "${INVOKING_USER}" -g "${INVOKING_USER}" "${USER_UNIT_DIR}"
cat > "${USER_UNIT_DIR}/camera-bridge.service" <<EOF
[Unit]
Description=IPU6 raw-Bayer to v4l2loopback bridge (${LOOPBACK_DEV})
After=graphical-session.target wireplumber.service
Wants=wireplumber.service

[Service]
Type=simple
ExecStart=${LAUNCHER}
# After the writer is producing frames, restart wireplumber so it re-enumerates
# /dev/video98 and tags it as Video/Source (Camera). Without this, PipeWire
# saw v4l2loopback before the writer attached and classified it as
# Video Output only, hiding it from Firefox / PipeWire-using apps.
ExecStartPost=/bin/sh -c 'sleep 3; systemctl --user restart wireplumber'
Restart=on-failure
RestartSec=2s
# Keep one frame's worth of margin; ISYS streaming is throughput-sensitive.
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=0

[Install]
WantedBy=default.target
EOF
chown "${INVOKING_USER}:${INVOKING_USER}" "${USER_UNIT_DIR}/camera-bridge.service"

# ---------------------------------------------------------------------------
# Step 5: enable + start the user service.
# ---------------------------------------------------------------------------
log "Step 5: starting the bridge service as ${INVOKING_USER}."
sudo -u "${INVOKING_USER}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user daemon-reload
sudo -u "${INVOKING_USER}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user enable --now camera-bridge.service

sleep 3
log "Step 6: verifying."
log "  Service status:"
sudo -u "${INVOKING_USER}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user --no-pager status camera-bridge.service 2>&1 | sed "s/^/    /" | head -20

log "  ${LOOPBACK_DEV} formats:"
v4l2-ctl -d "${LOOPBACK_DEV}" --list-formats-ext 2>&1 | sed "s/^/    /" | head -10

cat <<TIPS

${LOG_PREFIX} Done.

Use the camera by selecting "${LOOPBACK_LABEL}" as the webcam in any app
(Slack/Zoom/Chrome/Firefox/cheese).

To preview locally:
  gst-launch-1.0 v4l2src device=${LOOPBACK_DEV} ! videoconvert ! autovideosink

To stop or troubleshoot:
  systemctl --user status camera-bridge.service
  systemctl --user stop camera-bridge.service
  journalctl --user -u camera-bridge.service -f

Tunable image settings live in the env vars near the top of this script.
Edit and re-run to apply (no need to --uninstall first).

Roll back with: sudo ${SCRIPT_NAME} --uninstall
TIPS
