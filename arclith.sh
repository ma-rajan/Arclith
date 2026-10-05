#!/usr/bin/env bash
# ARCLITH — Modular Arch Linux Configuration Framework
# Phase 1: command-line interface foundation.

set -Eeuo pipefail
IFS=$'\n\t'

readonly ARCLITH_VERSION="0.1.0"
readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

supports_color() {
  [[ -t 1 ]] && command_exists tput && [[ "$(tput colors 2>/dev/null || printf '0')" -ge 8 ]]
}

if supports_color; then
  readonly COLOR_RESET=$'\033[0m'
  readonly COLOR_BLUE=$'\033[1;34m'
  readonly COLOR_GREEN=$'\033[1;32m'
  readonly COLOR_YELLOW=$'\033[1;33m'
  readonly COLOR_RED=$'\033[1;31m'
else
  readonly COLOR_RESET=""
  readonly COLOR_BLUE=""
  readonly COLOR_GREEN=""
  readonly COLOR_YELLOW=""
  readonly COLOR_RED=""
fi

log() {
  printf '%b[INFO]%b %s\n' "$COLOR_BLUE" "$COLOR_RESET" "$*"
}

warn() {
  printf '%b[WARN]%b %s\n' "$COLOR_YELLOW" "$COLOR_RESET" "$*" >&2
}

error() {
  printf '%b[ERROR]%b %s\n' "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

success() {
  printf '%b[OK]%b %s\n' "$COLOR_GREEN" "$COLOR_RESET" "$*"
}

print_banner() {
  printf '\n'
  printf '%b' "$COLOR_BLUE"
  cat <<'EOF'
    _    ____   ____ _     ___ _____ _   _
   / \  |  _ \ / ___| |   |_ _|_   _| | | |
  / _ \ | |_) | |   | |    | |  | | | |_| |
 / ___ \|  _ <| |___| |___ | |  | | |  _  |
/_/   \_\_| \_\\____|_____|___| |_| |_| |_|
EOF
  printf '%b' "$COLOR_RESET"
  printf '  Modular Arch Linux Configuration Framework  •  v%s\n\n' "$ARCLITH_VERSION"
}

print_usage() {
  cat <<'EOF'
Usage:
  ./arclith.sh <command>

Commands:
  install       Install ARCLITH (planned)
  configure     Configure ARCLITH modules (planned)
  hardware      Show read-only system and hardware information
  profile       Manage ARCLITH profiles (planned)
  update        Update ARCLITH-managed components (planned)
  uninstall     Remove ARCLITH-managed components (planned)
  info          Show project information
  help          Show this help message

Options:
  -h, --help     Show this help message
  -v, --version  Show the ARCLITH version

Run without a command to open the interactive menu.
EOF
}

not_implemented() {
  local feature=$1
  warn "The '${feature}' command is not implemented yet. It is planned for a future ARCLITH phase."
}

show_info() {
  log "ARCLITH version: $ARCLITH_VERSION"
  log "Project root: $PROJECT_ROOT"
  log "Status: Early development — Phase 1 CLI foundation"
}

show_menu() {
  cat <<'EOF'
Choose an action:
  1) Install
  2) Configure
  3) Hardware
  4) Profile
  5) Update
  6) Uninstall
  7) Information
  8) Help
  0) Exit
EOF
}

run_command() {
  local selected_command=$1

  case "$selected_command" in
    hardware)
      exec "$PROJECT_ROOT/hardware/detect.sh"
      ;;
    install|configure|profile|update|uninstall)
      not_implemented "$selected_command"
      ;;
    info)
      show_info
      ;;
    help|-h|--help)
      print_usage
      ;;
    --version|-v)
      printf 'ARCLITH %s\n' "$ARCLITH_VERSION"
      ;;
    *)
      error "Unknown command: $selected_command"
      printf 'Run %s help to see available commands.\n' "${0##*/}" >&2
      return 2
      ;;
  esac
}

interactive_menu() {
  local choice command_name

  if [[ ! -t 0 ]]; then
    warn "No interactive terminal is available; showing help instead."
    print_usage
    return 0
  fi

  show_menu
  if ! read -r -p "Select an option [0-8]: " choice; then
    printf '\n'
    warn "No menu selection was received."
    return 0
  fi
  printf '\n'

  case "$choice" in
    1) command_name="install" ;;
    2) command_name="configure" ;;
    3) command_name="hardware" ;;
    4) command_name="profile" ;;
    5) command_name="update" ;;
    6) command_name="uninstall" ;;
    7) command_name="info" ;;
    8) command_name="help" ;;
    0) success "Goodbye."; return 0 ;;
    *) error "Invalid selection: ${choice:-<empty>}"; return 2 ;;
  esac

  run_command "$command_name"
}

main() {
  print_banner

  if (( $# == 0 )); then
    interactive_menu
    return
  fi

  if (( $# > 1 )); then
    error "Only one command may be supplied."
    print_usage >&2
    return 2
  fi

  run_command "$1"
}

main "$@"
