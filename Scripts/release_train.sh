#!/bin/bash
set -euo pipefail

# Public releases are one train: combined, Claude-only, and GPT-only. Every
# checkout is tested, signed, notarized, stapled, and assessed before any tag
# or GitHub release is published.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ "$(git branch --show-current)" != "main" ]]; then
    echo "ERROR: run the release train from a clean main branch." >&2
    exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: commit or stash every change before releasing." >&2
    exit 1
fi
if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "ERROR: set NOTARY_PROFILE to a stored notarytool Keychain profile." >&2
    exit 1
fi
command -v gh >/dev/null || { echo "ERROR: gh is required." >&2; exit 1; }

git fetch origin main claude-session-pinger gpt-session-pinger --tags

TRAIN_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ai-session-release.XXXXXX")"
COMBINED_CHECKOUT="$TRAIN_ROOT/combined"
CLAUDE_CHECKOUT="$TRAIN_ROOT/claude"
GPT_CHECKOUT="$TRAIN_ROOT/gpt"
ASSET_DIR="$TRAIN_ROOT/assets"
mkdir -p "$ASSET_DIR"

cleanup() {
    git worktree remove --force "$COMBINED_CHECKOUT" >/dev/null 2>&1 || true
    git worktree remove --force "$CLAUDE_CHECKOUT" >/dev/null 2>&1 || true
    git worktree remove --force "$GPT_CHECKOUT" >/dev/null 2>&1 || true
    rm -rf "$TRAIN_ROOT"
}
trap cleanup EXIT

git worktree add --detach "$COMBINED_CHECKOUT" HEAD
git worktree add --detach "$CLAUDE_CHECKOUT" origin/claude-session-pinger
git worktree add --detach "$GPT_CHECKOUT" origin/gpt-session-pinger

CHECKOUTS=("$COMBINED_CHECKOUT" "$CLAUDE_CHECKOUT" "$GPT_CHECKOUT")
LABELS=("Session Tracker" "Claude Session Pinger" "GPT Usage Tracker")
APP_NAMES=("Session Tracker.app" "Session Pinger.app" "GPT Usage Tracker.app")
ASSET_NAMES=("SessionTracker.app.zip" "ClaudeSessionPinger.app.zip" "GPTSessionPinger.app.zip")
TAG_PREFIXES=("tracker-v" "v" "gpt-v")
REFS=("HEAD" "origin/claude-session-pinger" "origin/gpt-session-pinger")

for index in 0 1 2; do
    checkout="${CHECKOUTS[$index]}"
    label="${LABELS[$index]}"
    app_name="${APP_NAMES[$index]}"
    asset_name="${ASSET_NAMES[$index]}"
    app_path="$checkout/dist/$app_name"
    staged_asset="$ASSET_DIR/$asset_name"
    verify_dir="$TRAIN_ROOT/verify-$index"

    echo "Preflighting $label..."
    (
        cd "$checkout"
        swift test --parallel
        DISTRIBUTION=1 ./Scripts/build_app.sh
        rm -f "$staged_asset"
        COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app_path" "$staged_asset"
        xcrun notarytool submit "$staged_asset" --keychain-profile "$NOTARY_PROFILE" --wait
        xcrun stapler staple "$app_path"
        xcrun stapler validate "$app_path"
        spctl --assess --type execute --verbose=4 "$app_path"
        codesign --verify --deep --strict --verbose=2 "$app_path"
        rm -f "$staged_asset"
        COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --noqtn --noacl --keepParent "$app_path" "$staged_asset"
        rm -rf "$verify_dir"
        mkdir -p "$verify_dir"
        ditto -x -k --norsrc --noextattr --noqtn "$staged_asset" "$verify_dir"
        codesign --verify --deep --strict --verbose=2 "$verify_dir/$app_name"
    )
done

# Nothing reaches GitHub until all three applications pass the complete gate.
for index in 0 1 2; do
    checkout="${CHECKOUTS[$index]}"
    asset_name="${ASSET_NAMES[$index]}"
    ref="${REFS[$index]}"
    version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$checkout/Resources/Info.plist")
    tag="${TAG_PREFIXES[$index]}${version}"
    sha=$(git rev-parse "$ref")
    notes=$(awk "/^## v${version}/{flag=1; next} /^## /{flag=0} flag" "$checkout/CHANGELOG.md")
    [[ -n "$notes" ]] || { echo "ERROR: CHANGELOG.md has no v${version} entry for ${LABELS[$index]}." >&2; exit 1; }

    if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
        tagged_sha=$(git rev-list -n 1 "$tag")
        if [[ "$tagged_sha" != "$sha" ]]; then
            echo "ERROR: $tag already points at a different commit." >&2
            exit 1
        fi
    else
        git tag "$tag" "$sha"
    fi
    git push origin "refs/tags/$tag"

    if gh release view "$tag" >/dev/null 2>&1; then
        gh release upload "$tag" "$ASSET_DIR/$asset_name" --clobber
    else
        gh release create "$tag" "$ASSET_DIR/$asset_name" --title "$tag" --notes "$notes"
    fi
done

echo "Released all three applications from one verified release train."
