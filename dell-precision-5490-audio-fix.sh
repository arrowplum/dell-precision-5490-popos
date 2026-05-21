#!/usr/bin/env bash
# Fix audio on Dell Precision 5490 running Pop!_OS 24.04 (or similar Ubuntu-based distro).
#
# The Intel Meteor Lake SOF + SoundWire card defaults to the "pro-audio" PipeWire
# profile, which exposes raw multichannel sinks but no Speaker/Headphones routing,
# so nothing comes out of the laptop speakers. Switching to the "HiFi" profile
# fixes it. WirePlumber persists the choice in ~/.local/state/wireplumber/.
#
# Safe to run multiple times.

set -euo pipefail

need() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "missing required command: $1" >&2
        exit 1
    }
}

need pactl

# Find the SOF SoundWire card. Matches the Meteor Lake-P HD Audio controller.
CARD="$(pactl list short cards | awk '/sof_sdw/ {print $2; exit}')"

if [[ -z "${CARD}" ]]; then
    echo "Could not find an sof_sdw PipeWire card. This script is for Dell Precision 5490 (or similar Intel Meteor Lake SoundWire) laptops." >&2
    pactl list short cards >&2
    exit 1
fi

echo "Found card: ${CARD}"

CURRENT="$(pactl list cards | awk -v c="${CARD}" '
    $1=="Name:" {match_=($2==c)}
    match_ && $1=="Active" && $2=="Profile:" {print $3; exit}
')"

echo "Current profile: ${CURRENT:-unknown}"

if [[ "${CURRENT}" == "HiFi" ]]; then
    echo "Already on HiFi profile. Nothing to change."
else
    echo "Switching to HiFi profile..."
    pactl set-card-profile "${CARD}" HiFi
    sleep 1
    echo "Done."
fi

echo
echo "Default sink:"
pactl get-default-sink

echo
echo "Sinks available:"
pactl list short sinks

cat <<'TEST'

Verify audio with these commands:
  speaker-test -t sine -f 440 -c 2 -l 1 -D default     # 440Hz tone through speakers
  arecord -f cd -d 5 /tmp/mic-test.wav && aplay /tmp/mic-test.wav   # mic record + playback
TEST
