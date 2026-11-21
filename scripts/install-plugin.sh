#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/../plugins/vinyl-art-bridge.lua"

if [ -n "${CLIAMP_CONFIG_DIR:-}" ]; then
    CFG_DIR="$CLIAMP_CONFIG_DIR"
elif [ -n "${XDG_CONFIG_HOME:-}" ]; then
    CFG_DIR="$XDG_CONFIG_HOME/cliamp"
else
    CFG_DIR="$HOME/.config/cliamp"
fi

DEST_DIR="$CFG_DIR/plugins"
DEST="$DEST_DIR/vinyl-art-bridge.lua"

mkdir -p "$DEST_DIR"
cp "$SRC" "$DEST"
echo "Plugin copiato in: $DEST"
exec cliamp plugins trust vinyl-art-bridge "$@"
