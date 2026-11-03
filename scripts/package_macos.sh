#!/usr/bin/env bash
# ==============================================================================
# scripts/package_mini_macos.sh
#
# Builds the macOS Application Bundle (Oh-Mini-Mineral.app) and packages it into
# a distributable disk image:
#   dist/Oh-Mini-Mineral-0.1.0-macOS.dmg
# ==============================================================================

set -euo pipefail

APP_NAME="Oh-Mini-Mineral"
VERSION="${1:-0.1.0}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN_DIR="${ROOT_DIR}/bin"
DIST_DIR="${ROOT_DIR}/dist"
STAGE_DIR="${DIST_DIR}/macos_dmg_root"
APP_BUNDLE="${STAGE_DIR}/${APP_NAME}.app"
DMG_PATH="${DIST_DIR}/${APP_NAME}-${VERSION}-macOS.dmg"

echo "=== Building ${APP_NAME} v${VERSION} macOS Bundle & DMG ==="

if [[ ! -f "${BIN_DIR}/omm_gui" ]] || [[ ! -f "${BIN_DIR}/omm_daemon" ]]; then
    "${ROOT_DIR}/scripts/build_all.sh" all
fi

rm -rf "${STAGE_DIR}" "${DMG_PATH}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS/codecs"
mkdir -p "${APP_BUNDLE}/Contents/Resources/codecs"
mkdir -p "${DIST_DIR}"

cp "${BIN_DIR}/omm_gui" "${APP_BUNDLE}/Contents/MacOS/omm_gui"
cp "${BIN_DIR}/omm_daemon" "${APP_BUNDLE}/Contents/MacOS/omm_daemon"
cp "${BIN_DIR}/omm_tui" "${APP_BUNDLE}/Contents/MacOS/omm_tui"
chmod +x "${APP_BUNDLE}/Contents/MacOS/omm_gui" \
         "${APP_BUNDLE}/Contents/MacOS/omm_daemon" \
         "${APP_BUNDLE}/Contents/MacOS/omm_tui"

if [[ -f "${BIN_DIR}/libomm_mineral.dylib" ]]; then
    cp "${BIN_DIR}/libomm_mineral.dylib" "${APP_BUNDLE}/Contents/MacOS/libomm_mineral.dylib"
fi

for dylib in "${BIN_DIR}/codecs"/libcodec_*.dylib; do
    if [[ -f "${dylib}" ]]; then
        cp "${dylib}" "${APP_BUNDLE}/Contents/MacOS/codecs/"
        cp "${dylib}" "${APP_BUNDLE}/Contents/Resources/codecs/"
    fi
done

cat > "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" << 'EOF'
#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="${DIR}:/opt/homebrew/bin:/usr/local/bin:${PATH}"
export DYLD_LIBRARY_PATH="${DIR}:${DIR}/codecs:/opt/homebrew/lib:/usr/local/lib:${DYLD_LIBRARY_PATH:-}"
cd "${DIR}"
exec "${DIR}/omm_gui" "$@"
EOF
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Generate macOS .icns icon (Mac System 7 Platinum + CRT Spectrum aesthetic)
ICONSET_DIR="${DIST_DIR}/OhMiniMineral.iconset"
rm -rf "${ICONSET_DIR}"
mkdir -p "${ICONSET_DIR}"

python3 - "${ICONSET_DIR}/icon_512x512.png" << 'PYEOF'
import struct, sys, zlib

out_path = sys.argv[1]
w = h = 512
raw = bytearray()
bars = [120, 210, 290, 340, 260, 310, 190, 140]
for y in range(h):
    raw.append(0)
    for x in range(w):
        dx = min(x, w - 1 - x)
        dy = min(y, h - 1 - y)
        if dx < 32 and dy < 32 and (32 - dx) ** 2 + (32 - dy) ** 2 > 32 ** 2:
            raw.extend((0, 0, 0, 0))
            continue
        # Classic Mac System 7 Platinum bevel frame
        if x < 18 or y < 18 or x >= w - 18 or y >= h - 18:
            c = 235 if (x < 18 or y < 18) else 136
            raw.extend((c, c, c, 255))
            continue
        if 18 <= y < 68:
            # Classic striped title bar
            stripe = 204 if (y % 4 < 2) else 165
            raw.extend((stripe, stripe, stripe, 255))
            continue
        # Phosphor CRT dark screen inset
        if 44 <= x < w - 44 and 92 <= y < h - 44:
            bx = (x - 64) // 48
            rx = (x - 64) % 48
            if 0 <= bx < 8 and 6 <= rx < 38:
                bh = bars[bx]
                by = (h - 64) - y
                if 0 <= by < bh:
                    if by > bh - 16:
                        raw.extend((255, 214, 10, 255))
                    else:
                        raw.extend((0, 230, 118, 255))
                    continue
            raw.extend((14, 22, 18, 255))
        else:
            raw.extend((214, 214, 214, 255))

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xffffffff)

ihdr = struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
with open(out_path, "wb") as f:
    f.write(png)
PYEOF

if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    for sz in 16 32 128 256 512; do
        sips -z "${sz}" "${sz}" "${ICONSET_DIR}/icon_512x512.png" --out "${ICONSET_DIR}/icon_${sz}x${sz}.png" >/dev/null
        sz2=$((sz * 2))
        sips -z "${sz2}" "${sz2}" "${ICONSET_DIR}/icon_512x512.png" --out "${ICONSET_DIR}/icon_${sz}x${sz}@2x.png" >/dev/null
    done
    iconutil -c icns "${ICONSET_DIR}" -o "${APP_BUNDLE}/Contents/Resources/OhMiniMineral.icns" || true
fi
rm -rf "${ICONSET_DIR}"

cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Oh-Mini-Mineral</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.weisshymmnos.oh-mini-mineral</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIconFile</key>
    <string>OhMiniMineral.icns</string>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - "${APP_BUNDLE}" || true
fi

ln -s /Applications "${STAGE_DIR}/Applications"
if [[ -f "${ROOT_DIR}/README_MINI.md" ]]; then
    cp "${ROOT_DIR}/README_MINI.md" "${STAGE_DIR}/README.md"
elif [[ -f "${ROOT_DIR}/README.md" ]]; then
    cp "${ROOT_DIR}/README.md" "${STAGE_DIR}/README.md"
fi

hdiutil create \
    -volname "${APP_NAME} ${VERSION}" \
    -srcfolder "${STAGE_DIR}" \
    -ov \
    -format UDZO \
    "${DMG_PATH}"

rm -rf "${STAGE_DIR}"
ls -lh "${DMG_PATH}"
echo "=== macOS DMG created at ${DMG_PATH} ==="
