#!/usr/bin/env sh
# git-stack installer.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/tsaodown/git-stack/main/install.sh | sh
#
# Environment:
#   INSTALL_DIR     destination directory (default: $HOME/.local/bin)
#   GIT_STACK_REF   git ref (branch, tag, or SHA) to install (default: main)
#
# Behavior: downloads bin/git-stack at the given ref, places it at
# $INSTALL_DIR/git-stack, makes it executable, and prints next-step
# shell-integration instructions for the user's current shell.

set -eu

INSTALL_DIR="${INSTALL_DIR:-$HOME/.local/bin}"
REF="${GIT_STACK_REF:-main}"
URL="https://raw.githubusercontent.com/tsaodown/git-stack/${REF}/bin/git-stack"
TARGET="${INSTALL_DIR}/git-stack"

say() { printf '%s\n' "$*"; }
err() { printf 'install.sh: error: %s\n' "$*" >&2; exit 1; }

command -v curl >/dev/null 2>&1 || err "curl is required"

mkdir -p "$INSTALL_DIR"

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

if ! curl -fsSL "$URL" -o "$tmp"; then
  err "failed to download $URL"
fi

# Quick sanity check: must look like a bash script.
head -n1 "$tmp" | grep -q '^#!' || err "downloaded file does not look like a script"

mv "$tmp" "$TARGET"
chmod 755 "$TARGET"
trap - EXIT

say "installed git-stack to $TARGET"

# PATH check.
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) say ""; say "warning: $INSTALL_DIR is not on your \$PATH." ;;
esac

# Shell-integration hint based on $SHELL.
shell_name=$(basename "${SHELL:-}")
say ""
say "next: add shell integration for the gstk* aliases."
case "$shell_name" in
  bash) say "  echo 'eval \"\$(git stack init bash)\"' >> ~/.bashrc" ;;
  zsh)  say "  echo 'eval \"\$(git stack init zsh)\"'  >> ~/.zshrc" ;;
  fish) say "  echo 'git stack init fish | source' >> ~/.config/fish/config.fish" ;;
  *)    say "  bash: eval \"\$(git stack init bash)\" in ~/.bashrc"
        say "  zsh:  eval \"\$(git stack init zsh)\"  in ~/.zshrc"
        say "  fish: git stack init fish | source     in config.fish" ;;
esac
say ""
say "then reload your shell. run 'git stack help' to see commands."
