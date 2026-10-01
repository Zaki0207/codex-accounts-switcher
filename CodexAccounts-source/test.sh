#!/bin/zsh
set -euo pipefail
source_dir="${0:A:h}"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
swiftc -target arm64-apple-macos14.0 -D REVIEW_TEST -parse-as-library \
  -framework AppKit -framework SwiftUI -framework Security -lsqlite3 \
  "${source_dir}"/*.swift "${source_dir}/tests/Regression.swift" \
  -o "${test_dir}/regression"
"${test_dir}/regression" "$@"
