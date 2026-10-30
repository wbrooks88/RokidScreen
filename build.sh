#!/bin/bash
# Build "Rokid Screen.app" and copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Rokid Screen.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/RokidScreen" app/*.swift \
    -framework AppKit -framework Metal -framework MetalKit -framework ScreenCaptureKit \
    -framework IOKit -framework Carbon -framework CoreMedia -framework AVFoundation
mkdir -p "$APP/Contents/Resources"
# Icon Composer icon through actool (Xcode): macOS 26+ shows older .icns
# icons boxed in a grey tile; the .icns it also writes is for older systems
xcrun actool "$PWD/icon/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 14.0 --app-icon AppIcon \
    --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null
B=/opt/homebrew
# libusb linked in statically, so the app runs without Homebrew
cc -O2 -o "$APP/Contents/MacOS/rokid-mode" tools/rokid-mode.c -I$B/include/libusb-1.0 $B/lib/libusb-1.0.a \
    -framework IOKit -framework CoreFoundation -framework Security
codesign --force --sign - -i local.rokidscreen.mode "$APP/Contents/MacOS/rokid-mode"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.rokidscreen</string>
  <key>CFBundleName</key><string>Rokid Screen</string>
  <key>CFBundleExecutable</key><string>RokidScreen</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>Video</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>com.apple.quicktime-movie</string><string>public.mpeg-4</string><string>public.movie</string></array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key><string>Photo</string>
      <key>CFBundleTypeRole</key><string>Viewer</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>LSItemContentTypes</key><array><string>public.heic</string><string>public.heif</string><string>public.image</string></array>
    </dict>
  </array>
</dict></plist>
PLIST
# A fixed designated requirement keeps the Screen Recording permission across rebuilds
codesign --force --sign - -i local.rokidscreen -r='designated => identifier "local.rokidscreen"' "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/"Rokid Screen.app"
cp -R "$APP" ~/Applications/
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/"Rokid Screen.app"
echo "Built ~/Applications/Rokid Screen.app"
