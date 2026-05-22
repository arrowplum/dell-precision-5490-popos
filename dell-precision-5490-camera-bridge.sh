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
# OPERATING MODEL
# The bridge is installed but NOT enabled at boot. While running, it streams
# the sensor continuously, which keeps the camera privacy LED lit and uses
# about a quarter of a CPU core. Start it when you want a webcam, stop it
# when you do not:
#
#   systemctl --user start camera-bridge.service   # turn camera on
#   systemctl --user stop  camera-bridge.service   # turn it back off
#
# Two convenience pieces also get installed:
#   * A systemd-suspend hook at /usr/lib/systemd/system-sleep/ipu6-bridge-stop
#     auto-stops the bridge before the system suspends, so closing the lid
#     with the camera still running is safe (the bridge does not auto-restart
#     on resume).
#   * A tray indicator at /usr/local/bin/ipu6-bridge-indicator, autostarted
#     for the invoking user, shows current ON/OFF state and offers
#     start/stop/status from a menu.
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
SENSOR_EXPOSURE=800                 # in sensor lines; max=888 at default vblank
SENSOR_GAIN=8192                    # analogue gain, default 256 (=1.0x), max 65535
SENSOR_DIGITAL_GAIN=8192            # default 1024 (=1.0x), max 262143
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
    rm -f "${INVOKING_HOME}/.config/wireplumber/wireplumber.conf.d/52-ipu6-bridge-classify.conf"
    rm -f "${INVOKING_HOME}/.config/autostart/ipu6-bridge-indicator.desktop"
    rm -f /etc/modprobe.d/zz-v4l2loopback-ipu6.conf
    rm -f /etc/modules-load.d/zz-v4l2loopback-ipu6.conf
    rm -f /etc/udev/rules.d/70-ipu6-bridge.rules
    rm -f /usr/lib/systemd/system-sleep/ipu6-bridge-stop
    udevadm control --reload-rules 2>/dev/null || true
    pkill -f /usr/local/bin/ipu6-bridge-indicator 2>/dev/null || true
    rm -f /usr/local/bin/ipu6-bridge-indicator
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

# WirePlumber rule: force /dev/video98 to be classified as a Video/Source.
# Without this rule, wireplumber reads the loopback's initial v4l2 caps as
# ":video_output:" (before any writer attaches) and refuses to create a
# source node, so PipeWire-using apps can't see the camera. Combined with
# the udev rule below, this lets the bridge launcher nudge wireplumber to
# re-evaluate the device without restarting wireplumber (which would drop
# every audio stream as a side effect).
log "  installing WirePlumber rule to classify ${LOOPBACK_DEV} as Video/Source."
cat > "${WP_DIR}/52-ipu6-bridge-classify.conf" <<WPEOF
monitor.v4l2.rules = [
  {
    matches = [
      { api.v4l2.path = "${LOOPBACK_DEV}" }
    ]
    actions = {
      update-props = {
        device.capabilities = ":video_capture:"
        media.class = "Video/Source"
      }
    }
  }
]
WPEOF
chown "${INVOKING_USER}:${INVOKING_USER}" "${WP_DIR}/52-ipu6-bridge-classify.conf"

# udev rule: make the sysfs uevent file for ${LOOPBACK_DEV} writable by the
# "video" group. With this in place, the user-level bridge service can write
# "change" into that file and trigger wireplumber to re-evaluate the loopback
# (which is how we get a Video/Source node without restarting wireplumber).
log "  installing udev rule to make ${LOOPBACK_DEV}'s uevent file group-writable."
cat > /etc/udev/rules.d/70-ipu6-bridge.rules <<UDEOF
# Make /sys/.../${LOOPBACK_DEV##/dev/}/uevent writable by the "video" group so the
# camera bridge user service can nudge wireplumber to re-evaluate the loopback
# without restarting wireplumber. The uevent file is already owned root:video;
# we just need +w on group.
SUBSYSTEM=="video4linux", KERNEL=="${LOOPBACK_DEV##/dev/}", ACTION=="add|change", RUN+="/bin/chmod g+w /sys%p/uevent"
UDEOF
udevadm control --reload-rules
# Apply to the device that's already present so a reboot isn't required.
[[ -e "/sys/class/video4linux/${LOOPBACK_DEV##/dev/}/uevent" ]] && \
    chmod g+w "/sys/class/video4linux/${LOOPBACK_DEV##/dev/}/uevent" || true

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
# Force wireplumber to rebuild the ${LOOPBACK_DEV} device proxy with its
# child Source node. Sending a "change" event only updates properties;
# wireplumber's v4l2 monitor does not re-evaluate child node creation on
# change. A fake "remove" + "add" cycle on the sysfs uevent file makes it
# destroy and recreate the device, which DOES create the Source node from
# current caps (Video Capture + YUYV 1280x720) and pick up the classify
# rule in wireplumber.conf.d/52-ipu6-bridge-classify.conf.
# The underlying v4l2loopback kernel device is unaffected: the writer's
# open fd keeps it alive; the uevent file just emits userspace events.
# The sysfs uevent file is made group-writable for the "video" group by
# /etc/udev/rules.d/70-ipu6-bridge.rules. Audio streams are untouched.
ExecStartPost=/bin/sh -c 'sleep 3; { echo remove > /sys/class/video4linux/${LOOPBACK_DEV##/dev/}/uevent; sleep 1; echo add > /sys/class/video4linux/${LOOPBACK_DEV##/dev/}/uevent; } 2>/dev/null || true'
Restart=on-failure
RestartSec=2s
# Keep one frame's worth of margin; ISYS streaming is throughput-sensitive.
Nice=-5
IOSchedulingClass=best-effort
IOSchedulingPriority=0

# No [Install] section on purpose. The bridge is opt-in per session: it
# streams the sensor continuously, which keeps the privacy LED lit and
# blocks suspend-on-lid-close. Start it manually when you want a webcam:
#   systemctl --user start camera-bridge.service
# Stop it when you're done, and before closing the lid:
#   systemctl --user stop  camera-bridge.service
EOF
chown "${INVOKING_USER}:${INVOKING_USER}" "${USER_UNIT_DIR}/camera-bridge.service"

# ---------------------------------------------------------------------------
# Step 5: register the unit (daemon-reload). Do NOT enable or start it.
# The bridge is opt-in per session; auto-start at boot keeps the LED on and
# blocks lid-close suspend.
# ---------------------------------------------------------------------------
log "Step 5: registering the user unit (no auto-start)."
sudo -u "${INVOKING_USER}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user daemon-reload
# If a previous run of this script enabled the unit, disable it now so the
# bridge doesn't auto-start at next login.
sudo -u "${INVOKING_USER}" \
    XDG_RUNTIME_DIR="/run/user/${USER_UID}" \
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${USER_UID}/bus" \
    systemctl --user disable camera-bridge.service 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 6: install systemd-suspend hook so the bridge is auto-stopped before
# the system suspends. Without this, a user who forgets to stop the bridge
# and closes the lid keeps the sensor running, pins a core, and may block
# suspend entirely.
# ---------------------------------------------------------------------------
log "Step 6: installing systemd-suspend hook to auto-stop the bridge before sleep."
SLEEP_HOOK="/usr/lib/systemd/system-sleep/ipu6-bridge-stop"
install -d "$(dirname "${SLEEP_HOOK}")"
cat > "${SLEEP_HOOK}" <<'SHEOF'
#!/bin/sh
# Auto-stop camera-bridge.service for every logged-in user before suspend.
# Installed by dell-precision-5490-camera-bridge.sh. Without this hook,
# leaving the bridge running and closing the lid keeps the sensor powered,
# pins a CPU core, and can prevent the system from actually suspending.
# Runs as root from systemd-suspend.service / systemd-hibernate.service.

case "$1" in
    pre)
        for uid_dir in /run/user/[0-9]*; do
            [ -d "${uid_dir}" ] || continue
            user_name="$(stat -c %U "${uid_dir}" 2>/dev/null)"
            [ -n "${user_name}" ] && [ "${user_name}" != "root" ] || continue
            [ -S "${uid_dir}/bus" ] || continue
            su -s /bin/sh -c "
                XDG_RUNTIME_DIR=${uid_dir} \
                DBUS_SESSION_BUS_ADDRESS=unix:path=${uid_dir}/bus \
                systemctl --user stop camera-bridge.service
            " "${user_name}" 2>/dev/null || true
        done
        ;;
esac
SHEOF
chmod 0755 "${SLEEP_HOOK}"

# ---------------------------------------------------------------------------
# Step 7: install the tray indicator (Ayatana StatusNotifierItem) and its
# autostart entry. Click the icon for a menu with Start / Stop / Status.
# ---------------------------------------------------------------------------
log "Step 7: installing tray indicator (status + start/stop) and autostart entry."
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    python3-gi gir1.2-gtk-3.0 gir1.2-ayatanaappindicator3-0.1 >/dev/null

INDICATOR="/usr/local/bin/ipu6-bridge-indicator"
cat > "${INDICATOR}" <<'PYEOF'
#!/usr/bin/env python3
"""Tray indicator for the IPU6 camera bridge.

Polls camera-bridge.service every 3 seconds, shows a tray icon whose
appearance reflects ON/OFF state, and offers Start / Stop / Status from
its menu. Designed for COSMIC (which runs a StatusNotifierWatcher), but
works in any DE with Ayatana / SNI tray support.
"""

import subprocess
import sys

import gi
gi.require_version("Gtk", "3.0")
try:
    gi.require_version("AyatanaAppIndicator3", "0.1")
    from gi.repository import AyatanaAppIndicator3 as AppIndicator3
except (ValueError, ImportError):
    sys.stderr.write(
        "ERROR: AyatanaAppIndicator3 not available. "
        "Install gir1.2-ayatanaappindicator3-0.1 and try again.\n"
    )
    sys.exit(1)

from gi.repository import Gtk, GLib

SERVICE = "camera-bridge.service"
ICON_ON = "camera-web"
ICON_OFF = "camera-disabled-symbolic"
POLL_INTERVAL_MS = 3000


def is_active() -> bool:
    return subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", SERVICE]
    ).returncode == 0


def show_status(_):
    result = subprocess.run(
        ["systemctl", "--user", "status", "--no-pager", "--lines=10", SERVICE],
        capture_output=True, text=True,
    )
    text = result.stdout or "(no output)"
    dialog = Gtk.MessageDialog(
        message_type=Gtk.MessageType.INFO,
        buttons=Gtk.ButtonsType.CLOSE,
        text="camera-bridge.service",
    )
    dialog.format_secondary_text(text)
    dialog.set_default_size(700, 400)
    dialog.run()
    dialog.destroy()


def on_start(_):
    subprocess.run(["systemctl", "--user", "start", SERVICE])


def on_stop(_):
    subprocess.run(["systemctl", "--user", "stop", SERVICE])


def on_quit(_):
    Gtk.main_quit()


def main():
    indicator = AppIndicator3.Indicator.new(
        "ipu6-bridge-indicator",
        ICON_OFF,
        AppIndicator3.IndicatorCategory.APPLICATION_STATUS,
    )
    indicator.set_status(AppIndicator3.IndicatorStatus.ACTIVE)
    indicator.set_title("IPU6 Camera Bridge")

    menu = Gtk.Menu()

    status_item = Gtk.MenuItem(label="Camera: checking")
    status_item.connect("activate", show_status)
    menu.append(status_item)

    menu.append(Gtk.SeparatorMenuItem())

    start_item = Gtk.MenuItem(label="Start camera")
    start_item.connect("activate", on_start)
    menu.append(start_item)

    stop_item = Gtk.MenuItem(label="Stop camera")
    stop_item.connect("activate", on_stop)
    menu.append(stop_item)

    menu.append(Gtk.SeparatorMenuItem())

    quit_item = Gtk.MenuItem(label="Quit indicator")
    quit_item.connect("activate", on_quit)
    menu.append(quit_item)

    menu.show_all()
    indicator.set_menu(menu)

    def tick():
        on = is_active()
        indicator.set_icon_full(
            ICON_ON if on else ICON_OFF,
            "Camera bridge active" if on else "Camera bridge stopped",
        )
        indicator.set_label("ON" if on else "", "ipu6")
        status_item.set_label("Camera: ON" if on else "Camera: OFF")
        start_item.set_sensitive(not on)
        stop_item.set_sensitive(on)
        return True

    tick()
    GLib.timeout_add(POLL_INTERVAL_MS, tick)
    Gtk.main()


if __name__ == "__main__":
    main()
PYEOF
chmod 0755 "${INDICATOR}"

# Autostart entry for the invoking user.
AUTOSTART_DIR="${INVOKING_HOME}/.config/autostart"
install -d -o "${INVOKING_USER}" -g "${INVOKING_USER}" "${AUTOSTART_DIR}"
cat > "${AUTOSTART_DIR}/ipu6-bridge-indicator.desktop" <<DEEOF
[Desktop Entry]
Type=Application
Name=IPU6 Camera Bridge Indicator
Comment=Status, start, and stop controls for the IPU6 webcam bridge
Exec=${INDICATOR}
Icon=camera-web
Categories=Utility;
StartupNotify=false
Terminal=false
X-GNOME-Autostart-enabled=true
DEEOF
chown "${INVOKING_USER}:${INVOKING_USER}" "${AUTOSTART_DIR}/ipu6-bridge-indicator.desktop"

# Kill any prior indicator instance. The new one will be launched at next
# login by the autostart entry. For this session, the install message
# tells the user how to launch it manually.
pkill -f "${INDICATOR}" 2>/dev/null || true

log "Step 8: verifying ${LOOPBACK_DEV} is wired up."
log "  ${LOOPBACK_DEV} formats:"
v4l2-ctl -d "${LOOPBACK_DEV}" --list-formats-ext 2>&1 | sed "s/^/    /" | head -10

cat <<TIPS

${LOG_PREFIX} Done. Bridge is installed but not running.

To use the tray indicator THIS session, launch it once by hand:
  ${INDICATOR} &
Subsequent logins will start it automatically (autostart entry installed).
The menu offers Start, Stop, and Status. The icon shows ON / OFF at a glance.

From the command line, equivalently:
  systemctl --user start camera-bridge.service
  systemctl --user stop  camera-bridge.service

A systemd-suspend hook auto-stops the bridge before sleep, so closing the
lid with the camera still running is safe. The bridge does not auto-restart
on resume; click the tray icon to bring it back next time you need it.

Use the camera by selecting "${LOOPBACK_LABEL}" as the webcam in any app
(Slack/Zoom/Chrome/Firefox/cheese).

To preview locally:
  gst-launch-1.0 v4l2src device=${LOOPBACK_DEV} ! videoconvert ! autovideosink

Troubleshooting:
  systemctl --user status camera-bridge.service
  journalctl --user -u camera-bridge.service -f

Tunable image settings live in the env vars near the top of this script.
Edit and re-run to apply (no need to --uninstall first).

Roll back with: sudo ${SCRIPT_NAME} --uninstall
TIPS
