#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
output_dir="${1:-$project_dir/.build}"
mkdir -p "$output_dir"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
plugin="$output_dir/libStarRailDesktopMode.dylib"

xcrun --sdk macosx clang++ -dynamiclib -std=c++20 -O2 -fobjc-arc \
    -target arm64-apple-ios15.0-macabi -isysroot "$sdk" \
    -iframework "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -F"$sdk/System/iOSSupport/System/Library/Frameworks" \
    -framework Foundation -framework UIKit -framework QuartzCore \
    -framework CoreGraphics -framework GameController -framework Metal -framework ImageIO \
    -Wall -Wextra -Werror -fvisibility=hidden \
    -install_name '@rpath/libStarRailDesktopMode.dylib' \
    "$project_dir"/Sources/*.mm -o "$plugin"

codesign --force --sign - --identifier io.starrail.desktopmode "$plugin"
codesign --verify --strict "$plugin"
print -r -- "$plugin"
