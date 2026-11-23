#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
case "${1:-}" in
  ""|--universal) DEFAULT_TARGET="$HOME/Library/Caches/VPSMonitor/Builds/VPSMonitor Proview.app"; DEFAULT_ID="local.komari.monitor.preview" ;;
  --install) DEFAULT_TARGET="$HOME/Applications/VPSMonitor Proview.app"; DEFAULT_ID="local.komari.monitor.preview" ;;
  *) echo "usage: $0 [--install | --universal]" >&2; exit 2 ;;
esac
APP_TARGET="${VPSMONITOR_APP_DIR:-$DEFAULT_TARGET}"
BUNDLE_ID="${VPSMONITOR_BUNDLE_ID:-$DEFAULT_ID}"
[[ "$BUNDLE_ID" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "Invalid bundle identifier" >&2; exit 2; }
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/vpsmonitor-build.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT
APP_DIR="$STAGING_ROOT/VPSMonitor.app"
CONTENTS="$APP_DIR/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"
ICONSET="$STAGING_ROOT/VPSMonitor.iconset"
ICON_FILE="$RESOURCES/VPSMonitor.icns"

cd "$ROOT"
mkdir -p "$MACOS" "$RESOURCES"
BUILD_FLAGS=(-c release -Xswiftc -gnone -Xswiftc -no-toolchain-stdlib-rpath -Xswiftc -file-prefix-map -Xswiftc "$ROOT=.")
if [[ "${1:-}" == "--universal" ]]; then
  slices=()
  for arch in arm64 x86_64; do
    triple="$arch-apple-macosx14.0"
    swift build "${BUILD_FLAGS[@]}" --triple "$triple" --product KomariMonitor
    bin_dir="$(swift build "${BUILD_FLAGS[@]}" --triple "$triple" --show-bin-path)"
    slices+=("$bin_dir/KomariMonitor")
  done
  xcrun lipo -create "${slices[@]}" -output "$MACOS/VPSMonitor"
else
  swift build "${BUILD_FLAGS[@]}" --product KomariMonitor
  bin_dir="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
  cp "$bin_dir/KomariMonitor" "$MACOS/VPSMonitor"
fi
xcrun strip -S -x "$MACOS/VPSMonitor"
cp "Sources/KomariMonitor/KomariLogo.png" "$RESOURCES/KomariLogo.png"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_512x512.png" >/dev/null
sips -z 1024 1024 "Sources/KomariMonitor/KomariLogo.png" --out "$ICONSET/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET" -o "$ICON_FILE"
rm -rf "$ICONSET"

cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>VPSMonitor</string>
  <key>CFBundleIdentifier</key>
  <string>local.komari.monitor</string>
  <key>CFBundleName</key>
  <string>VPSMonitor Proview</string>
  <key>CFBundleDisplayName</key>
  <string>VPSMonitor Proview</string>
  <key>CFBundleIconFile</key>
  <string>VPSMonitor</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.7.0</string>
  <key>CFBundleVersion</key>
  <string>17</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR" >/dev/null
codesign --verify --deep --strict "$APP_DIR"

# Desktop/iCloud can reattach Finder metadata while signing. Sign outside the
# synced folder, then copy the completed bundle without inherited attributes.
[[ "$APP_TARGET" == /*.app && ! -L "$APP_TARGET" ]] || { echo "Expected an absolute, non-symlink .app path" >&2; exit 2; }
if [[ -e "$APP_TARGET" ]]; then
  EXPECTED_ID="$BUNDLE_ID"
  ACTUAL_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP_TARGET/Contents/Info.plist")"
  [[ "$ACTUAL_ID" == "$EXPECTED_ID" ]] || { echo "Refusing to overwrite a different application" >&2; exit 2; }
fi
mkdir -p "$(dirname "$APP_TARGET")"
rm -rf "$APP_TARGET"
ditto --noextattr --norsrc "$APP_DIR" "$APP_TARGET"
xattr -cr "$APP_TARGET"
codesign --verify --deep --strict "$APP_TARGET"

echo "$APP_TARGET"
