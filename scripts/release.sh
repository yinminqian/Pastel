#!/bin/bash
#
# Builds, signs, notarizes and packages a release DMG.
#
# Notarization needs a Developer ID Application certificate, which is not the
# same thing as the Apple Development certificate Xcode installs for you. If
# you do not have one, the script still produces a working DMG — it just skips
# notarization and says so. An un-notarized build is fine to run locally and
# will be refused by Gatekeeper if anyone downloads it.
#
# Credentials, if you have them:
#   xcrun notarytool store-credentials paster-notary \
#       --apple-id you@example.com --team-id TEAMID --password APP_SPECIFIC_PASSWORD
#
set -euo pipefail

SCHEME=paster
KEYCHAIN_PROFILE="${NOTARY_PROFILE:-paster-notary}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build/release"
STAGE="$BUILD/dmg"
DMG="$ROOT/paster.dmg"

echo "==> Testing"
xcodebuild test -project "$ROOT/paster.xcodeproj" -scheme "$SCHEME" \
    -destination 'platform=macOS' -quiet

echo "==> Building Release"
rm -rf "$BUILD" "$DMG"
xcodebuild -project "$ROOT/paster.xcodeproj" -scheme "$SCHEME" \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath "$BUILD" build -quiet

APP="$BUILD/Build/Products/Release/paster.app"
[ -d "$APP" ] || { echo "no app at $APP"; exit 1; }

echo "==> Verifying signature"
codesign --verify --deep --strict --verbose=1 "$APP"

# The hardened runtime is required for notarization. Confirm it is on and that
# no exception entitlements crept in — a clipboard manager needs none, and each
# one is something Apple has to review.
# Captured rather than piped into `grep -q`: under `pipefail`, grep exiting on
# its first match makes codesign fail with SIGPIPE and the test read inverted.
SIGNING="$(codesign -dvvv "$APP" 2>&1 || true)"
case "$SIGNING" in
    *"flags="*"runtime"*) ;;
    *) echo "!! hardened runtime is off; notarization would be rejected"; exit 1 ;;
esac

ENTITLEMENTS="$(codesign -d --entitlements - "$APP" 2>&1 || true)"
case "$ENTITLEMENTS" in
    *"com.apple.security.cs."*)
        echo "!! hardened-runtime exception entitlements present; remove them"
        exit 1 ;;
esac

AUTHORITY="$(printf '%s\n' "$SIGNING" | grep '^Authority=' | head -1 | cut -d= -f2-)"
echo "    signed by: $AUTHORITY"

echo "==> Packaging"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname paster -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

case "$AUTHORITY" in
    "Developer ID Application"*)
        echo "==> Notarizing"
        xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait
        xcrun stapler staple "$DMG"
        echo "==> Verifying Gatekeeper acceptance"
        spctl -a -vv -t install "$DMG"
        echo "==> Done: $DMG (notarized)"
        ;;
    *)
        echo
        echo "==> Skipping notarization."
        echo "    Signed with '$AUTHORITY', which cannot be notarized."
        echo "    A Developer ID Application certificate is required."
        echo "    The DMG works locally; Gatekeeper will refuse it if downloaded."
        echo "==> Done: $DMG (not notarized)"
        ;;
esac
