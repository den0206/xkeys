#!/bin/bash
# Submits a file to Apple's notary service with the App Store Connect API key
# and fails unless the submission is Accepted, printing Apple's log on rejection.
# Requires ASC_KEY_PATH, ASC_KEY_ID and ASC_ISSUER_ID.
set -euo pipefail

file="$1"
auth=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
result="$(xcrun notarytool submit "$file" "${auth[@]}" --wait --output-format json)" || { echo "$result"; exit 1; }
echo "$result"
status="$(plutil -extract status raw - <<< "$result")"
if [ "$status" != "Accepted" ]; then
  xcrun notarytool log "$(plutil -extract id raw - <<< "$result")" "${auth[@]}" || true
  echo "::error::Notarization of $(basename "$file") finished with status: $status"
  exit 1
fi
