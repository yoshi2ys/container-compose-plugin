#!/usr/bin/env bash
# Build the `compose` CLI plugin and install it for Apple's `container` tool.
# After install: `container system start` then `container compose --help`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
DEST="/usr/local/libexec/container-plugins/compose"

echo "==> Building release binary"
swift build -c release --package-path "$ROOT"
BIN="$(swift build -c release --package-path "$ROOT" --show-bin-path)/compose"
[ -x "$BIN" ] || { echo "error: built binary not found at $BIN" >&2; exit 1; }

echo "==> Installing to $DEST (sudo may prompt)"
sudo mkdir -p "$DEST/bin"
sudo cp "$ROOT/plugin/config.toml" "$DEST/config.toml"
sudo cp "$BIN" "$DEST/bin/compose"

echo "==> Installed. Verify with:"
echo "    container system start"
echo "    container --help        # 'compose' should appear under PLUGINS"
echo "    container compose --help"
