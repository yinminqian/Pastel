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

# --- Update feed -------------------------------------------------------------
# Sparkle in the app reads appcast.xml from the repo (SUFeedURL in Info.plist)
# and downloads the DMG attached to the GitHub release. The DMG is signed with
# the EdDSA key that `generate_keys --account paster` stored in the Keychain;
# the app carries the matching public key (SUPublicEDKey).
#
# Publishing (PUBLISH=1 NOTES=path/to/notes.md ./scripts/release.sh) uploads the
# release first and pushes the feed second, so the feed never points at a DMG
# that is not there yet.
INFO="$APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$INFO")"
TAG="v$VERSION"
REPO="yinminqian/Pastel"
SPARKLE_BIN="$BUILD/SourcePackages/artifacts/sparkle/Sparkle/bin"
APPCAST="$ROOT/appcast.xml"

# Sparkle compares CFBundleVersion: a release that does not raise it is never
# offered to anyone.
if [ -f "$APPCAST" ]; then
    PUBLISHED="$(sed -n 's:.*<sparkle\:version>\(.*\)</sparkle\:version>.*:\1:p' "$APPCAST" | head -1)"
    if [ -n "$PUBLISHED" ] && [ "$BUILD_NUMBER" -le "$PUBLISHED" ]; then
        echo "!! build $BUILD_NUMBER is not above the published $PUBLISHED; raise CURRENT_PROJECT_VERSION"
        exit 1
    fi
fi

echo "==> Signing the update ($VERSION, build $BUILD_NUMBER)"
SIGNED="$("$SPARKLE_BIN/sign_update" --account paster "$DMG")"
SIGNATURE="$(printf '%s' "$SIGNED" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LENGTH="$(printf '%s' "$SIGNED" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
[ -n "$SIGNATURE" ] && [ -n "$LENGTH" ] || { echo "!! sign_update gave no signature: $SIGNED"; exit 1; }

python3 "$ROOT/scripts/appcast.py" "$APPCAST" "$VERSION" "$BUILD_NUMBER" "$MIN_SYSTEM" \
    "https://github.com/$REPO/releases/download/$TAG/paster.dmg" "$SIGNATURE" "$LENGTH" ${NOTES:+"$NOTES"}
echo "==> Wrote $APPCAST"

if [ "${PUBLISH:-0}" != "1" ]; then
    echo "    Not published. PUBLISH=1 NOTES=notes.md ./scripts/release.sh to release $TAG."
    exit 0
fi

[ -n "${NOTES:-}" ] && [ -f "$NOTES" ] || { echo "!! NOTES=path/to/notes.md is required to publish"; exit 1; }
gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 && { echo "!! $TAG is already released"; exit 1; }
# The release is cut from main; what was built has to be what main holds.
git -C "$ROOT" fetch -q origin main
[ "$(git -C "$ROOT" rev-parse HEAD)" = "$(git -C "$ROOT" rev-parse origin/main)" ] \
    || { echo "!! HEAD is not origin/main; push first"; exit 1; }
[ -z "$(git -C "$ROOT" status --porcelain -- . ':!appcast.xml' ':!paster.dmg')" ] \
    || { echo "!! uncommitted changes; the DMG would not match the tag"; exit 1; }

echo "==> Publishing $TAG"
gh release create "$TAG" "$DMG" --repo "$REPO" --target main \
    --title "Pastel $VERSION" --notes-file "$NOTES"
git -C "$ROOT" add appcast.xml
git -C "$ROOT" commit -q -m "Offer $VERSION to the update feed"
git -C "$ROOT" push -q origin main
echo "==> Released $TAG; installed copies will be offered it on their next launch"
