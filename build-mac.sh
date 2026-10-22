#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Execute este script no Mac com Xcode instalado."
  exit 1
fi
xcodebuild -project Brisa.xcodeproj -scheme Brisa -configuration Release -derivedDataPath .derivedData SYMROOT="$PWD/build" build
open "$PWD/build/Release/Brisa.app"
