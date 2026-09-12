# HANOII.md

Personal notes for the `custom` branch. Not for upstream.

## Goal

Run screenpipe as a local-only tool: no screenpipe account, no cloud login,
no free-tier limits. Keep the patch tiny so `git rebase upstream/main` stays
cheap.

## Findings

- Old forced 7-day retention for free accounts was removed upstream in
  `79321df68` (PR #6146). Nothing deletes data by plan anymore.
- The visible "only a couple of days" in the timeline is the newer
  24-hour history access limit from `d950d9226` (PR #6630):
  - `crates/screenpipe-engine/src/history_access.rs` holds the live policy
    (`FREE_HISTORY_HOURS = 24`).
  - `src-tauri/src/recording.rs` `refresh_history_access_policy()` sets it
    from `SettingsStore::is_free_or_unattributed_user()`.
  - `src-tauri/src/commands.rs` re-applies it after `loadUser` and falls
    back to restricted when settings cannot be read.
  - Engine routes (`search.rs`, `streaming.rs`, `frames.rs`, `content.rs`)
    and the Swift/TS timelines all read that one policy, so unlocking the
    native side unlocks every surface.
- JPEG screenshots are compacted into MP4 chunks after 10 minutes
  (`snapshot_compaction.rs`); missing JPGs are expected, not a limit.
- Login gating: `startup_auth::bootstrap` resolves `NotRequired` when
  `should_skip_onboarding()` is true. `NotRequired` disables the frontend
  `AppEntitlementGate`, marks onboarding complete, and skips trial paywall
  checks. Server auto-start still needs `local_plan_policy()` to be
  non-`Unknown`, and recording gates on the same.
- Other free-plan knobs that hang off `is_free_or_unattributed_user()`:
  activity history restriction (`activity_history.rs`) and the 2 pipe cap
  in `commands.rs`.

## The patch

One constant, `src-tauri/src/local_only.rs` (`LOCAL_ONLY = true`), read in
four places:

- `main.rs` `should_skip_onboarding()` returns true. Effect: no login,
  onboarding auto-completed, no trial paywall, entitlement gate off.
- `store.rs` `local_plan_policy()` returns `VerifiedPaid`. Effect: server
  and recording start, history unrestricted, activity history unrestricted,
  pipe cap off.
- `commands.rs` two fallbacks for missing settings no longer restrict.

Set `LOCAL_ONLY = false` to get stock upstream behavior back.

## Rebase

`./rebuild.sh` does the whole loop: sync `main` with upstream, push main and
tags, rebase `custom` onto the latest `app-v*` tag, build, and copy the
install command to the clipboard. Manual equivalent:

```sh
git fetch upstream
git rebase upstream/main
```

If a hunk conflicts, re-apply the one-line `crate::local_only::LOCAL_ONLY`
check at the equivalent spot. Verify with:

```sh
cd apps/screenpipe-app-tauri
bun run test:tauri store::tests -- recording::history_access_tests startup_auth::tests
```

Plan-derived tests in `store::tests` that assert free/unknown behavior are
expected to fail while `LOCAL_ONLY = true`.

## Building and running the patched app

Use a release build, not `build:tauri:dev`:

- Debug builds already bypass entitlement via `cfg!(debug_assertions)`, so
  they cannot prove `LOCAL_ONLY` works.
- Debug builds apply `dev_isolation.rs`: data in `~/.screenpipe-dev`, API
  port 3130, focus port 11535. Release uses `~/.screenpipe` and 3030.
- `debug-dev` compiles first-party crates at opt-level 0. Too slow for
  always-on capture.
- `scripts/build_macos.sh` is also `debug-dev`, only signed for stable TCC.

The desktop app embeds the engine (`server_core.rs`, `capture_session.rs`).
No separate `screenpipe` CLI binary is needed. Skip the root
`cargo build --release` steps in `CONTRIBUTING.md`.

```fish
# quit the installed screenpipe first: same data dir, same port 3030
cd apps/screenpipe-app-tauri
bun install
set -gx APPLE_SIGNING_IDENTITY (security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)
bun tauri build --bundles app --config src-tauri/tauri.local.conf.json
cp -R "src-tauri/target/release/bundle/macos/screenpipe - Development.app" /Applications/
open "/Applications/screenpipe - Development.app"
```

`src-tauri/tauri.local.conf.json` mirrors what `release-app.yml` does for
arm64: it moves `mlx.metallib` from `bundle.macOS.files` to `externalBin` so
Tauri signs it as a sidecar, and drops the 0-byte `libonnxruntime.dylib`
placeholder. Without it, signing with a real identity fails with
`code object is not signed at all` on `Contents/MacOS/mlx.metallib`.
The `null` entries rely on Tauri's RFC 7396 merge, which deletes keys.

Bundle id is `screenpi.pe.dev`, so it coexists with the installed app in
`/Applications` but shares `~/.screenpipe`. Never run both at once.

## Code signing for stable TCC permissions

macOS keys Screen Recording, Microphone, and Accessibility grants on bundle
id plus signing identity. Ad-hoc signatures change every build, so grants
break after each rebuild. Signing with one stable cert keeps them.

A free Apple ID is enough: Xcode, Settings, Accounts, Manage Certificates,
add "Apple Development". No paid program, no notarization, local run only.
Cert expires yearly; regenerating it means re-granting permissions once.

Check the identity is usable from the CLI:

```sh
security find-identity -v -p codesigning
```

If Xcode shows the cert but this prints `0 valid identities found`, the
chain is untrusted. Cause on 2026-09-08: login keychain only had the old
"Apple Worldwide Developer Relations" intermediate, expired 2023-02-07,
while the dev cert is issued by WWDR G3. Fix:

```sh
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG6.cer
security add-certificates -k ~/Library/Keychains/login.keychain-db \
  AppleWWDRCAG3.cer AppleWWDRCAG6.cer
```

Verify: `security verify-cert -c <dev-cert.pem>` should succeed. Apple's
CA list: https://www.apple.com/certificateauthority/

Tauri reads `APPLE_SIGNING_IDENTITY` from the environment. No
`signingIdentity` is set in any `tauri.*.conf.json`. The same variable
overrides the hardcoded default in `scripts/build_macos.sh`.

## Generated schema noise

Every native build (`bun tauri build`, `bun run test:tauri`, `dev:tauri`)
rewrites the tracked files in `src-tauri/gen/schemas/`. They are marked
assume-unchanged in this checkout so `git status` stays clean:

```sh
git ls-files apps/screenpipe-app-tauri/src-tauri/gen/schemas/ | xargs git update-index --assume-unchanged
git ls-files -v apps/screenpipe-app-tauri/src-tauri/gen/schemas/   # 'h' prefix = hidden
```

Caveats:

- The flag lives in `.git/index`, not in the repo. A fresh clone or
  worktree needs the command again.
- If upstream changes those files, `git rebase` or `git checkout` can fail
  with "would be overwritten". Undo, restore, redo:

```sh
git ls-files apps/screenpipe-app-tauri/src-tauri/gen/schemas/ | xargs git update-index --no-assume-unchanged
git checkout -- apps/screenpipe-app-tauri/src-tauri/gen/schemas/
```

- Never commit those files from this branch. Upstream regenerates them.
