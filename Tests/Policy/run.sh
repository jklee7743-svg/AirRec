#!/usr/bin/env bash
set -euo pipefail
AIRRECORD_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AIRRECORD_TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$AIRRECORD_TEST_DIR"' EXIT
swiftc "$AIRRECORD_ROOT/Sources/Core/Automation/AirRecordPolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Automation/AirRecordActivationFailurePolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Automation/AirRecordOutgoingWaitPolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Automation/AirRecordCallEndWaitPolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Automation/AirRecordIncomingWaitPolicy.swift" \
  "$AIRRECORD_ROOT/Tests/LegacySupport/Swift/AirRecordKeepAliveLease.swift" \
  "$AIRRECORD_ROOT/Tests/LegacySupport/Swift/AirRecordKeepAliveWire.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Background/AirRecordLocationSessionPolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Background/AirRecordLocationIndicatorPolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Background/AirRecordBackgroundPermissionPolicy.swift" \
  "$AIRRECORD_ROOT/Sources/Core/Background/AirRecordRecordingWaitPolicy.swift" \
  "$AIRRECORD_ROOT/Tests/Policy/main.swift" \
  -D AIRRECORD_AUTOMATION -D CALLTAP_RAWAX \
  -o "$AIRRECORD_TEST_DIR/airrecord-policy-tests"
"$AIRRECORD_TEST_DIR/airrecord-policy-tests"
