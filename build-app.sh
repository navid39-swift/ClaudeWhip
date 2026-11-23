#!/bin/bash
# Builds ClaudeWhip.app (and a .zip for GitHub Releases) from ClaudeWhip.swift.
# Usage: ./build-app.sh      → build/ClaudeWhip.app and build/ClaudeWhip.zip
set -e
cd "$(dirname "$0")"
VERSION="1.0"
APP="build/ClaudeWhip.app"

rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "• Compiling…"
swiftc -O ClaudeWhip.swift -o "$APP/Contents/MacOS/ClaudeWhip"

echo "• Making the 🤠 icon…"
if swift - << 'SWIFT' 2>/dev/null
import Cocoa
let s = 1024.0
let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { r in
    NSColor(calibratedRed: 0.98, green: 0.85, blue: 0.55, alpha: 1).setFill()
    NSBezierPath(roundedRect: r.insetBy(dx: 90, dy: 90), xRadius: 190, yRadius: 190).fill()
    let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 600)]
    let t = "🤠" as NSString, sz = t.size(withAttributes: a)
    t.draw(at: NSPoint(x: (s - sz.width) / 2, y: (s - sz.height) / 2 - 20), withAttributes: a)
    return true
}
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "build/icon.png"))
SWIFT
then
  mkdir -p build/icon.iconset
  for sz in 16 32 128 256 512; do
    sips -z $sz $sz build/icon.png --out build/icon.iconset/icon_${sz}x${sz}.png >/dev/null
    sips -z $((sz*2)) $((sz*2)) build/icon.png --out build/icon.iconset/icon_${sz}x${sz}@2x.png >/dev/null
  done
  iconutil -c icns build/icon.iconset -o "$APP/Contents/Resources/AppIcon.icns" && ICON="<key>CFBundleIconFile</key><string>AppIcon</string>"
  rm -rf build/icon.iconset build/icon.png
else
  echo "  (skipped the icon)"
fi

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>ClaudeWhip</string>
  <key>CFBundleDisplayName</key><string>ClaudeWhip</string>
  <key>CFBundleIdentifier</key><string>io.github.navid39-swift.claudewhip</string>
  <key>CFBundleExecutable</key><string>ClaudeWhip</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  ${ICON:-}
</dict>
</plist>
PLIST

echo "• Signing (ad-hoc)…"
codesign --force --deep --sign - "$APP"

(cd build && ditto -c -k --keepParent ClaudeWhip.app ClaudeWhip.zip)
echo "✓ Done: build/ClaudeWhip.app and build/ClaudeWhip.zip"
