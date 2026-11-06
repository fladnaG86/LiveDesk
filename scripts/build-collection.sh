#!/bin/zsh
# Renders the official LiveDesk wallpaper collection (original, CC0) and writes catalog/catalog.json.
#
#   scripts/build-collection.sh [tag]
#
# Output: dist/collection/<scene>.mov (4K HEVC loop), <scene>-preview.mp4, <scene>.jpg
# Upload the files as assets of the GitHub release <tag> (default: collection-1):
#   gh release create collection-1 dist/collection/* --title "LiveDesk Collection 1"
set -euo pipefail

TAG="${1:-collection-1}"
REPO="fladnaG86/LiveDesk"
BASE="https://github.com/$REPO/releases/download/$TAG"
ROOT="${0:A:h:h}"
OUT="$ROOT/dist/collection"
SCENES=(aurora nebula liquid synthwave starwarp lava silk bokeh ocean topo)

command -v ffmpeg >/dev/null || { echo "ffmpeg required (brew install ffmpeg)"; exit 1; }

cd "$ROOT"
xcodegen generate -q
xcodebuild -project LiveDesk.xcodeproj -target livedesk-render -configuration Release \
    SYMROOT="$ROOT/build/collection" build -quiet
RENDER="$ROOT/build/collection/Release/livedesk-render"

mkdir -p "$OUT"
for s in $SCENES; do
    if [[ ! -f "$OUT/$s.mov" ]]; then
        "$RENDER" "Resources/Scenes/$s" "$OUT/$s.mov" --width 3840 --height 2160 --fps 30 \
            --duration 20 --crossfade 3 --bitrate 18000000
    fi
    ffmpeg -loglevel error -y -i "$OUT/$s.mov" -t 8 -vf "scale=640:-2" -c:v libx264 -crf 27 \
        -pix_fmt yuv420p -movflags +faststart -an "$OUT/$s-preview.mp4"
    ffmpeg -loglevel error -y -ss 3 -i "$OUT/$s.mov" -frames:v 1 -vf "scale=960:-2" -q:v 3 "$OUT/$s.jpg"
done

python3 -I - "$ROOT" "$BASE" "${SCENES[@]}" <<'EOF'
import json, os, subprocess, sys
root, base, scenes = sys.argv[1], sys.argv[2], sys.argv[3:]
items = []
for s in scenes:
    manifest = json.load(open(os.path.join(root, "Resources/Scenes", s, "manifest.json")))
    probe = json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height:format=duration", "-of", "json", os.path.join(root, "dist/collection", s + ".mov")]))
    stream = probe["streams"][0]
    items.append({
        "id": "livedesk-" + s,
        "title": manifest["name"],
        "author": "LiveDesk",
        "video": f"{base}/{s}.mov",
        "preview": f"{base}/{s}-preview.mp4",
        "thumbnail": f"{base}/{s}.jpg",
        "width": stream["width"], "height": stream["height"],
        "duration": round(float(probe["format"]["duration"]), 2),
        "license": "CC0",
        "page": "https://github.com/fladnaG86/LiveDesk",
    })
os.makedirs(os.path.join(root, "catalog"), exist_ok=True)
with open(os.path.join(root, "catalog/catalog.json"), "w") as f:
    json.dump({"name": "LiveDesk Collection", "items": items}, f, indent=2, ensure_ascii=False)
    f.write("\n")
print(f"catalog/catalog.json: {len(items)} items")
EOF
ls -lh "$OUT"
