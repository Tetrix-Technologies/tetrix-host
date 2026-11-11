#!/bin/sh
# Renders the app icon and fills the AppIcon asset set.
#
# The mark is drawn by the app itself, from the design tokens, in
# App/TetrixHost/Debug/Snapshots.swift. Build the Debug app first:
#
#   xcodebuild -project TetrixHost.xcodeproj -scheme TetrixHost \
#     -configuration Debug -derivedDataPath .build/xcode build
#
# Then run this script from the repo root.
set -eu

APP=".build/xcode/Build/Products/Debug/Tetrix Host.app/Contents/MacOS/Tetrix Host"
OUT=".build/icon"
SET="App/TetrixHost/Assets.xcassets/AppIcon.appiconset"

if [ ! -x "$APP" ]; then
	echo "Build the Debug app first. $APP is missing." >&2
	exit 1
fi

"$APP" --render-icon "$OUT"
for SIZE in 16 32 64 128 256 512 1024; do
	sips -s format png -z "$SIZE" "$SIZE" "$OUT/icon-1024.png" --out "$SET/icon-$SIZE.png" >/dev/null
done
echo "Wrote the icon to $SET"
