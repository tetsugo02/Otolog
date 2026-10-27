#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# Validate before building or creating a release asset. No source version is changed.
release_version=$(python3 Scripts/release-version.py "${1:-}")
./Scripts/build.sh

app_path="build/Build/Products/Release/Otolog.app"
built_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")
source_version=$(python3 Scripts/release-version.py)
if [[ "$built_version" != "$source_version" ]]; then
  print -u2 "Built application version does not match source Info.plist"
  exit 1
fi
python3 Scripts/verify-app.py "$app_path"

mkdir -p dist
archive_name="Otolog-${release_version}-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "dist/$archive_name"
unzip -tq "dist/$archive_name"
(
  cd dist
  shasum -a 256 "$archive_name" > SHA256SUMS.txt
  shasum -a 256 --check SHA256SUMS.txt
)
print "Package: dist/$archive_name"
print 'Signing: ad-hoc; Developer ID signing and notarization are not configured.'
