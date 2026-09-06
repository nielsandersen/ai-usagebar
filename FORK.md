# Niels’ personal AI Usage Bar

The supported personal branch is `codex/macos-personal` in https://github.com/nielsandersen/ai-usagebar. `upstream` points to the original project; `main` in the fork is the upstream baseline. The first personal commit preserves the custom macOS design independently of the authentication repair.

## What stays

The existing rings, provider marks, compact/icon/text modes, English labels, menu layout, colors, usage windows, multi-provider overview, account menus, shortcuts, and preferences are preserved. There is no upstream redesign in this release.

## Mac authentication

Background monitoring reads Claude Code’s default and named Keychain logins without rotating their refresh tokens. Claude Code owns those logins and does not share the usage bar’s refresh lock. If a token is rejected, cached usage remains visible with an instruction to open Claude Code. File-backed accounts and inactive Desktop snapshots retain their existing behavior; Linux is unchanged.

Explicit account changes still work. Keychain writes go through `/usr/bin/security -i` over stdin, with properly escaped compact JSON and a 15-second deadline. They do not add trusted applications, reset the keychain, or expose tokens in process arguments. Inputs of 4096 bytes or more after escaping are rejected before writing, because Apple’s interactive reader truncates longer lines. Large account blobs must be managed through Claude Code. Read-only monitoring is not limited by this write size.

The known upstream issue is https://github.com/akitaonrails/ai-usagebar/issues/148. This release prevents recurrence; it does not silently rewrite existing Keychain permissions.

## Install or update

Download the ARM64 release archive and its `.sha256` file from this fork’s Releases page. Verify with `shasum -a 256 -c ai-usagebar-macos-arm64.tar.gz.sha256`, unpack, then run `python3 ai-usagebar-macos-arm64/install.py`.

From a source checkout with GitHub CLI installed, `./macos/update-personal.sh` downloads and verifies the latest personal release. Pass a specific `macos-v...` tag to select a version. Do not use `cargo install ai-usagebar` to update this edition: it installs the upstream backend.

Installations live in `~/.local/share/ai-usagebar/versions/<version>` with a `current` symlink. The installer selects that backend and TUI, preserves the remaining preferences, and starts the matching menu bar. Subsequent updates preserve your launch-at-login choice. When login launch is disabled, quit any running copy and reopen the printed executable path after updating; the installer does not spawn an unmanaged duplicate. `--no-start` only stages a verified package; it changes neither the active version nor login settings. Failed activation restores the prior link, backend preference, and LaunchAgent. Old source checkouts and binaries are not removed. Do not launch an old copy manually alongside the installed app.

To roll back after a subsequent personal update:

```sh
python3 ~/.local/share/ai-usagebar/current/install.py --rollback
```

The first personal installation has no previous personal version; the original LaunchAgent is backed up under `~/.local/share/ai-usagebar/backups`. Original upstream executables remain available but contain the authentication bug.

## Development and releases

1. Branch from `codex/macos-personal`; keep changes to the custom Swift interface separate from upstream fixes.
2. Fetch `upstream` and inspect changes before selectively cherry-picking or merging. Never reset the personal branch to upstream.
3. Run `make test`, `cargo clippy --all-targets --locked -- -D warnings`, `cargo fmt --all -- --check`, `./macos/run-tests.sh`, and `python3 -m unittest discover -s macos/release -p 'test_*.py'`.
4. On an interactive Mac, run `cargo test --lib keychain_round_trip_preserves_access -- --ignored`. This creates and deletes a disposable keychain containing fake credentials. It verifies exact access-control preservation, repeated writes, Unicode round trips, and rejection without overwriting data. Disposable keychains may use legacy ACLs, so the test does not assert a particular login-keychain partition format.
5. Bump Cargo.toml, Cargo.lock, manifest.json, and CHANGELOG.md together. Personal versions use `1.4.1-niels.1`, etc. Keep crates.io publishing disabled.
6. Run `./macos/package-release.sh` and verify the installed app plus a Claude Code request.
7. Commit and push the personal branch. Create an immutable annotated `macos-v<version>` tag and push it. The personal macOS workflow tests, builds, and publishes an ARM64 archive with checksums.

This macOS release process supersedes the inherited upstream AUR/Linux release checklist. The AUR files remain a historical upstream snapshot and are not published from this fork. Never use upstream-style `v...` tags for personal builds.
