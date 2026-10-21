#!/bin/zsh
# Packages a universal (Apple silicon + Intel) Loupe.app into dist/ for a GitHub release.
set -euo pipefail
cd "${0:A:h}/.."

VERSION=${VERSION:-$(cat VERSION)}
UNIVERSAL=1 VERSION=$VERSION ./scripts/build-app.sh
lipo -info build/Loupe.app/Contents/MacOS/Loupe

mkdir -p dist
ZIP=dist/Loupe-$VERSION-macOS.zip
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Loupe.app "$ZIP"
(cd dist && shasum -a 256 "${ZIP:t}" > "${ZIP:t}.sha256")
echo "Packaged $ZIP"
cat "$ZIP.sha256"
