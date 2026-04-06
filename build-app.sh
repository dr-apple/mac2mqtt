#!/usr/bin/env zsh
set -euo pipefail

APP_NAME="Mac2MQTT.app"
APP_DIR="./dist/${APP_NAME}"
ICONSET_DIR="./dist/Mac2MQTT.iconset"
ICON_PNG="./dist/icon-1024.png"
ICON_SWIFT="./dist/render-icon.swift"

echo "Building release binaries..."
swift build -c release

echo "Creating app bundle..."
rm -rf "./dist"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

echo "Rendering app icon..."
cat > "${ICON_SWIFT}" <<'EOF'
import AppKit

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else {
    fputs("No graphics context\n", stderr)
    exit(1)
}

ctx.setFillColor(NSColor.clear.cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))

ctx.setStrokeColor(NSColor.black.cgColor)
ctx.setLineWidth(62)
ctx.setLineJoin(.round)
ctx.setLineCap(.round)

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * 1024.0, y: y * 1024.0) }
func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(x: x * 1024.0, y: y * 1024.0, width: w * 1024.0, height: h * 1024.0)
}

// Outer hybrid shell.
let outer = NSBezierPath(roundedRect: r(0.08, 0.08, 0.84, 0.84), xRadius: 0.2 * 1024.0, yRadius: 0.2 * 1024.0)
outer.stroke()

// Finder-like split.
let split = NSBezierPath()
split.move(to: p(0.5, 0.14))
split.line(to: p(0.5, 0.86))
split.stroke()

// Left eye + smile.
NSBezierPath(ovalIn: r(0.30, 0.60, 0.08, 0.08)).fill()
let smile = NSBezierPath()
smile.move(to: p(0.28, 0.36))
smile.curve(to: p(0.44, 0.33), controlPoint1: p(0.33, 0.30), controlPoint2: p(0.39, 0.30))
smile.stroke()

// Right remote ring + center.
NSBezierPath(ovalIn: r(0.58, 0.56, 0.20, 0.20)).stroke()
NSBezierPath(ovalIn: r(0.66, 0.64, 0.04, 0.04)).fill()

// Remote lower buttons.
NSBezierPath(ovalIn: r(0.61, 0.34, 0.06, 0.06)).fill()
NSBezierPath(ovalIn: r(0.71, 0.34, 0.06, 0.06)).fill()

image.unlockFocus()

let tiff = image.tiffRepresentation!
let rep = NSBitmapImageRep(data: tiff)!
let png = rep.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "./dist/icon-1024.png"))
EOF

swift "${ICON_SWIFT}"

mkdir -p "${ICONSET_DIR}"
cp "${ICON_PNG}" "${ICONSET_DIR}/icon_512x512@2x.png"
sips -z 16 16     "${ICON_PNG}" --out "${ICONSET_DIR}/icon_16x16.png" >/dev/null
sips -z 32 32     "${ICON_PNG}" --out "${ICONSET_DIR}/icon_16x16@2x.png" >/dev/null
sips -z 32 32     "${ICON_PNG}" --out "${ICONSET_DIR}/icon_32x32.png" >/dev/null
sips -z 64 64     "${ICON_PNG}" --out "${ICONSET_DIR}/icon_32x32@2x.png" >/dev/null
sips -z 128 128   "${ICON_PNG}" --out "${ICONSET_DIR}/icon_128x128.png" >/dev/null
sips -z 256 256   "${ICON_PNG}" --out "${ICONSET_DIR}/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "${ICON_PNG}" --out "${ICONSET_DIR}/icon_256x256.png" >/dev/null
sips -z 512 512   "${ICON_PNG}" --out "${ICONSET_DIR}/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "${ICON_PNG}" --out "${ICONSET_DIR}/icon_512x512.png" >/dev/null
iconutil -c icns "${ICONSET_DIR}" -o "${APP_DIR}/Contents/Resources/AppIcon.icns"

cp "./.build/release/mac2mqtt-ui" "${APP_DIR}/Contents/MacOS/mac2mqtt-ui"
cp "./.build/release/mac2mqttd" "${APP_DIR}/Contents/Resources/mac2mqttd"
cp "./mac2mqtt.yaml.example" "${APP_DIR}/Contents/Resources/mac2mqtt.yaml.example"
chmod +x "${APP_DIR}/Contents/MacOS/mac2mqtt-ui"
chmod +x "${APP_DIR}/Contents/Resources/mac2mqttd"

cat > "${APP_DIR}/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>mac2mqtt-ui</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.mac2mqtt-ui</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleName</key>
  <string>Mac2MQTT</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
</dict>
</plist>
EOF

echo "Done: ${APP_DIR}"
echo "Now drag ${APP_NAME} into Applications."
