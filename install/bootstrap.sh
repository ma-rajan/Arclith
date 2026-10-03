#!/usr/bin/env bash
set -euo pipefail

command -v pacman >/dev/null || { echo "ARCLITH requires Arch Linux (pacman was not found)." >&2; exit 1; }
echo "Bootstrap stage placeholder."
