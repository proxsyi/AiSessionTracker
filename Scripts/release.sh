#!/bin/bash
set -euo pipefail

# Builds the app, zips it, and publishes it as a new GitHub release so
# installed copies can find and install it via Settings > Check for updates.
# Requires the `gh` CLI, authenticated with access to this repo.
#
# Usage: NOTARY_PROFILE="your-notary-profile" ./Scripts/release.sh
# Bump the version in Resources/Info.plist and add a CHANGELOG.md entry
# for it before running this.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="gpt-v${VERSION}"

echo "Releasing ${TAG}..."

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "ERROR: set NOTARY_PROFILE to a stored notarytool keychain profile." >&2
    exit 1
fi

DISTRIBUTION=1 ./Scripts/build_app.sh

ASSET_NAME="GPTSessionPinger.app.zip"
rm -f "dist/${ASSET_NAME}"
ditto -c -k --sequesterRsrc --keepParent "dist/GPT Usage Tracker.app" "dist/${ASSET_NAME}"
xcrun notarytool submit "dist/${ASSET_NAME}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "dist/GPT Usage Tracker.app"
spctl --assess --type execute --verbose=4 "dist/GPT Usage Tracker.app"
rm -f "dist/${ASSET_NAME}"
ditto -c -k --sequesterRsrc --keepParent "dist/GPT Usage Tracker.app" "dist/${ASSET_NAME}"

NOTES=$(awk "/^## v${VERSION}/{flag=1; next} /^## /{flag=0} flag" CHANGELOG.md)
if [ -z "$NOTES" ]; then
    NOTES="See CHANGELOG.md."
fi

git tag "${TAG}" 2>/dev/null || echo "Tag ${TAG} already exists locally."
git push origin "${TAG}" 2>/dev/null || echo "Tag ${TAG} already pushed."

if gh release view "${TAG}" >/dev/null 2>&1; then
    echo "Release ${TAG} already exists -- updating its asset."
    gh release upload "${TAG}" "dist/${ASSET_NAME}" --clobber
else
    gh release create "${TAG}" "dist/${ASSET_NAME}" --title "${TAG}" --notes "${NOTES}"
fi

echo "Released ${TAG}."
