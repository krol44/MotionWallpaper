#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"
BUILD_DIR="$PWD/build"

xcodebuild \
  -project MotionWallpaper.xcodeproj \
  -scheme MotionWallpaper \
  -configuration Debug \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$BUILD_DIR" \
  build

APP="$BUILD_DIR/Build/Products/Debug/MotionWallpaper.app"
echo
echo "Built: $APP"
open "$APP"
