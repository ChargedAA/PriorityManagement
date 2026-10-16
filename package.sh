#!/bin/bash
# Builds .zip and .dmg installers for Apple silicon (arm64) and Intel (x86_64) into dist/
set -e
cd "$(dirname "$0")"
VERSION="${1:-1.0}"
rm -rf dist && mkdir -p dist/stage
for ARCH in arm64 x86_64; do
  D="dist/stage/$ARCH"
  mkdir -p "$D/dmg"
  ARCH=$ARCH ./build.sh "$D/PriorityManagement.app"
  ditto -c -k --keepParent "$D/PriorityManagement.app" "dist/PriorityManagement-$VERSION-$ARCH.zip"
  cp -R "$D/PriorityManagement.app" "$D/dmg/"
  ln -s /Applications "$D/dmg/Applications"
  hdiutil create -quiet -volname "PriorityManagement" -srcfolder "$D/dmg" -ov -format UDZO \
    "dist/PriorityManagement-$VERSION-$ARCH.dmg"
done
rm -rf dist/stage
ls -lh dist
