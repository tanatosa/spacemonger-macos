#!/usr/bin/env bash
#
# Builds a release SpaceMonger.app (universal: Apple Silicon + Intel) and a
# zip of it in dist/.
#
# Signing is AD HOC (no certificate, no Apple account): the app runs on the
# Mac that built it, but Gatekeeper blocks it on other Macs once downloaded.
# Shipping to other Macs needs a "Developer ID Application" certificate
# (SIGN_IDENTITY="Developer ID Application: …") plus notarization
# (xcrun notarytool submit … --wait; xcrun stapler staple …), not done here.
#
# Settings (environment variables):
#   VERSION        marketing version            (default 1.0.0)
#   BUILD_NUMBER   build number                 (default: git commit count)
#   BUNDLE_ID      bundle identifier            (default local.spacemonger.SpaceMongerMac)
#   ARCHS          architectures to build       (default "arm64 x86_64")
#   SIGN_IDENTITY  codesign identity, "-" = ad hoc (default -)
#
# Note: the bundle identifier is also the preferences domain, so the .app
# keeps its settings in ~/Library/Preferences/<BUNDLE_ID>.plist — not in
# SpaceMongerMac.plist, which `swift run` uses.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SpaceMonger"
EXECUTABLE="SpaceMongerMac"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
BUNDLE_ID="${BUNDLE_ID:-local.spacemonger.SpaceMongerMac}"
ARCHS="${ARCHS:-arm64 x86_64}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
MIN_MACOS="13.0"   # keep in step with platforms in Package.swift
ICON_SOURCE="Sources/SpaceMongerMac/Resources/AppIcon.png"

DIST="dist"
APP="$DIST/$APP_NAME.app"
ZIP="$DIST/$APP_NAME-$VERSION.zip"

arch_flags=()
for arch in $ARCHS; do arch_flags+=(--arch "$arch"); done

echo "==> Building release ($ARCHS)"
swift build -c release "${arch_flags[@]}"
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"
RESOURCE_BUNDLE="$BIN_DIR/${EXECUTABLE}_${EXECUTABLE}.bundle"

[[ -x "$BIN_DIR/$EXECUTABLE" ]] || { echo "error: $BIN_DIR/$EXECUTABLE not built" >&2; exit 1; }
# SwiftPM's Bundle.module looks for this in Contents/Resources and calls
# fatalError when it's missing — the app would crash at launch.
[[ -d "$RESOURCE_BUNDLE" ]] || { echo "error: $RESOURCE_BUNDLE not built" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP" "$ZIP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp -R "$RESOURCE_BUNDLE" "$APP/Contents/Resources/"

# Finder / Dock icon: the original's icon (res/SpaceMonger.ico, already
# upscaled to 512 px nearest-neighbor) at every size an .icns needs. The
# smaller sizes are exact integer downscales, so the pixel art stays crisp.
ICON_TMP="$(mktemp -d)"
trap 'rm -rf "$ICON_TMP"' EXIT
ICONSET="$ICON_TMP/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ICON_SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>     <string>en</string>
    <key>CFBundleExecutable</key>            <string>$EXECUTABLE</string>
    <key>CFBundleIdentifier</key>            <string>$BUNDLE_ID</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleName</key>                  <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>           <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>           <string>APPL</string>
    <key>CFBundleShortVersionString</key>    <string>$VERSION</string>
    <key>CFBundleVersion</key>               <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>              <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>        <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>     <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>              <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>       <true/>
    <key>NSHumanReadableCopyright</key>      <string>SpaceMonger © 1998–2020 Sean Werkema. MIT License.</string>
    <!-- Shown in the macOS privacy prompts when a scan reaches protected places. -->
    <key>NSDesktopFolderUsageDescription</key>    <string>SpaceMonger reads file sizes to draw its disk-space map.</string>
    <key>NSDocumentsFolderUsageDescription</key>  <string>SpaceMonger reads file sizes to draw its disk-space map.</string>
    <key>NSDownloadsFolderUsageDescription</key>  <string>SpaceMonger reads file sizes to draw its disk-space map.</string>
    <key>NSRemovableVolumesUsageDescription</key> <string>SpaceMonger reads file sizes to draw its disk-space map.</string>
    <key>NSNetworkVolumesUsageDescription</key>   <string>SpaceMonger reads file sizes to draw its disk-space map.</string>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (${SIGN_IDENTITY/#-/ad hoc})"
sign_flags=(--force --options runtime --sign "$SIGN_IDENTITY")
[[ "$SIGN_IDENTITY" != "-" ]] && sign_flags+=(--timestamp)
codesign "${sign_flags[@]}" "$APP"
codesign --verify --strict --verbose=1 "$APP"

echo "==> Packaging $ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
# Debug symbols, for reading crash reports of this exact build.
rm -rf "$DIST/$APP_NAME-$VERSION.dSYM"
cp -R "$BIN_DIR/$EXECUTABLE.dSYM" "$DIST/$APP_NAME-$VERSION.dSYM"

echo
echo "Built $APP_NAME $VERSION ($BUILD_NUMBER), $BUNDLE_ID"
echo "  app:   $APP ($(du -sh "$APP" | cut -f1))"
echo "  zip:   $ZIP ($(du -sh "$ZIP" | cut -f1))"
echo "  archs: $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE")"
codesign -dv "$APP" 2>&1 | grep -E '^(Signature|TeamIdentifier)=' | sed 's/^/  /'
