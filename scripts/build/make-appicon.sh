#!/bin/bash
# make-appicon.sh — Render the MiragePlay app icon (macOS .icns) from the
# StatusIcon source SVG.
#
# Two variants are defined (PM task dock-branding-impl, YC to pick; default = ①):
#   ① light       — light rounded-square base + black geometry (Dock-readable)   [DEFAULT]
#   ② transparent — transparent base + black geometry only
#
# Geometry semantics mirror app/Sources/AppShell/StatusIconFactory.swift
# (icon-swap wave): white fills are dropped, the rectangle stroke is clipped
# against the triangle interior with an even-odd clip (the occlusion seen in
# the source file), the triangle stroke stays unclipped, eyes keep their
# fill+stroke disc equivalence.
#
# Usage:
#   scripts/build/make-appicon.sh --out <AppIcon.icns> [--variant light|transparent]
#                           [--previews <dir>] [--work <dir>]
#
#   --out       destination .icns path (multi-size 16..512@2x=1024)
#   --variant   which variant to build into --out (default: light, env
#               MIRAGE_APPICON_VARIANT overrides when the flag is absent)
#   --previews  also write preview PNGs (1024/64) and BOTH variants' .icns
#               into <dir>, so YC can compare the two options
#   --work      scratch directory for the intermediate SVGs and .iconset dirs
#               (default: <repo>/_build/appicon-work — the build tree, kept
#               because packaging calls this script without --work). Callers that render into a temporary tree pass
#               their own --work, otherwise the work files land in the checkout
#               even when --out points somewhere else.
#
# Exits non-zero on any failure. Deterministic: same source -> same outputs.
set -e

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/_canonical-path.sh
. "$REPO/scripts/lib/_canonical-path.sh"
SRC_SVG="$REPO/app/Resources/StatusIcon/icon.svg"
WORK="$REPO/_build/appicon-work"
OUT_ICNS=""
VARIANT="${MIRAGE_APPICON_VARIANT:-light}"
PREVIEWS=""
USAGE="usage: $0 --out <icns> [--variant light|transparent] [--previews <dir>] [--work <dir>]"

while [ $# -gt 0 ]; do
    case "$1" in
        --out)      OUT_ICNS="$2"; shift 2 ;;
        --variant)  VARIANT="$2"; shift 2 ;;
        --previews) PREVIEWS="$2"; shift 2 ;;
        --work)     WORK="$2"; shift 2 ;;
        -h|--help)  echo "$USAGE"; exit 0 ;;
        *) echo "$USAGE" >&2; exit 1 ;;
    esac
done

# One canonicalisation point, so the default and the flag cannot disagree: this
# value reaches rsvg-convert/iconutil, and a caller-typed spelling would be
# echoed back in every "prepared ..." line (see scripts/lib/_canonical-path.sh).
WORK="$(mp_canonical_path "$WORK")" || {
    echo "ERROR: cannot resolve the work directory '$WORK' to its on-disk spelling" >&2
    exit 1
}

if [ -z "$OUT_ICNS" ]; then
    echo "ERROR: --out <AppIcon.icns> is required" >&2
    exit 1
fi
case "$VARIANT" in
    light|transparent) ;;
    *) echo "ERROR: unknown variant '$VARIANT' (light|transparent)" >&2; exit 1 ;;
esac
if [ ! -f "$SRC_SVG" ]; then
    echo "ERROR: source SVG missing at $SRC_SVG" >&2
    exit 1
fi

for tool in rsvg-convert iconutil python3; do
    command -v "$tool" >/dev/null 2>&1 || { echo "ERROR: required tool '$tool' not found" >&2; exit 1; }
done

mkdir -p "$WORK"

# --- 1. derive the two prepared 1024x1024 SVGs from the source ---------------
python3 - "$SRC_SVG" "$WORK" <<'PYEOF'
import re, sys

src_path, work = sys.argv[1], sys.argv[2]
svg = open(src_path, encoding="utf-8").read()

# Source canvas and geometry (see StatusIconFactory.swift transcription):
#   canvas 211x165, content group translate(-1938,-146)
#   content bounds incl. stroke half-width (7.4479): x 4.0521..208.9479, y 1.0521..164.9479
CW, CH = 211.0, 165.0
HALF = 14.8958 / 2.0
CB_X0, CB_X1 = 11.5 - HALF, 201.5 + HALF          # 4.0521 .. 208.9479 (width 204.8958)
CB_Y0, CB_Y1 = 8.5 - HALF, 157.5 + HALF           # 1.0521 .. 164.9479 (height 163.8958)
CB_CX, CB_CY = (CB_X0 + CB_X1) / 2.0, (CB_Y0 + CB_Y1) / 2.0

# Extract the four source paths (order: rect, triangle, eye1, eye2).
paths = re.findall(r'<path\s+d="([^"]+)"[^>]*/>', svg)
if len(paths) != 4:
    sys.exit("expected 4 paths in %s, found %d" % (src_path, len(paths)))
rect_d, tri_d, eye1_d, eye2_d = paths

STROKE = 'stroke="#000000" stroke-width="14.8958" stroke-linecap="butt" stroke-linejoin="miter" stroke-miterlimit="8" stroke-opacity="1"'

# Geometry layer, in source coordinates (translate(-1938,-146) applied outside).
# The rect stroke is clipped to canvas-minus-triangle (even-odd) so the bottom
# edge breaks inside the triangle exactly like the source's white-fill occlusion.
defs = (
    '<defs><clipPath id="mb-cut" clipPathUnits="userSpaceOnUse">'
    '<path d="M1938 146L2149 146L2149 311L1938 311Z M1993.5 303.5L2044.5 214.5L2095.5 303.5Z" clip-rule="evenodd"/>'
    '</clipPath></defs>'
)
geometry = (
    defs
    + '<g clip-path="url(#mb-cut)"><path d="%s" fill="none" %s/></g>' % (rect_d, STROKE)
    + '<path d="%s" fill="none" %s/>' % (tri_d, STROKE)
    + '<path d="%s" fill="#000000" %s/>' % (eye1_d, STROKE)
    + '<path d="%s" fill="#000000" %s/>' % (eye2_d, STROKE)
)

# Placement: grid 1024. Geometry content (204.9 x 163.9 units) scaled to 660 px
# wide, centered at (512,512) in both variants so the only A/B difference is
# the base.
CANVAS = 1024.0
TARGET_W = 660.0
s = TARGET_W / (CB_X1 - CB_X0)
tx = CANVAS / 2.0 - CB_CX * s
ty = CANVAS / 2.0 - CB_CY * s
placed = '<g transform="translate(%.4f,%.4f) scale(%.6f)"><g transform="translate(-1938,-146)">%s</g></g>' % (tx, ty, s, geometry)

def write(name, base):
    out = (
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<svg width="%d" height="%d" viewBox="0 0 %d %d" xmlns="http://www.w3.org/2000/svg">\n'
        '%s\n%s\n</svg>\n'
    ) % (int(CANVAS), int(CANVAS), int(CANVAS), int(CANVAS), base, placed)
    with open("%s/%s" % (work, name), "w", encoding="utf-8") as f:
        f.write(out)
    print("prepared %s/%s" % (work, name))

# ① light: white macOS-style rounded-square base (824 grid, r 185.4).
TILE = '<rect x="102" y="102" width="820" height="820" rx="185.4" fill="#FFFFFF"/>'
write("icon-light.svg", TILE)
# ② transparent: same geometry, no base.
write("icon-transparent.svg", "")

print("scale=%.6f translate=(%.4f,%.4f)" % (s, tx, ty))
PYEOF

# --- 2. iconset render (16..512 + @2x) and .icns packing ---------------------
build_icns() { # <variant> <icns-out>
    local variant="$1" icns_out="$2"
    local svg="$WORK/icon-$variant.svg"
    local iconset="$WORK/$variant.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        rsvg-convert -w "$size"  -h "$size"  "$svg" -o "$iconset/icon_${size}x${size}.png"
        rsvg-convert -w "$((size*2))" -h "$((size*2))" "$svg" -o "$iconset/icon_${size}x${size}@2x.png"
    done
    # rsvg-convert writes color-type-6 (RGBA) PNGs; iconutil accepts them as-is.
    mkdir -p "$(dirname "$icns_out")"
    iconutil -c icns "$iconset" -o "$icns_out"
    echo "wrote $icns_out"
}

if [ -n "$PREVIEWS" ]; then
    mkdir -p "$PREVIEWS"
    for v in light transparent; do
        rsvg-convert -w 1024 -h 1024 "$WORK/icon-$v.svg" -o "$PREVIEWS/appicon-option$([ "$v" = light ] && echo 1 || echo 2)-$v-1024.png"
        rsvg-convert -w 64  -h 64  "$WORK/icon-$v.svg" -o "$PREVIEWS/appicon-option$([ "$v" = light ] && echo 1 || echo 2)-$v-64.png"
        build_icns "$v" "$PREVIEWS/appicon-option$([ "$v" = light ] && echo 1 || echo 2)-$v.icns"
    done
fi

build_icns "$VARIANT" "$OUT_ICNS"

echo "=== make-appicon complete (variant: $VARIANT) ==="
