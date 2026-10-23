#!/usr/bin/env bash
# Archive Psion5, export it for App Store Connect and upload it to TestFlight.
#
# Needs an App Store Connect API key (Admin or App Manager) described by
# ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH, in the environment or in
# ~/.appstoreconnect/brain.env, and an app record for io.hammant.psion5 in App
# Store Connect (the API can't create one; use the web UI once).
#
# The build bundles Psion's ROM, so keep it to internal testers: don't add an
# external TestFlight group or submit it for review.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${ASC_KEY_ID:-}" && -f ~/.appstoreconnect/brain.env ]]; then
  set -a
  # shellcheck disable=SC1090
  source ~/.appstoreconnect/brain.env
  set +a
fi
: "${ASC_KEY_ID:?set ASC_KEY_ID}" "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}" "${ASC_KEY_PATH:?set ASC_KEY_PATH}"

# Xcode's IPA packaging runs rsync from PATH; Homebrew's rsync 3.x rejects
# Apple's flags, so use the system tools only.
export PATH="/usr/bin:/bin:/usr/sbin:/sbin:$(dirname "$(command -v xcodegen)")"

BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"
OUT=build/testflight
ARCHIVE="$OUT/Psion5.xcarchive"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY_PATH"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

./scripts/fetch-windemu.sh
xcodegen generate >/dev/null

if [[ "${SKIP_ARCHIVE:-}" != "1" ]]; then
  rm -rf "$OUT"
  mkdir -p "$OUT"
  echo "Archiving build $BUILD_NUMBER..."
  # Log to a file, not a pipe: Xcode's build helpers can hold a pipe open
  # after xcodebuild exits.
  if ! xcodebuild -project Psion5.xcodeproj -scheme Psion5 -configuration Release \
      -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" \
      CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" archive > "$OUT/archive.log" 2>&1 < /dev/null; then
    grep -E "error:" "$OUT/archive.log" | head -20
    echo "ARCHIVE FAILED (full log: $OUT/archive.log)"
    exit 1
  fi
  echo "** ARCHIVE SUCCEEDED **"
fi

[[ "${ARCHIVE_ONLY:-}" == "1" ]] && exit 0
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")

rm -rf "$OUT/export"
echo "Exporting..."
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" \
    -exportOptionsPlist scripts/ExportOptions.plist "${AUTH[@]}" > "$OUT/export.log" 2>&1 < /dev/null; then
  grep -E "error:" "$OUT/export.log" | head -20
  echo "EXPORT FAILED (full log: $OUT/export.log)"
  exit 1
fi
echo "** EXPORT SUCCEEDED **"

IPA=$(find "$OUT/export" -name '*.ipa' | head -1)
echo "Uploading $(basename "$IPA") ($(du -h "$IPA" | cut -f1))..."
xcrun altool --upload-app -f "$IPA" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID" --output-format normal
echo "Uploaded build $BUILD_NUMBER. It shows up in TestFlight once App Store Connect has processed it (usually 5-15 minutes)."
