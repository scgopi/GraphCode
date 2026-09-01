#!/usr/bin/env bash
# Renders every animation to a GIF (for X) and an MP4 (for anywhere that takes video).
#
#   ./build.sh              all figures
#   ./build.sh pass-one-vs-pass-two
#
# Frames are stepped through window.__seek, so a re-run of an unchanged file produces
# byte-identical output — the GIF can never drift from the HTML it came from.
set -euo pipefail
cd "$(dirname "$0")"

[ -d node_modules/playwright-core ] || npm i --silent playwright-core

CAPTURE_FPS=25      # what the frames are stepped at, and the MP4's rate
GIF_FPS=12.5        # halved for the GIF: same motion, half the palette work
WIDTH=1200
HEIGHT=675

figures=("$@")
if [ ${#figures[@]} -eq 0 ]; then
  figures=(loop-learns loops-talk bundle-travels fresh-identity)
fi

mkdir -p out
for name in "${figures[@]}"; do
  name="${name%.html}"
  echo "── $name"
  node render.mjs "$name.html" "frames/$name" "$CAPTURE_FPS" "$WIDTH" "$HEIGHT"

  ffmpeg -loglevel error -y -framerate "$CAPTURE_FPS" -i "frames/$name/f%04d.png" \
    -c:v libx264 -pix_fmt yuv420p -crf 18 -movflags +faststart \
    -vf "scale=1600:-2:flags=lanczos" "out/$name.mp4"

  # Two passes: a palette built from the whole clip, then applied. One-pass GIFs band
  # badly on these flat dark panels.
  ffmpeg -loglevel error -y -framerate "$CAPTURE_FPS" -i "frames/$name/f%04d.png" \
    -vf "fps=$GIF_FPS,scale=1100:-1:flags=lanczos,palettegen=max_colors=192:stats_mode=diff" \
    -y "frames/$name/palette.png"
  ffmpeg -loglevel error -y -framerate "$CAPTURE_FPS" -i "frames/$name/f%04d.png" \
    -i "frames/$name/palette.png" \
    -lavfi "fps=$GIF_FPS,scale=1100:-1:flags=lanczos[x];[x][1:v]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle" \
    -loop 0 "out/$name.gif"

  # A still for anywhere that won't take motion, taken from the held final frame.
  cp "frames/$name/$(ls "frames/$name" | grep '^f' | tail -1)" "out/$name.png"

  printf '   %-34s %s\n' "$name.gif" "$(du -h "out/$name.gif" | cut -f1)"
  printf '   %-34s %s\n' "$name.mp4" "$(du -h "out/$name.mp4" | cut -f1)"
done
