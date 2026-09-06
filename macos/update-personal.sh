#!/usr/bin/env bash
# Downloads only releases from Niels' fork. Never runs cargo install from upstream.
set -euo pipefail
REPO=nielsandersen/ai-usagebar
ARCH="$(uname -m)"
TAG="${1:-}"
if [ -z "$TAG" ]; then
  TAG="$(gh api "repos/$REPO/releases" --jq '[.[] | select(.draft == false and (.tag_name | startswith("macos-v")))][0].tag_name')"
fi
case "$TAG" in macos-v*) ;; *) echo 'No personal macOS release found' >&2; exit 1 ;; esac
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ARCHIVE="ai-usagebar-macos-$ARCH.tar.gz"
gh release download "$TAG" --repo "$REPO" --dir "$WORK" --pattern "$ARCHIVE" --pattern "$ARCHIVE.sha256"
(cd "$WORK" && shasum -a 256 -c "$ARCHIVE.sha256" && tar -xzf "$ARCHIVE")
python3 "$WORK/ai-usagebar-macos-$ARCH/install.py"
