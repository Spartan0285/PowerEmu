#!/bin/bash
# make-icon.sh [OUT.icns]
#
# Build the app icon from assets/poweremu.icon (an Icon Composer document).
# Xcode's actool compiles .icon documents; with only the Command Line Tools
# available, flatten the document's layers ourselves -- bottom layer first,
# as icon.json lists them top-down -- and hand the result to iconutil.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/poweremu.icon"
OUT="${1:-$ROOT/build/PowerEmu.icns}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -d "$SRC" ] || { echo "no icon document at $SRC" >&2; exit 1; }

# Prefer Apple's own compiler when Xcode is present.
#
# This matters for more than fidelity. On macOS 26 an Icon Composer document
# compiles to an Assets.car holding the real icon; the .icns it also emits
# stops at 256px and is only a fallback. An app that ships the .icns alone
# gets the legacy treatment -- the system draws it inset inside its own
# rounded container, which is why a correctly sized icon came out looking
# tiny in the middle of a squircle. Hand-flattening the layers, which is what
# the fallback below does, can never produce the Assets.car and so can never
# fix that.
ACTOOL="$(xcode-select -p 2>/dev/null)/usr/bin/actool"
if [ -x "$ACTOOL" ]; then
    CAR_DIR="${ICON_CAR_DIR:-$(dirname "$OUT")}"
    mkdir -p "$CAR_DIR" "$WORK/acout"
    # The document is passed directly: actool ignores a .icon sitting inside
    # an .xcassets and silently compiles nothing.
    "$ACTOOL" --compile "$WORK/acout" --platform macosx \
        --minimum-deployment-target 26.0 --app-icon "$(basename "$SRC" .icon)" \
        --output-partial-info-plist "$WORK/acout/partial.plist" "$SRC" \
        >/dev/null 2>&1 || true
    if [ -f "$WORK/acout/Assets.car" ]; then
        cp "$WORK/acout/Assets.car" "$CAR_DIR/Assets.car"
        cp "$WORK/acout/$(basename "$SRC" .icon).icns" "$OUT" 2>/dev/null || true
        echo "built $OUT and $CAR_DIR/Assets.car (actool)"
        exit 0
    fi
    echo "actool produced no Assets.car; falling back to flattening" >&2
fi

# Layer file names, in the order icon.json lists them (top layer first).
LAYERS=$(python3 - "$SRC/icon.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
for g in d.get("groups", []):
    for l in g.get("layers", []):
        print(l["image-name"])
EOF
)

cat > "$WORK/flatten.swift" <<'EOF'
import AppKit

// argv: out.png size layer-bottom ... layer-top
let args = CommandLine.arguments
let out = URL(fileURLWithPath: args[1])
let size = Int(args[2])!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
for path in args.dropFirst(3) {
    guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
        FileHandle.standardError.write("cannot read \(path)\n".data(using: .utf8)!)
        exit(1)
    }
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
}
let dest = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
EOF

ORDERED=()
while IFS= read -r n; do
    [ -n "$n" ] && ORDERED=("$SRC/Assets/$n" "${ORDERED[@]+"${ORDERED[@]}"}")   # reverse: bottom first
done <<< "$LAYERS"

DEVELOPER_DIR=${DEVELOPER_DIR:-/Library/Developer/CommandLineTools} \
    swift "$WORK/flatten.swift" "$WORK/flat.png" 1024 "${ORDERED[@]}"

SET="$WORK/icon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
    sips -Z $s "$WORK/flat.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
    sips -Z $((s * 2)) "$WORK/flat.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p "$(dirname "$OUT")"
iconutil -c icns "$SET" -o "$OUT"
echo "built $OUT"
