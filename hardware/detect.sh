#!/usr/bin/env bash
set -euo pipefail

if ! command -v lspci >/dev/null; then
  echo "Cannot detect graphics hardware: lspci is not installed." >&2
  exit 1
fi

lspci -nn | grep -Ei 'vga|3d|display' || true
