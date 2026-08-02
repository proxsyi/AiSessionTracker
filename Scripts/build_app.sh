#!/bin/bash
set -euo pipefail

APP_NAME="Session Tracker"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR=".build/release"
DIST_DIR="dist"
DIST_APP_DIR="${DIST_DIR}/${APP_NAME}.app"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/session-pinger-build.XXXXXX")"
APP_DIR="${WORK_DIR}/${APP_NAME}.app"
trap 'rm -rf "${WORK_DIR}"' EXIT

swift build -c release

# The combined tracker is a third, separately identified product. Building it
# never removes either standalone app from dist or /Applications.
rm -rf "${DIST_APP_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/CombinedSessionTracker" "${APP_DIR}/Contents/MacOS/CombinedSessionTracker"
cp "${BUILD_DIR}/SessionPingerWakeHelper" "${APP_DIR}/Contents/Resources/SessionPingerWakeHelper"
chmod 755 "${APP_DIR}/Contents/Resources/SessionPingerWakeHelper"
cp "Resources/Info.plist" "${APP_DIR}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_DIR}/Contents/Resources/AppIcon.icns"

# Strip Finder metadata / extended attributes before signing. codesign
# refuses to sign a bundle containing them ("resource fork, Finder
# information, or similar detritus not allowed"). Newer macOS versions add
# provenance/quarantine xattrs to copied files, so always clean first.
xattr -cr "${APP_DIR}"
find "${APP_DIR}" -name "._*" -delete

# Distribution builds require Developer ID Application signing; development
# builds may use the local Apple Development identity for on-device testing.
AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning)"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="${CODESIGN_IDENTITY}"
elif [[ "${DISTRIBUTION:-0}" == "1" && "${AVAILABLE_IDENTITIES}" == *"Developer ID Application:"* ]]; then
    SIGN_IDENTITY="$(printf '%s\n' "${AVAILABLE_IDENTITIES}" | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -n 1)"
elif [[ "${AVAILABLE_IDENTITIES}" == *"Apple Development:"* ]]; then
    SIGN_IDENTITY="$(printf '%s\n' "${AVAILABLE_IDENTITIES}" | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -n 1)"
else
    SIGN_IDENTITY="Session Pinger Signing"
fi
if [[ "${DISTRIBUTION:-0}" == "1" && "${SIGN_IDENTITY}" != Developer\ ID\ Application:* ]]; then
    echo "ERROR: distribution builds require a Developer ID Application certificate." >&2
    exit 1
fi
if printf '%s\n' "${AVAILABLE_IDENTITIES}" | grep -Fq "${SIGN_IDENTITY}"; then
    echo "Signing with identity: ${SIGN_IDENTITY}"
    if [[ "${DISTRIBUTION:-0}" == "1" ]]; then
        codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_DIR}"
    else
        codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}"
    fi
else
    echo "WARNING: code-signing identity \"${SIGN_IDENTITY}\" not found -- using ad-hoc signing."
    echo "         The keychain will re-prompt on every update until this identity exists."
    codesign --force --deep --sign - "${APP_DIR}"
fi

codesign --verify --deep --strict --verbose=2 "${APP_DIR}"

# Assemble and sign outside Documents so Finder cannot race codesign by
# attaching com.apple.FinderInfo midway through signing. Copy the finished
# bundle back without resource forks or extended attributes, then verify the
# exact artifact the user will launch.
mkdir -p "${DIST_DIR}"
COPYFILE_DISABLE=1 ditto --norsrc --noextattr --noqtn "${APP_DIR}" "${DIST_APP_DIR}"

verified=false
for attempt in 1 2 3; do
    xattr -cr "${DIST_APP_DIR}"
    find "${DIST_APP_DIR}" -name "._*" -delete
    if codesign --verify --deep --strict --verbose=2 "${DIST_APP_DIR}"; then
        verified=true
        break
    fi
    sleep 0.2
done
if [[ "${verified}" != true ]]; then
    echo "ERROR: the copied app failed strict signature verification." >&2
    exit 1
fi

echo "Built: ${DIST_APP_DIR}"
echo "Move it into /Applications, then double-click to launch."
