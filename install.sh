#!/usr/bin/env bash
set -euo pipefail

# surrogate installer — copies binaries to ~/.local/bin/
# Works on Linux (any distro) and macOS.

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- helpers ---

info()  { echo "surrogate: $*"; }
warn()  { echo "surrogate: WARNING: $*" >&2; }
die()   { echo "surrogate: FATAL: $*" >&2; exit 1; }

detect_os() {
  case "$(uname -s)" in
    Linux*)  echo "linux" ;;
    Darwin*) echo "macos" ;;
    *)       echo "unknown" ;;
  esac
}

detect_pkg_manager() {
  if command -v pacman &>/dev/null; then echo "pacman"
  elif command -v apt-get &>/dev/null; then echo "apt"
  elif command -v dnf &>/dev/null; then echo "dnf"
  elif command -v yum &>/dev/null; then echo "yum"
  elif command -v apk &>/dev/null; then echo "apk"
  elif command -v zypper &>/dev/null; then echo "zypper"
  elif command -v brew &>/dev/null; then echo "brew"
  elif command -v nix-env &>/dev/null; then echo "nix"
  else echo "unknown"
  fi
}

install_dcg() {
  local dcg_url="https://raw.githubusercontent.com/Dicklesworthstone/destructive_command_guard/master/install.sh"
  local dcg_path="${INSTALL_DIR}/dcg"

  if [[ -x "$dcg_path" ]]; then
    info "  dcg: found at $dcg_path"
    return 0
  fi

  if command -v dcg &>/dev/null; then
    info "  dcg: found at $(command -v dcg)"
    return 0
  fi

  if [[ "${SURROGATE_SKIP_DCG:-0}" == "1" ]]; then
    warn "  dcg: skipped (SURROGATE_SKIP_DCG=1)"
    return 1
  fi

  info "  dcg: not found"
  info "  dcg: installing recommended safety guard"
  if curl -fsSL "${dcg_url}?$(date +%s)" | bash -s -- --easy-mode; then
    if [[ -x "$dcg_path" ]]; then
      info "  dcg: installed at $dcg_path"
      return 0
    fi
    if command -v dcg &>/dev/null; then
      info "  dcg: installed at $(command -v dcg)"
      return 0
    fi
  fi

  warn "  dcg: install failed"
  warn "  surrogate still works without dcg, but typing will be less guarded"
  echo "  Install manually: curl -fsSL \"${dcg_url}?\\$(date +%s)\" | bash -s -- --easy-mode"
  return 1
}

install_tmux_hint() {
  local pkg
  pkg="$(detect_pkg_manager)"
  case "$pkg" in
    pacman)  echo "sudo pacman -S tmux" ;;
    apt)     echo "sudo apt-get install -y tmux" ;;
    dnf)     echo "sudo dnf install -y tmux" ;;
    yum)     echo "sudo yum install -y tmux" ;;
    apk)     echo "sudo apk add tmux" ;;
    zypper)  echo "sudo zypper install -y tmux" ;;
    brew)    echo "brew install tmux" ;;
    nix)     echo "nix-env -iA nixpkgs.tmux" ;;
    *)       echo "# Install tmux using your package manager" ;;
  esac
}

# --- preflight ---

OS="$(detect_os)"

if [[ "$OS" == "unknown" ]]; then
  die "Unsupported OS: $(uname -s). Surrogate requires Linux or macOS."
fi

# --- install surrogate ---

info "Installing to $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"

cp "$SCRIPT_DIR/bin/surrogate" "$INSTALL_DIR/surrogate"
chmod +x "$INSTALL_DIR/surrogate"

cp "$SCRIPT_DIR/bin/surrogate-shell-setup" "$INSTALL_DIR/surrogate-shell-setup"
chmod +x "$INSTALL_DIR/surrogate-shell-setup"

cp "$SCRIPT_DIR/bin/surrogate-doctor" "$INSTALL_DIR/surrogate-doctor"
chmod +x "$INSTALL_DIR/surrogate-doctor"

info "Installed:"
info "  $INSTALL_DIR/surrogate"
info "  $INSTALL_DIR/surrogate-shell-setup"
info "  $INSTALL_DIR/surrogate-doctor"

# --- check PATH ---

if ! echo "$PATH" | tr ':' '\n' | grep -qx "$INSTALL_DIR"; then
  warn "$INSTALL_DIR is not in your PATH"
  echo "  Add to your shell rc file:"
  echo "    export PATH=\"$INSTALL_DIR:\$PATH\""
fi

# --- check dependencies ---

echo ""
info "Checking dependencies..."

if command -v tmux &>/dev/null; then
  info "  tmux: $(tmux -V)"
else
  warn "  tmux: NOT FOUND"
  echo "  Install with: $(install_tmux_hint)"
fi

if command -v zmx &>/dev/null; then
  info "  zmx: found at $(command -v zmx)"
else
  warn "  zmx: NOT FOUND"
  echo "  Install from: https://github.com/neurosnap/zmx"
  echo "  zmx is required for surrogate to work."
fi

echo ""
info "Checking recommended safety tooling..."
install_dcg || true

# --- next steps ---

echo ""
info "To auto-wrap all terminals in zmx sessions:"
info "  surrogate-shell-setup --install"
info "To skip dcg auto-install next time:"
info "  SURROGATE_SKIP_DCG=1 bash install.sh"
