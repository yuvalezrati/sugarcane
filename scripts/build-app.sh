#!/bin/bash
# Builds the downloadable Sugarcane release into ./dist:
#
#   dist/Sugarcane-<version>.pkg   double-click installer: installs Sugarcane into Applications and opens it
#   dist/Sugarcane-<version>.zip   the plain app, for people who prefer to drag it into Applications
#   dist/Sugarcane.app             the app itself
#
# Usage:
#   ./scripts/build-app.sh                                  unsigned build (fine for friends; see README)
#   VERSION=1.1.0 ./scripts/build-app.sh                    set the version number
#
# Optional, with an Apple Developer account, so people get no security warning:
#   DEVELOPER_ID="Developer ID Application: Your Name (TEAMID)" \
#   INSTALLER_ID="Developer ID Installer: Your Name (TEAMID)" \
#   NOTARY_PROFILE="sugarcane-notary" ./scripts/build-app.sh
#   (create the profile once with: xcrun notarytool store-credentials sugarcane-notary)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-1.3.3}"
BUNDLE_ID="${BUNDLE_ID:-io.github.yuvalezrati.sugarcane}"
MIN_MACOS="12.0"
DEVELOPER_ID="${DEVELOPER_ID:-}"
INSTALLER_ID="${INSTALLER_ID:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

DIST="dist"
BUILD="build"
APP="$DIST/Sugarcane.app"

if ! command -v swiftc >/dev/null; then
  echo "swiftc not found. Install the command-line tools with: xcode-select --install"
  exit 1
fi

rm -rf "$DIST" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD"

# 1. Compile for Apple silicon and Intel, then merge into one universal binary
echo "Compiling Sugarcane $VERSION (Apple silicon + Intel)…"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos$MIN_MACOS" sugarcane.swift -o "$BUILD/Sugarcane-$arch"
done
lipo -create "$BUILD/Sugarcane-arm64" "$BUILD/Sugarcane-x86_64" -output "$APP/Contents/MacOS/Sugarcane"

# 2. App icon: a green cane stalk with an amber leaf on a near-black tile
echo "Making the icon…"
cat > "$BUILD/icon.swift" <<'EOF'
import AppKit
let side: CGFloat = 1024
let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
    let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 100, dy: 100), xRadius: 185, yRadius: 185)
    NSGradient(starting: NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 1),
               ending: NSColor(srgbRed: 0.05, green: 0.045, blue: 0.04, alpha: 1))!.draw(in: tile, angle: -90)
    // A leaning cane stalk in four jointed sections, with one leaf
    let transform = NSAffineTransform()
    transform.translateX(by: 512, yBy: 512)
    transform.rotate(byDegrees: -14)
    transform.concat()
    let green = NSColor(srgbRed: 0.204, green: 0.780, blue: 0.349, alpha: 1)
    green.setFill()
    for i in 0..<4 {
        NSBezierPath(roundedRect: NSRect(x: -52, y: -300 + CGFloat(i) * 152, width: 104, height: 136),
                     xRadius: 30, yRadius: 30).fill()
    }
    let leaf = NSBezierPath()
    leaf.move(to: NSPoint(x: 52, y: 150))
    leaf.curve(to: NSPoint(x: 290, y: 330), controlPoint1: NSPoint(x: 150, y: 170), controlPoint2: NSPoint(x: 250, y: 240))
    leaf.curve(to: NSPoint(x: 52, y: 230), controlPoint1: NSPoint(x: 190, y: 310), controlPoint2: NSPoint(x: 110, y: 280))
    leaf.close()
    NSColor(srgbRed: 0.941, green: 0.706, blue: 0.271, alpha: 1).setFill()
    leaf.fill()
    return true
}
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
EOF
ICON_FILE=""
if swift "$BUILD/icon.swift" "$BUILD/icon.png" 2>/dev/null; then
  ICONSET="$BUILD/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z "$s" "$s" "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$BUILD/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  ICON_FILE="AppIcon"
else
  echo "  (couldn't draw the icon – continuing without one)"
fi

# 3. Info.plist: menu-bar-only app (no Dock icon)
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Sugarcane</string>
  <key>CFBundleDisplayName</key><string>Sugarcane</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>Sugarcane</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>$ICON_FILE</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.healthcare-fitness</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# 4. Sign the app (Developer ID if given, otherwise ad-hoc)
echo "Signing the app…"
if [[ -n "$DEVELOPER_ID" ]]; then
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID" "$APP"
else
  codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"

# 5. The double-click installer (.pkg)
echo "Building the installer…"
PKGROOT="$BUILD/pkgroot"
SCRIPTS="$BUILD/scripts"
mkdir -p "$PKGROOT/Applications" "$SCRIPTS"
ditto "$APP" "$PKGROOT/Applications/Sugarcane.app"

# Quit a running copy before upgrading
cat > "$SCRIPTS/preinstall" <<'EOF'
#!/bin/bash
pkill -x Sugarcane 2>/dev/null || true
exit 0
EOF
# Open Sugarcane for the person who ran the installer, so the sign-in panel appears right away
cat > "$SCRIPTS/postinstall" <<'EOF'
#!/bin/bash
console_user=$(stat -f%Su /dev/console)
if [[ -n "$console_user" && "$console_user" != "root" ]]; then
  uid=$(id -u "$console_user")
  launchctl asuser "$uid" sudo -u "$console_user" open -a "/Applications/Sugarcane.app" || true
fi
exit 0
EOF
chmod +x "$SCRIPTS/preinstall" "$SCRIPTS/postinstall"

# Always install into /Applications (don't "relocate" to some other copy of the app)
pkgbuild --analyze --root "$PKGROOT" "$BUILD/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/components.plist"

pkgbuild --root "$PKGROOT" --install-location / --component-plist "$BUILD/components.plist" \
  --scripts "$SCRIPTS" --identifier "$BUNDLE_ID.pkg" --version "$VERSION" \
  "$BUILD/Sugarcane-component.pkg" >/dev/null

PKG="$DIST/Sugarcane-$VERSION.pkg"
if [[ -n "$INSTALLER_ID" ]]; then
  productbuild --package "$BUILD/Sugarcane-component.pkg" --sign "$INSTALLER_ID" --timestamp "$PKG" >/dev/null
else
  productbuild --package "$BUILD/Sugarcane-component.pkg" "$PKG" >/dev/null
fi

# 6. Notarize (only with an Apple Developer account)
if [[ -n "$NOTARY_PROFILE" && -n "$INSTALLER_ID" ]]; then
  echo "Notarizing the installer (takes a few minutes)…"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
fi

# 7. A plain zip of the app as an alternative download
ditto -c -k --keepParent "$APP" "$DIST/Sugarcane-$VERSION.zip"

echo
echo "Done:"
echo "  $PKG   ← share this one: double-click to install"
echo "  $DIST/Sugarcane-$VERSION.zip"
if [[ -z "$INSTALLER_ID" ]]; then
  echo
  echo "This build isn't signed with an Apple Developer ID, so macOS will warn people the"
  echo "first time they open the installer. The README explains how to get past that."
fi
