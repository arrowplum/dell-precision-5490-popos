# Dell Precision 5490 audio fix on Pop!_OS 24.04

## Symptom
Fresh Pop!_OS 24.04 install on a Dell Precision 5490 (replacing factory Ubuntu). System volume slider in the panel responded to playback, but no sound came out of the laptop speakers. Mic also silent.

## Hardware context
- Laptop: Dell Precision 5490, BIOS 1.6.0.
- OS: Pop!_OS 24.04 LTS, kernel 6.18.x.
- Audio: Intel Meteor Lake-P, driver `sof-audio-pci-intel-mtl` (Sound Open Firmware).
- Codecs over SoundWire:
  - RT713 (headset / SDCA) on link 0
  - RT1316 x2 (speaker amps) on links 1 and 2
  - RT1713 (DMIC array) on link 3
- SOF topology file in use: `sof-mtl-rt713-l0-rt1316-l12-rt1713-l3.tplg.zst`.
- UCM card name: `sof-soundwire` (ALSA card id `sofsoundwire`).

Drivers, firmware, and UCM profiles were all installed and loading correctly. No package install was needed.

## Root cause
PipeWire defaulted the card to the `pro-audio` profile (raw multichannel passthrough with no Speaker/Headphones routing) instead of the `HiFi` profile. Both profiles were available; only `HiFi` exposes the Speaker, Headphones, and HDMI ports with the right mixer routing.

Diagnostic snippet from `pactl list cards`:

```
Profiles:
    off:       Off
    HiFi:      Play HiFi quality Music (sinks: 5, sources: 2, available: yes)
    pro-audio: Pro Audio (sinks: 6, sources: 3)
Active Profile: pro-audio
```

## Fix (one command)

```sh
pactl set-card-profile alsa_card.pci-0000_00_1f.3-platform-sof_sdw HiFi
```

WirePlumber automatically persists the selection to:

```
~/.local/state/wireplumber/default-profile
```

so the choice survives reboots. No system files were modified.

Equivalent via the GUI: open **Settings → Sound** (or **gnome-control-center sound**), pick the speaker/headphones output, and the profile flips to HiFi behind the scenes.

## Verification

Speakers:
```sh
speaker-test -t sine -f 440 -c 2 -l 1 -D default
```
(short 440 Hz tone, Ctrl-C to stop)

Microphone (record 5s, play back):
```sh
arecord -f cd -d 5 /tmp/mic-test.wav && aplay /tmp/mic-test.wav
```

Useful state to sanity-check after the profile switch:
```sh
pactl list short sinks          # expect HiFi__Speaker__sink, HiFi__Headphones__sink, HiFi__HDMI*__sink
pactl get-default-sink           # expect the Speaker sink
wpctl status                     # see active sink/source with a star
```

## What was NOT needed
- No kernel upgrade (kernel 6.18 was already new enough).
- No firmware-sof-signed swap.
- No new alsa-ucm-conf or pipewire packages.
- No `/etc/modprobe.d` quirks.
- No editing of UCM `.conf` files.

The hardware support was complete; the only issue was the wrong PipeWire card profile being picked at first session start.

## TL;DR for someone on the same laptop

Run this once, log out and back in if needed, and audio works:

```sh
pactl set-card-profile alsa_card.pci-0000_00_1f.3-platform-sof_sdw HiFi
```
