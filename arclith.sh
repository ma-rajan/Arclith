#!/usr/bin/env bash
# ARCLITH command entry point.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "${1:-help}" in
  install) exec "$ROOT_DIR/install/install.sh" "${@:2}" ;;
  bootstrap) exec "$ROOT_DIR/install/bootstrap.sh" "${@:2}" ;;
  update) exec "$ROOT_DIR/install/update.sh" "${@:2}" ;;
  uninstall) exec "$ROOT_DIR/install/uninstall.sh" "${@:2}" ;;
  detect) exec "$ROOT_DIR/hardware/detect.sh" "${@:2}" ;;
  help|-h|--help)
    cat <<'EOF'
Usage: ./arclith.sh <command>

Commands:
  install     Install an ARCLITH profile
  bootstrap   Prepare the system prerequisites
  update      Update ARCLITH-managed configuration
  uninstall   Remove ARCLITH-managed configuration
  detect      Detect supported graphics hardware
EOF
    ;;
  *) echo "Unknown command: $1" >&2; exit 2 ;;
esac
