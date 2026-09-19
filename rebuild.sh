#!/usr/bin/env bash
# Personal helper for the `custom` branch. Not for upstream. See HANOII.md.
#
# 1. Sync main with upstream/main and push it (plus all tags) to origin.
# 2. Rebase `custom` onto the latest app-v* release tag (or main with --main).
#    custom is force-pushed (with lease) to origin on every run, like main,
#    whether or not there was anything to rebase or the build succeeds.
# 3. Build the signed local-only release app.
# 4. Print the install command and copy it to the clipboard.
#
# Stops after syncing main when custom already contains the rebase target
# (no new app-v* tag, or with --main no new commits on main); --force rebuilds
# anyway. --main picks up unreleased upstream fixes.
set -euo pipefail

FORCE=0
USE_MAIN=0
for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --main) USE_MAIN=1 ;;
    *) echo "usage: $0 [--main] [--force]" >&2; exit 2 ;;
  esac
done

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

# custom is rewritten by the rebase, so a plain push is rejected.
# --force-with-lease refuses to clobber commits pushed from elsewhere;
# --force-if-includes additionally requires those commits to have been
# integrated locally (guards against a stale origin/custom after a fetch).
push_custom() {
  log "Pushing custom to origin"
  git push --force-with-lease --force-if-includes origin custom
}

schemas_unhide() {
  git ls-files "$SCHEMAS_DIR" | xargs git update-index --no-assume-unchanged
  git checkout -- "$SCHEMAS_DIR"
}

schemas_hide() {
  git ls-files "$SCHEMAS_DIR" | xargs git update-index --assume-unchanged
}

cd "$REPO_ROOT"

[ -n "$SIGNING_IDENTITY" ] || die "no valid 'Apple Development' signing identity found (security find-identity -v -p codesigning); see HANOII.md"

# The assume-unchanged flag on gen/schemas makes checkout/rebase fail with
# "would be overwritten" when upstream touches those files. Drop it for the
# git operations and restore it at the end. Restoring the files first also
# keeps build-generated noise out of the clean-tree check below.
log "Restoring generated schema files"
schemas_unhide
trap 'schemas_hide' EXIT

if [ -n "$(git status --porcelain)" ]; then
  die "working tree not clean; commit or stash first"
fi

log "Fetching upstream"
git fetch upstream --tags

log "Merging upstream/main into main"
git checkout main
git merge --no-edit upstream/main

log "Pushing main and tags to origin"
git push origin main
git push origin --tags

if [ "$USE_MAIN" = 1 ]; then
  TARGET=main
  TARGET_DESC="main ($(git rev-parse --short main))"
else
  TARGET="$(git tag --list 'app-v*' --sort=-v:refname | head -1)"
  [ -n "$TARGET" ] || die "no app-v* tag found"
  TARGET_DESC="$TARGET"
fi

# Only a target custom does not contain yet triggers a rebuild: a new release
# tag, or with --main new commits on main. Without --main, unreleased commits
# on main are ignored.
if [ "$FORCE" = 0 ] && git merge-base --is-ancestor "$TARGET" custom; then
  cat <<MSG

Nothing new: custom is already rebased onto $TARGET_DESC.
Run ./rebuild.sh --force to rebuild anyway$([ "$USE_MAIN" = 1 ] || printf ', or --main to pick up unreleased main').
MSG
  git checkout custom
  push_custom
  exit 0
fi

log "Rebasing custom onto $TARGET_DESC"
git checkout custom
if ! git rebase "$TARGET"; then
  cat >&2 <<MSG

Rebase onto $TARGET_DESC hit a conflict.
Re-apply the one-line crate::local_only::LOCAL_ONLY check at the equivalent
spot (see HANOII.md), then:

  git add -A && git rebase --continue

Verify with:

  cd apps/screenpipe-app-tauri
  bun run test:tauri store::tests -- recording::history_access_tests startup_auth::tests

Then rerun ./rebuild.sh with the same flags plus --force (the rebase becomes
a no-op, and --force skips the nothing-new stop so the build still runs).
MSG
  exit 1
fi

push_custom

log "Building release app (signed as: $SIGNING_IDENTITY)"
cd "$APP_DIR"
BUILD_MARKER="$(mktemp)"
bun install
APPLE_SIGNING_IDENTITY="$SIGNING_IDENTITY" \
  bun tauri build --bundles app --config src-tauri/tauri.local.conf.json

[ -d "$BUNDLE_PATH" ] || die "build finished but bundle not found at: $BUNDLE_PATH"
# A leftover bundle from an older build passes the check above. Upstream once
# renamed the product, and this script kept installing the stale app.
[ "$BUNDLE_PATH/Contents/MacOS/screenpipe-app" -nt "$BUILD_MARKER" ] \
  || die "bundle at $BUNDLE_PATH is older than this build; check productName in tauri.conf.json / tauri.local.conf.json"
rm -f "$BUILD_MARKER"

printf '%s' "$INSTALL_CMD" | pbcopy

cat <<MSG

Build done: custom is rebased onto $TARGET_DESC.
Quit the running screenpipe app (same data dir and port 3030), then run the
install command. It is already on your clipboard:

  $INSTALL_CMD

MSG
