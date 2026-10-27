#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
APP="../双语译读.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -target arm64-apple-macosx14.0 -swift-version 5 -O -module-cache-path /tmp/bilingual-reader-swift-cache main.swift Layout.swift Credentials.swift AppleTranslation.swift BatchTranslation.swift -o "$APP/Contents/MacOS/BilingualReader" -framework AppKit -framework SwiftUI -framework PDFKit -framework CryptoKit -framework Security -framework NaturalLanguage -Xlinker -weak_framework -Xlinker Translation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>BilingualReader</string>
<key>CFBundleIdentifier</key><string>local.bilingualreader.desktop</string>
<key>CFBundleName</key><string>双语译读</string>
<key>CFBundleDisplayName</key><string>双语译读</string>
<key>CFBundleVersion</key><string>17</string>
<key>CFBundleShortVersionString</key><string>0.12.0</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
"$APP/Contents/MacOS/BilingualReader" --self-test
