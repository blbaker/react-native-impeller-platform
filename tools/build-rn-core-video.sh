#!/usr/bin/env bash
# Regenerate fixtures/rn-core/route.mp4, the rn-core test video (needs ffmpeg
# with libx264; the gate itself needs neither). 320x180, 30 fps, 12 s, H.264
# yuv420p, a keyframe every 30 frames. Frame k carries k in 9 bit blocks
# (tools/rn_core_check.py video_frame), so a screenshot names its frame.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=fixtures/rn-core/route.mp4
python3 tools/rn_core_check.py gen-video-frames |
  ffmpeg -hide_banner -loglevel error -y -f rawvideo -pix_fmt rgb24 -s 320x180 -r 30 -i - \
    -c:v libx264 -preset slow -crf 16 -g 30 -keyint_min 30 -sc_threshold 0 -bf 2 \
    -pix_fmt yuv420p -colorspace bt470bg -color_primaries bt470bg -color_trc smpte170m \
    -movflags +faststart "$OUT"
echo "wrote $OUT ($(wc -c < "$OUT") bytes)"
