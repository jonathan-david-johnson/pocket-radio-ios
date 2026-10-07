#!/bin/sh
# Regenerates the looped tone fixture served by IcyStreamServer (M13 E2 method item 1):
# 10 s, 440 Hz, mono, 128 kbps CBR, amplitude 0.05, libmp3lame.
#
# Usage: make_tone.sh [output.mp3]
#   Default output is carplay_tone_128k.mp3 next to this script. Pass a path to avoid overwriting.
set -eu
OUT="${1:-$(cd "$(dirname "$0")" && pwd)/carplay_tone_128k.mp3}"
/opt/homebrew/bin/ffmpeg -y -loglevel error \
  -f lavfi -i "sine=frequency=440:duration=10:sample_rate=44100" \
  -af "volume=0.05" -ac 1 -c:a libmp3lame -b:a 128k "$OUT"
