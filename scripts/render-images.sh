#!/bin/bash
# Redraws the README images and the app icon from demo data.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product SlurmBar
tmp=$(mktemp -d)
.build/debug/SlurmBar --render "$tmp"
cp "$tmp/showcase-light.png" "$tmp/showcase-dark.png" assets/
cp "$tmp/icon-1024.png" assets/icon.png
if command -v ffmpeg >/dev/null; then
  # 256-colour PNGs are about a quarter of the size and look the same here
  for f in assets/showcase-light.png assets/showcase-dark.png; do
    ffmpeg -loglevel error -y -i "$f" -vf "split[a][b];[a]palettegen=max_colors=256:stats_mode=full[p];[b][p]paletteuse=dither=sierra2_4a" "$tmp/q.png"
    mv "$tmp/q.png" "$f"
  done
fi
iconset="$tmp/AppIcon.iconset"
mkdir -p "$iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$tmp/icon-1024.png" --out "$iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$tmp/icon-1024.png" --out "$iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/AppIcon.icns
echo "updated assets/ and Resources/AppIcon.icns"
