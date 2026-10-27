#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
./Scripts/build.sh
build/Build/Products/Release/Otolog.app/Contents/MacOS/Otolog --self-test
