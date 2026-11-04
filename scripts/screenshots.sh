#!/usr/bin/env bash
# Renders the README pictures from generated demo files: the animation in
# light and dark (docs/screenshots/demo-light.webp and demo-dark.webp), a
# still of each for visitors who ask for reduced motion, and one screenshot
# per kind of file. Nothing is captured from the screen and the renderer never
# comes to the front; its settings and caches go to a throwaway home.
# Needs Homebrew's opencascade and ffmpeg (built with libwebp, as Homebrew's is).
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "screenshots: $*" >&2; exit 1; }

command -v ffmpeg >/dev/null || die "ffmpeg is needed: brew install ffmpeg"
OCC="$(brew --prefix opencascade 2>/dev/null)" || die "OpenCASCADE is needed: brew install opencascade"
[ -d "$OCC/include/opencascade" ] || die "OpenCASCADE is needed: brew install opencascade"

out=docs/screenshots
width=1600
target=arm64-apple-macos12.0
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/bin" "$tmp/demo" "$tmp/ready"

OCC_LIBS=(TKernel TKMath TKG2d TKG3d TKGeomBase TKGeomAlgo TKBRep TKTopAlgo TKPrim TKBO TKBool
          TKFillet TKOffset TKMesh TKShHealing TKXSBase TKLCAF TKCDF TKCAF TKVCAF TKXCAF TKDE
          TKDESTEP TKDEIGES TKDESTL)
LINK=(-L"$OCC/lib" "${OCC_LIBS[@]/#/-l}" -Wl,-rpath,"$OCC/lib")

echo "Demo files:"
clang++ -std=c++17 -O2 -target "$target" -Wno-deprecated-declarations \
    -I"$OCC/include/opencascade" tools/demo/make_models.cpp "${LINK[@]}" -o "$tmp/bin/make_models" \
    2> >(grep -v "^ld: warning" >&2)
mkdir -p "$tmp/demo/planetary-set/3D" "$tmp/demo/planetary-set/_rels"
( cd "$tmp/demo" && "$tmp/bin/make_models" . >/dev/null )
( cd "$tmp/demo/planetary-set" && zip -X -D -q -r ../planetary-set.3mf '[Content_Types].xml' _rels 3D )
cp tools/demo/build-notes.md "$tmp/demo/"

# An archive of the whole demo project. The drawing and photos are
# placeholders: the preview lists names and sizes and never opens them.
project="$tmp/project/gear-pump"
mkdir -p "$project"/{cad,cam,docs,photos,print}
cp "$tmp/demo/gear-pump.step" "$project/cad/"
cp "$tmp/demo/pump-body.nc" "$project/cam/"
cp "$tmp/demo/build-notes.md" "$project/docs/"
cp "$tmp/demo/vase.stl" "$tmp/demo/planetary-set.3mf" "$project/print/"
head -c 188416 /dev/zero > "$project/docs/assembly-drawing.pdf"
head -c 2516582 /dev/zero > "$project/photos/prototype-01.jpg"
head -c 1992294 /dev/zero > "$project/photos/prototype-02.jpg"
( cd "$tmp/project" && zip -X -D -q -r "$tmp/demo/gear-pump-project.zip" gear-pump )
for file in gear-pump.step vase.stl planetary-set.3mf pump-body.nc build-notes.md gear-pump-project.zip; do
    [ -s "$tmp/demo/$file" ] || die "the demo file $file was not made"
    echo "  $file"
done

echo "Renderer:"
clang++ -std=c++17 -O2 -fPIC -target "$target" -Wno-deprecated-declarations \
    -I"$OCC/include/opencascade" -Isrc/core -c src/core/cadmesh.cpp -o "$tmp/bin/cadmesh.o"
clang++ -std=c++17 -O2 -fPIC -target "$target" -Isrc/core -c src/core/read_3mf.cpp -o "$tmp/bin/read_3mf.o"
clang -std=c11 -O2 -fPIC -target "$target" -Isrc/qlext -c src/qlext/archivelist.c -o "$tmp/bin/archivelist.o"
swiftc -O -target "$target" -module-name DemoRenderer -parse-as-library \
    -import-objc-header src/qlext/QLBridging.h -Isrc/core -Isrc/qlext \
    -framework Cocoa -framework Quartz -framework SceneKit -framework Metal \
    "$tmp/bin/cadmesh.o" "$tmp/bin/read_3mf.o" "$tmp/bin/archivelist.o" \
    -L"$OCC/lib" "${OCC_LIBS[@]/#/-l}" -lc++ -lz -larchive -Xlinker -rpath -Xlinker "$OCC/lib" \
    -o "$tmp/bin/render" \
    tools/demo/render.swift \
    src/qlext/PreviewViewController.swift src/qlext/GCodeHighlighter.swift \
    src/qlext/MarkdownPreview.swift src/qlext/ArchivePreview.swift src/qlext/MeshData.swift \
    src/qlext/FusionOpener.swift src/qlext/FusionOpenButton.swift \
    src/shared/PreviewPreferences.swift src/shared/FusionXPC.swift src/shared/HostApp.swift \
    2> >(grep -v "^ld: warning" >&2)

for theme in light dark; do
    echo "Rendering ($theme):"
    mkdir "$tmp/home-$theme"
    CFFIXED_USER_HOME="$tmp/home-$theme" "$tmp/bin/render" "$tmp/demo" "$tmp/$theme" "$theme"
    frames="$tmp/$theme/frames"
    # frame-0001.png to frame-NNNN.png, none missing: ffmpeg would stop at a gap.
    count="$(find "$frames" -name 'frame-*.png' | wc -l | tr -d ' ')"
    last="$(ls "$frames" | tail -1)"
    [[ "$count" -gt 0 && "$last" == "$(printf 'frame-%04d.png' "$count")" ]] ||
        die "frames are missing from the $theme recording"
    ffmpeg -loglevel error -y -framerate 30 -i "$frames/frame-%04d.png" \
        -vf "scale=$width:-1:flags=lanczos" -c:v libwebp_anim -q:v 80 -compression_level 6 \
        -loop 0 -an "$tmp/ready/demo-$theme.webp"
    sips -Z "$width" "$tmp/$theme/still.png" --out "$tmp/ready/demo-still-$theme.png" >/dev/null
    echo "  demo-$theme.webp ($(du -h "$tmp/ready/demo-$theme.webp" | cut -f1 | tr -d ' '))"
    echo "  demo-still-$theme.png"
done

echo "Screenshots:"
# shot <scene> <theme> <file>
shot() {
    sips -Z "$width" "$tmp/$2/$1.png" --out "$tmp/ready/$3" >/dev/null
    echo "  $3"
}
shot stl light stl.png
shot 3mf light 3mf.png
shot gcode light gcode.png
shot markdown light markdown.png
shot archive light archive.png
shot gcode dark dark.png

mkdir -p "$out"
cp "$tmp/ready/"* "$out/"
echo "Written to $out"
