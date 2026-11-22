#!/bin/zsh
set -eu

project_dir="${0:A:h:h}"
output_dir="${1:-$project_dir/.build}"
mkdir -p "$output_dir"
xcrun clang++ -std=c++17 -Wall -Wextra -Werror -I"$project_dir/Sources" \
    "$project_dir/Tests/DesktopStateTests.cpp" -o "$output_dir/DesktopStateTests"
"$output_dir/DesktopStateTests"
