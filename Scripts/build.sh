#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
output_dir="${1:-$project_dir/.build}"
mkdir -p "$output_dir"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
plugin="$output_dir/libStarRailDesktopMode.dylib"

cursor_flags=()
if [[ -n "${SRDM_CURSOR_PNG:-}" ]]; then
    if [[ ! -f "$SRDM_CURSOR_PNG" ]] ||
        [[ "$(stat -f %z "$SRDM_CURSOR_PNG")" -gt 1048576 ]]; then
        print -u2 'SRDM_CURSOR_PNG must point to a PNG file of at most 1 MiB.'
        exit 1
    fi
    metadata="$(LC_ALL=C sips -g format -g pixelWidth -g pixelHeight "$SRDM_CURSOR_PNG")"
    if ! grep -qx '  format: png' <<< "$metadata" ||
        ! grep -qx '  pixelWidth: 64' <<< "$metadata" ||
        ! grep -qx '  pixelHeight: 64' <<< "$metadata"; then
        print -u2 'SRDM_CURSOR_PNG must be a 64×64 PNG.'
        exit 1
    fi
    cursor_dir="$(mktemp -d "$output_dir/.cursor.XXXXXX")"
    cursor_header="$cursor_dir/SRDMEmbeddedCursor.hpp"
    trap 'rm -f -- "$cursor_header"; rmdir -- "$cursor_dir"' EXIT
    {
        print -r -- 'constexpr unsigned char EmbeddedCursorPNG[] = {'
        /usr/bin/xxd -i < "$SRDM_CURSOR_PNG"
        print -r -- '};'
    } > "$cursor_header"
    cursor_flags=(-DSRDM_EMBED_CURSOR -I "$cursor_dir")
fi

xcrun --sdk macosx clang++ -dynamiclib -std=c++20 -O2 -fobjc-arc \
    -target arm64-apple-ios15.0-macabi -isysroot "$sdk" \
    -iframework "$sdk/System/iOSSupport/System/Library/Frameworks" \
    -F"$sdk/System/iOSSupport/System/Library/Frameworks" \
    -framework Foundation -framework UIKit -framework QuartzCore \
    -framework CoreGraphics -framework GameController -framework Metal -framework ImageIO \
    -weak_framework MetalFX \
    -Wall -Wextra -Werror -fvisibility=hidden \
    -install_name '@rpath/libStarRailDesktopMode.dylib' \
    "${cursor_flags[@]}" "$project_dir"/Sources/*.mm -o "$plugin"

codesign --force --sign - --identifier io.starrail.desktopmode "$plugin"
codesign --verify --strict "$plugin"
print -r -- "$plugin"
