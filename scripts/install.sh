#!/bin/zsh
# Builds Loupe, copies it to /Applications and makes it the default app for
# .json, .ndjson and .jsonl files.
set -euo pipefail
cd "${0:A:h}/.."

./scripts/build-app.sh
pkill -x Loupe 2>/dev/null || true
rm -rf /Applications/Loupe.app
ditto build/Loupe.app /Applications/Loupe.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Loupe.app
swift scripts/set-default-app.swift /Applications/Loupe.app json ndjson jsonl
