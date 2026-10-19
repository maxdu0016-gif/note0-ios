#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  HOMEBREW_NO_AUTO_UPDATE=1 brew install xcodegen
fi

(cd ios && xcodegen generate)

simulator_id="$(xcrun simctl list devices available --json | python3 -c 'import json, sys; devices=json.load(sys.stdin)["devices"]; print(next(device["udid"] for runtime in devices.values() for device in runtime if device["isAvailable"] and device["name"].startswith("iPad")))')"
test_root="$(mktemp -d)"
xcodebuild test \
  -project ios/Note0.xcodeproj \
  -scheme Note0 \
  -configuration Debug \
  -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$test_root/DerivedData" \
  -resultBundlePath "$test_root/Note0Tests.xcresult" \
  CODE_SIGNING_ALLOWED=NO
