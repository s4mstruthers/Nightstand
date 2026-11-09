#!/bin/bash
# Builds dist/Nightstand.app, and with --dmg a distributable disk image.
#   scripts/build-app.sh              native build for this Mac
#   scripts/build-app.sh --universal  Apple silicon + Intel
#   scripts/build-app.sh --dmg        also create dist/Nightstand-<version>.dmg
# Set CODESIGN_IDENTITY to a Developer ID to sign for distribution (default: ad-hoc).
set -euo pipefail
cd "$(dirname "$0")/.."

DMG=false
ARCHS=()
for arg in "$@"; do
  case "$arg" in
    --dmg) DMG=true ;;
    --universal) ARCHS=(--arch arm64 --arch x86_64) ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

VERSION="${VERSION:-$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)}"
VERSION="${VERSION:-0.1.0}"

swift build -c release ${ARCHS[@]+"${ARCHS[@]}"}
BIN="$(swift build -c release ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Nightstand"

# Assemble and sign in a temporary folder: synced folders (iCloud Drive, Dropbox) attach extended
# attributes that invalidate code signatures.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Nightstand.app"
rm -rf dist
mkdir -p dist "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Nightstand"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Nightstand</string>
  <key>CFBundleDisplayName</key><string>Nightstand</string>
  <key>CFBundleIdentifier</key><string>io.github.s4mstruthers.Nightstand</string>
  <key>CFBundleExecutable</key><string>Nightstand</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSRemovableVolumesUsageDescription</key><string>Nightstand sends books to your e-reader and shows what is on it.</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>E-book</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>org.idpf.epub-container</string></array>
      <key>CFBundleTypeExtensions</key>
      <array><string>epub</string><string>kepub</string><string>mobi</string><string>azw3</string><string>fb2</string><string>cbz</string></array>
    </dict>
  </array>
  <key>NSHumanReadableCopyright</key><string>Open source under the MIT License.</string>
</dict>
</plist>
PLIST

xattr -cr "$APP"
codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP"
codesign --verify --strict "$APP"
ditto "$APP" dist/Nightstand.app
echo "Built dist/Nightstand.app ($VERSION)"

if $DMG; then
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "Nightstand" -srcfolder "$STAGE" -ov -format UDZO -quiet "dist/Nightstand-$VERSION.dmg"
  echo "Built dist/Nightstand-$VERSION.dmg"
fi
