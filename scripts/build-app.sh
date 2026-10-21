#!/bin/zsh
# Builds a release Loupe.app into ./build so it can be opened from Finder
# and registered for .json / .ndjson / .jsonl files.
#
#   VERSION=0.2.0 UNIVERSAL=1 ./scripts/build-app.sh   # Apple silicon + Intel binary
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-$(cat VERSION)}
if [[ ${UNIVERSAL:-0} == 1 ]]; then
    swift build -c release --product Loupe --arch arm64 --arch x86_64
    BINARY=.build/apple/Products/Release/Loupe
else
    swift build -c release --product Loupe
    BINARY=.build/release/Loupe
fi

APP=build/Loupe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/Loupe"

# App icon: drawn by scripts/make-icon.swift, resized into an .icns with the built-in sips/iconutil.
MASTER=build/AppIcon-1024.png
if [[ ! -f $MASTER || scripts/make-icon.swift -nt $MASTER ]]; then
    swift scripts/make-icon.swift lens "$MASTER"
fi
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Loupe</string>
    <key>CFBundleDisplayName</key><string>Loupe</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string></array>
    <key>CFBundleIdentifier</key><string>app.loupe.Loupe</string>
    <key>CFBundleExecutable</key><string>Loupe</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>NSHumanReadableCopyright</key><string>© 2026 Kerem Taşpınar. MIT License.</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>app.loupe.ndjson</string>
            <key>UTTypeDescription</key><string>Newline-delimited JSON</string>
            <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.text</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>ndjson</string><string>jsonl</string></array></dict>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>JSON</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>LSItemContentTypes</key><array><string>public.json</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>JSON Lines</string>
            <key>CFBundleTypeRole</key><string>Viewer</string>
            <key>LSHandlerRank</key><string>Default</string>
            <key>LSItemContentTypes</key><array><string>app.loupe.ndjson</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null
echo "Built $APP"
