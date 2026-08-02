#!/bin/bash
set -euo pipefail

APP_NAME="GPT Session Pinger"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

BUILD_DIR=".build/release"
DIST_DIR="dist"
DIST_APP_DIR="${DIST_DIR}/${APP_NAME}.app"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/session-pinger-build.XXXXXX")"
APP_DIR="${WORK_DIR}/${APP_NAME}.app"
trap 'rm -rf "${WORK_DIR}"' EXIT

swift build -c release

rm -rf "${DIST_DIR}"
mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"

cp "${BUILD_DIR}/GPTSessionPinger" "${APP_DIR}/Contents/MacOS/GPTSessionPinger"
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

# Sign with a stable code-signing identity if one is available, so the app's
# code identity stays the same across updates and the macOS keychain does not
# re-prompt for access every time you update. Falls back to ad-hoc signing
# (which changes every build, causing keychain re-prompts) if no identity is
# found. Override the identity name with CODESIGN_IDENTITY if needed.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-Apple Development}"
if security find-identity -v -p codesigning | grep -q "${SIGN_IDENTITY}"; then
    echo "Signing with identity: ${SIGN_IDENTITY}"
    codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP_DIR}"
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
