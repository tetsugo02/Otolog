#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
xcodebuild -project Otolog.xcodeproj -scheme Otolog -configuration Release -derivedDataPath build build
