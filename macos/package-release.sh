#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
VERSION="$(cargo metadata --no-deps --format-version 1 | python3 -c 'import json,sys; print(json.load(sys.stdin)["packages"][0]["version"])')"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo 'Unsupported architecture' >&2; exit 1 ;; esac
cargo build --release --locked --bins
./macos/build.sh
OUT="$ROOT/dist/ai-usagebar-macos-$ARCH"
mkdir -p "$OUT"
cp target/release/ai-usagebar target/release/ai-usagebar-tui macos/ai-usagebar-menubar "$OUT/"
cp macos/release/install.py "$OUT/"
printf '%s\n' "$VERSION" > "$OUT/VERSION"
(cd "$OUT" && shasum -a 256 ai-usagebar ai-usagebar-tui ai-usagebar-menubar install.py VERSION > SHA256SUMS)
(cd "$ROOT/dist" && tar -czf "ai-usagebar-macos-$ARCH.tar.gz" "ai-usagebar-macos-$ARCH" && shasum -a 256 "ai-usagebar-macos-$ARCH.tar.gz" > "ai-usagebar-macos-$ARCH.tar.gz.sha256")
echo "Package: $OUT"
