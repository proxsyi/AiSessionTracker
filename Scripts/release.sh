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

if [[ "${ALLOW_SINGLE_APP_RELEASE:-0}" != "1" ]]; then
    exec ./Scripts/release_train.sh
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
TAG="tracker-v${VERSION}"
RELEASE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/session-tracker-release.XXXXXX")"
RELEASE_BUILD_DIR="${RELEASE_ROOT}/build"
RELEASE_APP="${RELEASE_BUILD_DIR}/Session Tracker.app"
RELEASE_ZIP="${RELEASE_ROOT}/SessionTracker.app.zip"
VERIFY_DIR="${RELEASE_ROOT}/verify"
trap 'rm -rf "${RELEASE_ROOT}"' EXIT

echo "Releasing ${TAG}..."

if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "ERROR: set NOTARY_PROFILE to a stored notarytool keychain profile." >&2
    exit 1
fi

DISTRIBUTION=1 DIST_DIR="${RELEASE_BUILD_DIR}" ./Scripts/build_app.sh

ASSET_NAME="SessionTracker.app.zip"
rm -f "dist/${ASSET_NAME}"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "${RELEASE_APP}" "${RELEASE_ZIP}"
xcrun notarytool submit "${RELEASE_ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
xcrun stapler staple "${RELEASE_APP}"
xcrun stapler validate "${RELEASE_APP}"
spctl --assess --type execute --verbose=4 "${RELEASE_APP}"
codesign --verify --deep --strict --verbose=2 "${RELEASE_APP}"
rm -f "${RELEASE_ZIP}"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "${RELEASE_APP}" "${RELEASE_ZIP}"
mkdir -p "${VERIFY_DIR}"
ditto -x -k --norsrc --noextattr --noqtn "${RELEASE_ZIP}" "${VERIFY_DIR}"
codesign --verify --deep --strict --verbose=2 "${VERIFY_DIR}/Session Tracker.app"
cp "${RELEASE_ZIP}" "dist/${ASSET_NAME}"

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
