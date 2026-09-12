#!/usr/bin/env bash
# Personal helper for the `custom` branch. Not for upstream. See HANOII.md.
#
# 1. Sync main with upstream/main and push it (plus all tags) to origin.
# 2. Rebase `custom` onto the latest app-v* release tag.
# 3. Build the signed local-only release app.
# 4. Print the install command and copy it to the clipboard.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$REPO_ROOT/apps/screenpipe-app-tauri"
SCHEMAS_DIR="apps/screenpipe-app-tauri/src-tauri/gen/schemas"
# Signing identity: APPLE_SIGNING_IDENTITY from the environment wins, else
# the first valid "Apple Development" cert in the keychain.
find_signing_identity() {
  security find-identity -v -p codesigning \
    | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' \
    | head -1
}
SIGNING_IDENTITY="${APPLE_SIGNING_IDENTITY:-$(find_signing_identity)}"
BUNDLE_PATH="$APP_DIR/src-tauri/target/release/bundle/macos/screenpipe - Development.app"
INSTALL_CMD="cp -R \"$BUNDLE_PATH\" /Applications/ && open \"/Applications/screenpipe - Development.app\""

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

schemas_unhide() {
  git ls-files "$SCHEMAS_DIR" | xargs git update-index --no-assume-unchanged
  git checkout -- "$SCHEMAS_DIR"
}

schemas_hide() {
  git ls-files "$SCHEMAS_DIR" | xargs git update-index --assume-unchanged
}

cd "$REPO_ROOT"

[ -n "$SIGNING_IDENTITY" ] || die "no valid 'Apple Development' signing identity found (security find-identity -v -p codesigning); see HANOII.md"

if [ -n "$(git status --porcelain)" ]; then
  die "working tree not clean; commit or stash first"
fi

# The assume-unchanged flag on gen/schemas makes checkout/rebase fail with
# "would be overwritten" when upstream touches those files. Drop it for the
# git operations and restore it at the end.
log "Restoring generated schema files"
schemas_unhide
trap 'schemas_hide' EXIT

log "Fetching upstream"
git fetch upstream --tags

log "Merging upstream/main into main"
git checkout main
git merge --no-edit upstream/main

log "Pushing main and tags to origin"
git push origin main
git push origin --tags

RELEASE_TAG="$(git tag --list 'app-v*' --sort=-v:refname | head -1)"
[ -n "$RELEASE_TAG" ] || die "no app-v* tag found"

log "Rebasing custom onto $RELEASE_TAG"
git checkout custom
if ! git rebase "$RELEASE_TAG"; then
  cat >&2 <<MSG

Rebase onto $RELEASE_TAG hit a conflict.
Re-apply the one-line crate::local_only::LOCAL_ONLY check at the equivalent
spot (see HANOII.md), then:

  git add -A && git rebase --continue

Verify with:

  cd apps/screenpipe-app-tauri
  bun run test:tauri store::tests -- recording::history_access_tests startup_auth::tests

Then rerun ./rebuild.sh (it is safe to rerun; the rebase becomes a no-op).
MSG
  exit 1
fi

log "Building release app (signed as: $SIGNING_IDENTITY)"
cd "$APP_DIR"
bun install
APPLE_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  bun tauri build --bundles app --config src-tauri/tauri.local.conf.json

[ -d "$BUNDLE_PATH" ] || die "build finished but bundle not found at: $BUNDLE_PATH"

printf '%s' "$INSTALL_CMD" | pbcopy

cat <<MSG

Build done: custom is rebased onto $RELEASE_TAG.
Quit the running screenpipe app (same data dir and port 3030), then run the
install command. It is already on your clipboard:

  $INSTALL_CMD

MSG
