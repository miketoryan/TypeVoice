#!/bin/sh
set -eu

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen"
  exit 1
fi

xcodegen generate
echo "Generated TypeVoice.xcodeproj"
