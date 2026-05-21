# Dell Precision 5490 on Pop!_OS 24.04: working audio + internal webcam

Scripts and notes for getting working audio and the internal IPU6 webcam to
function on a Dell Precision 5490 (and likely close cousins such as Latitude
7340/7440/7640 with the same Meteor Lake + OV01A10 + IVSC config) running
Pop!_OS 24.04 with kernel 6.18.

## TL;DR install order

```sh
sudo ./dell-precision-5490-audio-fix.sh    # audio: a 1-liner profile switch
sudo ./dell-precision-5490-camera-build.sh # camera prereq: builds Intel HAL + icamerasrc
sudo ./dell-precision-5490-camera-bridge.sh # camera: raw-Bayer to v4l2loopback bridge
```

Reboot once after all three. Camera will auto-start. Then in apps, pick
**"IPU6 Bridge"** (or "IPU6 Bridge (V4L2)") as the webcam.

## What works

| Component | Status | App-facing surface |
| --- | --- | --- |
| Speakers | ✅ | system default sink |
| Internal mic (SoundWire array) | ✅ | system default source |
| Headset jack | ✅ | works via the same sof-soundwire card |
| Internal webcam (IPU6 + OV01A10) | ✅ green-tinted | `/dev/video98` ("IPU6 Bridge") |
| Slack (Flatpak) | ✅ | sees "IPU6 Bridge" |
| Cheese | ✅ | needs `--device=/dev/video98` first time |
| Firefox (libv4l2 mode) | ⚠️ | sees ~50 dummy "ipu6" entries; pick "IPU6 Bridge (V4L2)" |
| Firefox (PipeWire camera mode) | ✅ | clean single-entry dropdown (recommended; see Firefox notes) |

Image quality is intentionally limited: no auto-exposure, no auto-white-balance,
no denoising, no lens shading correction. Picture is dim and noticeably
green-tinted. This is unavoidable without the Intel PSYS userspace stack, which
won't build against kernel 6.18 as of May 2026.

## Why the camera is non-trivial on this hardware

The IPU6 video pipeline on Meteor Lake has two kernel sides:
- **ISYS** (input stream system): handles raw Bayer capture from the sensor via
  the IVSC privacy proxy. Mainlined in kernel 6.10+.
- **PSYS** (processing system): runs the ISP that does debayer + AWB + AE +
  denoising and produces YUV. Lives only in `github.com/intel/ipu6-drivers`
  out-of-tree. The published driver source still uses pre-kernel-6.13
  `MODULE_IMPORT_NS(IDENT)` syntax and fails to compile on 6.18.

This setup gives up on PSYS entirely and instead:
1. Reads raw Bayer directly from ISYS via `v4l2-ctl`.
2. Software-debayers in GStreamer.
3. Pushes YUV into a `v4l2loopback` virtual device that apps consume.

Two subtle pieces make this work:

- **IVSC needs to be warmed up before raw streaming will work.** The kernel
  exposes IVSC subdev pads but doesn't let userspace set the crop selection
  that IVSC needs. The Intel `icamerasrc` GStreamer element opens the HAL,
  which configures IVSC properly, and THEN crashes opening `/dev/ipu-psys0`
  (which doesn't exist). The IVSC configuration persists after the crash.
  The bridge launcher runs `icamerasrc` once for exactly this side effect.

- **v4l2loopback needs specific options for Chromium-based apps.**
  `exclusive_caps=1` so Chromium classifies the device as capture-only,
  `max_buffers=8` because the v4l2sink MMAP bufferpool defaults to 2 and that
  is too few. Without these, Slack refuses to enumerate the device.

## File map

| File | Purpose |
| --- | --- |
| `dell-precision-5490-audio-fix.{md,sh}` | Switches PipeWire to the HiFi profile on the sof-soundwire card. Self-contained, one-line core. |
| `dell-precision-5490-camera-build.sh` | Builds Intel `ipu6-camera-bins`, `ipu6-camera-hal`, `icamerasrc` from source and installs under `/usr`. The HAL is dormant (PSYS missing) but `icamerasrc` is needed for the IVSC warm-up trick. Source clones land under `~/src/ipu6-build/`. |
| `dell-precision-5490-camera-bridge.sh` | Installs `v4l2loopback-dkms`, writes the modprobe config, installs the launcher at `/usr/local/bin/camera-bridge-ipu6`, installs a systemd `--user` unit, writes a WirePlumber rule to hide ISYS endpoints, and starts everything. |
| `README.md` | This file. |

## Order of operations (longer form)

1. **Audio fix.** PipeWire defaults the sof-soundwire card to `pro-audio`
   (passthrough) which has no Speaker port. We just switch the active profile
   to `HiFi`. WirePlumber persists the selection in
   `~/.local/state/wireplumber/default-profile`.

2. **Camera build.** Clones three Intel repos, copies bin/include files into
   `/usr`, builds `ipu6-camera-hal` and `icamerasrc` against them. Installs
   `gst-launch-1.0 icamerasrc` to `/usr/local/bin` and `/usr/lib/x86_64-linux-gnu/gstreamer-1.0/libgsticamerasrc.so`.
   Takes 5–15 minutes; the HAL is the long step. The HAL is parked: it will
   crash at runtime trying to open PSYS. We only need its enumeration side effects.

3. **Camera bridge.** Installs `v4l2loopback-dkms` (builds against the running
   kernel; works on 6.18). Writes `/etc/modprobe.d/zz-v4l2loopback-ipu6.conf`
   with the right options (the `zz-` prefix is required so it sorts after
   Pop's `v4l2loopback.conf` and `v4l2-relayd.conf`, otherwise its settings
   are overridden). Installs the bridge launcher at
   `/usr/local/bin/camera-bridge-ipu6` which:
   - Runs `icamerasrc` once (crashes intentionally) to warm IVSC.
   - Applies sensor exposure / gain / vblank.
   - Streams raw Bayer from `/dev/video32` via a FIFO into GStreamer.
   - `bayer2rgb` + `videocrop top=39 bottom=39` + `videoconvert` to YUY2
     1280x720 (standard 16:9 size; not the native 1280x798 because PipeWire's
     spa.v4l2 won't negotiate non-standard sizes for cheese et al).
   - `v4l2sink io-mode=mmap` to `/dev/video98`.
   Also installs a WirePlumber rule
   (`~/.config/wireplumber/wireplumber.conf.d/51-ipu6-isys-disable.conf`)
   that hides the dozens of raw ISYS endpoints from PipeWire's camera list.
   The systemd `--user` unit's `ExecStartPost` restarts wireplumber so the
   `/dev/video98` device gets classified as `Video/Source` after the writer
   attaches.

## App-side configuration

- **Slack (Flatpak).** Grant device perms: `flatpak permission-set devices camera com.slack.Slack yes`. Then quit Slack fully and reopen.
- **Cheese.** First launch: `cheese --device=/dev/video98`. Then in Preferences → Webcam pick "IPU6 Bridge".
- **Firefox.** In `about:config`, set `media.webrtc.camera.allow-pipewire` to `true`, then fully restart Firefox. Otherwise Firefox uses libv4l2 directly and the dropdown is polluted by ~50 useless ISYS entries.
- **Chromium / Chrome.** Should just work; uses libv4l2 directly and sees the loopback by label.

## Tuning

Edit the variables near the top of `dell-precision-5490-camera-bridge.sh`:

- `SENSOR_EXPOSURE` (default 500, max 888): higher = brighter, lower = faster shutter.
- `SENSOR_GAIN` (default 8192): analog gain. Default 256 = 1.0x. Boost in dim rooms.
- `SENSOR_DIGITAL_GAIN` (default 4096, default-1024).
- `SENSOR_VBLANK` (default 96): increase to allow longer exposure (at cost of fps).
- `OUT_WIDTH` / `OUT_HEIGHT` (1280 / 720). Standard 16:9 output. Don't change
  unless you understand the videocrop math.

Re-run `sudo dell-precision-5490-camera-bridge.sh` to apply edits.

## What NOT to do

Three failure modes we hit during development. Avoid them.

1. **Don't hot-edit the running launcher and `sudo dell-precision-5490-camera-bridge.sh` while the bridge is mid-stream.** Repeated v4l2sink restarts wedge IVSC at the MEI layer; only a reboot recovers. To experiment, write a separate `/tmp/test.sh` script and exercise it offline; only redeploy the launcher when the experiment is known good.

2. **Don't try to "fix the green tint" with a `glshader` patch on the live pipeline.** That's specifically what wedged us. The proper green-tint fix is to write a small Python `numpy + opencv` shim that reads raw Bayer, applies a real AWB matrix, debayers, and writes to v4l2loopback. Develop it standalone, replace the gst-launch stage when it's working.

3. **Don't enable `exclusive_caps=0` on v4l2loopback.** v4l2-ctl readers like it, but Chromium-based apps (Slack, Chrome, Electron) refuse to enumerate v4l2 devices that expose both Output and Capture caps. Keep it at 1.

## Rolling back

```sh
sudo ./dell-precision-5490-camera-bridge.sh --uninstall
sudo ./dell-precision-5490-camera-build.sh --uninstall
# audio fix is a runtime profile switch; nothing to uninstall.
```

The HAL bits live entirely under `/usr/lib` (HAL libs + gstreamer plugin) and
`/usr/include/libcamhal`. The bridge bits live at `/usr/local/bin/camera-bridge-ipu6`,
`/etc/modprobe.d/zz-v4l2loopback-ipu6.conf`, and the user systemd unit.

## Future work

- **When kernel 6.13+-compatible IPU6 PSYS lands** (either upstream mainline or
  a sed-fixed `intel/ipu6-drivers` build), the proper path is to install PSYS,
  let `icamerasrc` succeed instead of crash, and either keep the bridge (with
  `icamerasrc` upstream of bayer2rgb + AWB instead of our raw-Bayer path) or
  let Pop's built-in `v4l2-relayd@default.service` take over (it already uses
  `VIDEOSRC=icamerasrc`, currently failing for the same reason).

- **AWB / green-tint fix**: write a Python shim that does proper white balance
  on the raw Bayer. Develop standalone, swap into the launcher pipeline only
  after standalone tests pass. See "What NOT to do" #2.
