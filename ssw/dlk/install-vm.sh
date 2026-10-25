#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="/ssw/dlk"

chmod +x "$SCRIPT_DIR/run-eks.sh" "$SCRIPT_DIR/client_eks" "$SCRIPT_DIR/setup-efs.sh"

sudo mkdir -p /ssw

if [[ -e "$TARGET" || -L "$TARGET" ]]; then
  if [[ -L "$TARGET" && "$(readlink -f "$TARGET")" == "$SCRIPT_DIR" ]]; then
    echo "[OK] $TARGET already points to $SCRIPT_DIR"
    exit 0
  fi

  echo "ERROR: $TARGET already exists and is not the expected symlink."
  echo "Move or back it up first; this script will not overwrite it."
  exit 1
fi

sudo ln -s "$SCRIPT_DIR" "$TARGET"

echo "[OK] $TARGET -> $SCRIPT_DIR"
echo
echo "Next:"
echo "  sudo bash /ssw/dlk/setup-efs.sh"
