#!/usr/bin/env bash
# ARCLITH — Modular Arch Linux Configuration Framework
# Phase 5: safe profile package installation.

set -Eeuo pipefail
IFS=$'\n\t'

readonly ARCLITH_VERSION="0.1.0"
readonly PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
PROFILE_PACKAGE_PLAN=()
PROFILE_PACKAGE_PLAN_SOURCES=()

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
  install       Install packages from a validated profile
  configure     Configure ARCLITH modules (planned)
  hardware      Show read-only system and hardware information
  profile       List, validate, inspect, or show a profile package plan
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
  log "Status: Active development — validated profile package installation"
}

validate_profile() {
  local profile_name=$1
  local quiet=${2:-false}
  PROFILE_PACKAGE_PLAN=()
  PROFILE_PACKAGE_PLAN_SOURCES=()
  local profile_directory="$PROJECT_ROOT/profiles/$profile_name"
  local profile_file="$profile_directory/profile.conf"
  local line=""
  local key=""
  local value=""
  local name=""
  local description=""
  local version=""
  local package_lists=""
  local package_list=""
  local package_line=""
  local trimmed_package=""
  local package_file=""
  local package_path=""
  local package_component=""
  local unsafe_package_path=0
  local line_number=0
  local has_error=0
  local -a package_list_names=()
  local -A seen_packages=()

  if [[ ! "$profile_name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    printf '    Invalid: profile name must start with a lowercase letter and contain only lowercase letters, digits, underscore, or hyphen\n'
    return 1
  fi

  if [[ ! -d "$profile_directory" || -L "$PROJECT_ROOT/profiles" || -L "$profile_directory" ]]; then
    printf '    Invalid: profile directory is missing (%s)\n' "$profile_directory"
    return 1
  fi
  if [[ ! -f "$profile_file" || ! -r "$profile_file" || -L "$profile_file" ]]; then
    printf '    Invalid: profile definition is missing or unreadable (%s)\n' "$profile_file"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line=${line%%#*}
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ! "$line" =~ ^([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      printf '    Invalid: malformed definition at line %d\n' "$line_number"
      has_error=1
      continue
    fi

    key=${BASH_REMATCH[1]}
    value=${BASH_REMATCH[2]}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$key" in
      NAME)
        if [[ -n "$name" || -z "$value" ]]; then
          printf '    Invalid: NAME must appear once and be non-empty\n'
          has_error=1
        else
          name=$value
        fi
        ;;
      DESCRIPTION)
        if [[ -n "$description" || -z "$value" ]]; then
          printf '    Invalid: DESCRIPTION must appear once and be non-empty\n'
          has_error=1
        else
          description=$value
        fi
        ;;
      VERSION)
        if [[ -n "$version" || ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          printf '    Invalid: VERSION must appear once in numeric major.minor.patch format\n'
          has_error=1
        else
          version=$value
        fi
        ;;
      PACKAGE_LISTS)
        if [[ -n "$package_lists" || -z "$value" ]]; then
          printf '    Invalid: PACKAGE_LISTS must appear once and be non-empty\n'
          has_error=1
        else
          package_lists=$value
        fi
        ;;
      *)
        printf '    Invalid: unsupported definition key "%s" at line %d\n' "$key" "$line_number"
        has_error=1
        ;;
    esac
  done < "$profile_file"

  [[ -n "$name" ]] || { printf '    Invalid: missing NAME\n'; has_error=1; }
  [[ -n "$description" ]] || { printf '    Invalid: missing DESCRIPTION\n'; has_error=1; }
  [[ -n "$version" ]] || { printf '    Invalid: missing VERSION\n'; has_error=1; }
  [[ -n "$package_lists" ]] || { printf '    Invalid: missing PACKAGE_LISTS\n'; has_error=1; }
  if [[ -n "$name" && "$name" != "$profile_name" ]]; then
    printf '    Invalid: NAME "%s" does not match directory "%s"\n' "$name" "$profile_name"
    has_error=1
  fi

  if [[ -n "$package_lists" ]]; then
    if [[ "$package_lists" == ,* || "$package_lists" == *, || "$package_lists" == *,,* ]]; then
      printf '    Invalid: PACKAGE_LISTS contains an empty entry\n'
      has_error=1
    fi
    IFS=, read -r -a package_list_names <<< "$package_lists"
    for package_list in "${package_list_names[@]}"; do
      package_list=${package_list#"${package_list%%[![:space:]]*}"}
      package_list=${package_list%"${package_list##*[![:space:]]}"}
      if [[ -z "$package_list" ]]; then
        printf '    Invalid: PACKAGE_LISTS contains an empty entry\n'
        has_error=1
        continue
      fi
      if [[ "$package_list" == /* || "$package_list" == *..* || ! "$package_list" =~ ^[a-zA-Z0-9_/-]+\.txt$ ]]; then
        printf '    Invalid: unsupported package-list path "%s"\n' "$package_list"
        has_error=1
        continue
      fi
      package_file="$PROJECT_ROOT/packages/$package_list"
      package_path="$PROJECT_ROOT/packages"
      unsafe_package_path=0
      [[ -L "$package_path" ]] && unsafe_package_path=1
      local -a package_path_components=()
      IFS=/ read -r -a package_path_components <<< "$package_list"
      for package_component in "${package_path_components[@]}"; do
        package_path="$package_path/$package_component"
        [[ -L "$package_path" ]] && unsafe_package_path=1
      done
      if (( unsafe_package_path )); then
        printf '    Invalid: package-list path traverses a symbolic link (%s)\n' "$package_list"
        has_error=1
      elif [[ ! -f "$package_file" || ! -r "$package_file" || -L "$package_file" ]]; then
        printf '    Invalid: package list is missing or unreadable (%s)\n' "$package_file"
        has_error=1
      else
        line_number=0
        while IFS= read -r package_line || [[ -n "$package_line" ]]; do
          ((line_number += 1))
          if [[ -z "$package_line" ]]; then
            continue
          elif [[ "$package_line" =~ ^[[:space:]]*# ]]; then
            continue
          fi

          trimmed_package=${package_line#"${package_line%%[![:space:]]*}"}
          trimmed_package=${trimmed_package%"${trimmed_package##*[![:space:]]}"}
          if [[ -z "$trimmed_package" || "$package_line" != "$trimmed_package" || "$trimmed_package" =~ [[:space:]] ]]; then
            printf '    Invalid: whitespace or empty package entry at %s:%d\n' "$package_file" "$line_number"
            has_error=1
            continue
          fi
          if [[ ! "$trimmed_package" =~ ^[[:alnum:]@][[:alnum:]@._+-]*$ ]]; then
            printf '    Invalid: malformed package name "%s" at %s:%d\n' "$trimmed_package" "$package_file" "$line_number"
            has_error=1
            continue
          fi
          if [[ -n ${seen_packages[$trimmed_package]+present} ]]; then
            printf '    Invalid: duplicate package "%s" in %s (already listed in %s)\n' \
              "$trimmed_package" "$package_file" "${seen_packages[$trimmed_package]}"
            has_error=1
          else
            seen_packages[$trimmed_package]=$package_file
            PROFILE_PACKAGE_PLAN+=("$trimmed_package")
            PROFILE_PACKAGE_PLAN_SOURCES+=("$package_list")
          fi
        done < "$package_file"
      fi
    done
  fi

  if (( has_error )); then
    return 1
  fi
  [[ "$quiet" == true ]] && return 0
  printf '    Valid\n'
}

resolve_profile_packages() {
  local profile_name=$1

  PROFILE_PACKAGE_PLAN=()
  PROFILE_PACKAGE_PLAN_SOURCES=()
  if ! validate_profile "$profile_name" true; then
    PROFILE_PACKAGE_PLAN=()
    PROFILE_PACKAGE_PLAN_SOURCES=()
    return 1
  fi
  if (( ${#PROFILE_PACKAGE_PLAN[@]} == 0 )); then
    printf 'Profile "%s" contains no packages.\n' "$profile_name" >&2
    return 1
  fi
}

list_profiles() {
  local profile_name=""
  local profile_file=""
  local profile_path=""
  local description=""
  local any_invalid=0
  local found=0

  for profile_path in "$PROJECT_ROOT/profiles"/*; do
    [[ -d "$profile_path" ]] || continue
    profile_name=${profile_path##*/}
    found=1
    profile_file="$PROJECT_ROOT/profiles/$profile_name/profile.conf"
    description="Description unavailable"
    if [[ -r "$profile_file" && ! -L "$profile_file" && ! -L "$PROJECT_ROOT/profiles/$profile_name" ]]; then
      description=$(awk -F= '$1 == "DESCRIPTION" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$profile_file")
      [[ -n "$description" ]] || description="Description unavailable"
    fi
    if validate_profile "$profile_name" true; then
      printf '%s — %s [valid]\n' "$profile_name" "$description"
    else
      printf '%s — %s [invalid]\n' "$profile_name" "$description"
      any_invalid=1
    fi
  done

  if (( ! found )); then
    error "No profile directories found in $PROJECT_ROOT/profiles."
    return 1
  fi

  if (( any_invalid )); then
    error "One or more profiles are invalid. See the status details above."
    return 1
  fi
}

run_profile_command() {
  local action=${1:-list}
  local profile_name profile_file description version package_lists failed=0
  local -a profile_names=()

  case "$action" in
    list)
      if (( $# > 1 )); then
        error "The 'profile list' command does not accept additional arguments."
        return 2
      fi
      list_profiles
      ;;
    show)
      if (( $# != 2 )); then
        error "Usage: ${0##*/} profile show <name>"
        return 2
      fi
      show_profile_plan "$2"
      ;;
    validate)
      if (( $# > 2 )); then
        error "Usage: ${0##*/} profile validate [name]"
        return 2
      fi
      if (( $# == 2 )); then
        profile_names=("$2")
      else
        for profile_file in "$PROJECT_ROOT/profiles"/*; do
          [[ -d "$profile_file" ]] || continue
          profile_names+=("${profile_file##*/}")
        done
      fi
      if (( ${#profile_names[@]} == 0 )); then
        error "No profiles found in $PROJECT_ROOT/profiles."
        return 1
      fi
      for profile_name in "${profile_names[@]}"; do
        if [[ ! "$profile_name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
          printf '  %s: invalid profile name\n' "$profile_name"
          failed=1
        elif validate_profile "$profile_name" true; then
          printf '  %s: valid\n' "$profile_name"
        else
          printf '  %s: invalid\n' "$profile_name"
          failed=1
        fi
      done
      return "$failed"
      ;;
    info)
      if (( $# != 2 )); then
        error "Usage: ${0##*/} profile info <name>"
        return 2
      fi
      profile_name=$2
      if [[ ! "$profile_name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
        error "Invalid profile name: $profile_name"
        return 2
      fi
      if ! validate_profile "$profile_name" true; then
        return 1
      fi
      profile_file="$PROJECT_ROOT/profiles/$profile_name/profile.conf"
      description=$(awk -F= '$1 == "DESCRIPTION" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$profile_file")
      version=$(awk -F= '$1 == "VERSION" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$profile_file")
      package_lists=$(awk -F= '$1 == "PACKAGE_LISTS" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }' "$profile_file")
      printf 'Name: %s\nDescription: %s\nVersion: %s\nPackage lists: %s\nValidation: valid\n' \
        "$profile_name" "$description" "$version" "$package_lists"
      ;;
    *)
      error "Unknown profile action: $action"
      printf 'Usage: %s profile [list|validate [name]|info <name>|show <name>]\n' "${0##*/}" >&2
      return 2
      ;;
  esac
}

package_group_name() {
  case "$1" in
    base.txt) printf 'Core / system' ;;
    desktop.txt) printf 'Desktop / Hyprland' ;;
    developer.txt) printf 'Development' ;;
    cyber.txt) printf 'Cybersecurity' ;;
    optional.txt) printf 'Optional tools' ;;
    *) printf '%s' "${1%.txt}" ;;
  esac
}

show_profile_plan() {
  local profile_name=$1
  local source_file=""
  local previous_source=""
  local group_name=""
  local index=0

  printf 'Package plan: %s\n' "$profile_name"
  if ! resolve_profile_packages "$profile_name"; then
    printf 'Manifest status: invalid\n'
    return 1
  fi

  for ((index = 0; index < ${#PROFILE_PACKAGE_PLAN[@]}; index += 1)); do
    source_file=${PROFILE_PACKAGE_PLAN_SOURCES[index]}
    if [[ "$source_file" != "$previous_source" ]]; then
      group_name=$(package_group_name "${source_file##*/}")
      printf '\n%s:\n' "$group_name"
      previous_source=$source_file
    fi
    printf '  - %s\n' "${PROFILE_PACKAGE_PLAN[index]}"
  done

  printf '\nTotal packages: %d\nManifest status: valid\n' "${#PROFILE_PACKAGE_PLAN[@]}"
}

show_menu() {
  cat <<'EOF'
Choose an action:
  1) Install profile packages
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
    profile)
      shift
      run_profile_command "$@"
      ;;
    install)
      shift
      source "$PROJECT_ROOT/install/install.sh"
      install_profile "$@"
      ;;
    configure|update|uninstall)
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
  local choice command_name profile_name

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
    1)
      if ! read -r -p "Profile [minimal/developer/cyber/full]: " profile_name; then
        printf '\n'
        warn "No profile was selected."
        return 2
      fi
      run_command install "$profile_name"
      return $?
      ;;
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

  if [[ ${1-} == install ]]; then
    if (( $# > 3 )); then
      error "Usage: ${0##*/} install <profile> [--dry-run|--yes]"
      return 2
    fi
  elif (( $# > 1 )) && { [[ "$1" != profile ]] || (( $# > 3 )) || { (( $# == 3 )) && [[ "$2" != show && "$2" != info && "$2" != validate ]]; }; }; then
    error "Unexpected command arguments."
    print_usage >&2
    return 2
  fi

  run_command "$@"
}

main "$@"
