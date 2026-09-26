#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
BUILD_DIR="${TMPDIR:-/tmp}/audioroute-poc-build"
mkdir -p "$BUILD_DIR" 'AudioRoute.app/Contents/MacOS'
xcrun clang -O2 -mmacosx-version-min=14.2 -c Source/Render.c -o "$BUILD_DIR/Render.o"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.2 -module-cache-path "$BUILD_DIR/module-cache" -import-objc-header Source/Render.h Source/Audio.swift Source/App.swift "$BUILD_DIR/Render.o" -framework AppKit -framework SwiftUI -framework CoreAudio -o AudioRoute.app/Contents/MacOS/AudioRoute
cp Info.plist AudioRoute.app/Contents/Info.plist
codesign --force --sign - --identifier local.audioroute.poc AudioRoute.app
printf 'Built %s/AudioRoute.app\n' "$PWD"
