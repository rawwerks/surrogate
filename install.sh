#!/usr/bin/env bash
set -euo pipefail

# surrogate installer — copies binaries to ~/.local/bin/

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Installing surrogate to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"

cp "$SCRIPT_DIR/bin/surrogate" "$INSTALL_DIR/surrogate"
chmod +x "$INSTALL_DIR/surrogate"

cp "$SCRIPT_DIR/bin/surrogate-shell-setup" "$INSTALL_DIR/surrogate-shell-setup"
chmod +x "$INSTALL_DIR/surrogate-shell-setup"

echo "Installed:"
echo "  $INSTALL_DIR/surrogate"
echo "  $INSTALL_DIR/surrogate-shell-setup"
echo ""
echo "To auto-wrap all terminals in zmx sessions:"
echo "  surrogate-shell-setup --install"
