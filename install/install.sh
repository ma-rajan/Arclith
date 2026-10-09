#!/usr/bin/env bash
# Package installation entry point. The CLI sources this file so profile
# validation and package resolution remain shared with the existing planner.

install_profile() {
  local profile_name=${1-}
  local option=""
  local dry_run=0
  local assume_yes=0
  local pacman_bin=""
  local sudo_bin=""
  local installed_output=""
  local installed_package=""
  local package=""
  local response=""
  local status=0
  local -A installed_set=()
  local -a already_installed=() to_install=()

  if (( $# < 1 )); then
    error "Usage: ${0##*/} install <profile> [--dry-run|--yes]"
    return 2
  fi
  shift

  while (( $# > 0 )); do
    option=$1
    shift
    case "$option" in
      --dry-run)
        if (( dry_run )); then
          error "Option --dry-run was supplied more than once."
          return 2
        fi
        dry_run=1
        ;;
      --yes)
        if (( assume_yes )); then
          error "Option --yes was supplied more than once."
          return 2
        fi
        assume_yes=1
        ;;
      *)
        error "Unsupported install option: $option"
        printf 'Usage: %s install <profile> [--dry-run|--yes]\n' "${0##*/}" >&2
        return 2
        ;;
    esac
  done

  if (( dry_run && assume_yes )); then
    error "Choose either --dry-run or --yes, not both."
    return 2
  fi
  if [[ ! "$profile_name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    error "Invalid profile name: ${profile_name:-<empty>}"
    return 2
  fi
  if [[ ! -d "$PROJECT_ROOT/profiles/$profile_name" ]]; then
    error "Unknown profile: $profile_name"
    return 2
  fi

  if ! resolve_profile_packages "$profile_name"; then
    error "Profile '$profile_name' is invalid; no packages will be installed."
    return 1
  fi

  pacman_bin=$(type -P pacman 2>/dev/null || true)
  if [[ -z "$pacman_bin" ]]; then
    error "pacman is unavailable; package installation requires an Arch Linux or pacman-based system."
    return 1
  fi

  # Reuse the project's existing, read-only Arch compatibility check.
  # shellcheck source=../hardware/recommend.sh
  source "$PROJECT_ROOT/hardware/recommend.sh"
  if ! is_arch_based; then
    error "This system is not identified as Arch Linux or Arch-based; refusing package installation."
    return 1
  fi

  if ! installed_output=$("$pacman_bin" -Qq); then
    error "Could not query installed packages with pacman."
    return 1
  fi
  while IFS= read -r installed_package || [[ -n "$installed_package" ]]; do
    [[ "$installed_package" =~ ^[[:alnum:]@][[:alnum:]@._+-]*$ ]] || continue
    installed_set["$installed_package"]=1
  done <<< "$installed_output"

  for package in "${PROFILE_PACKAGE_PLAN[@]}"; do
    if [[ -n "${installed_set[$package]+present}" ]]; then
      already_installed+=("$package")
    else
      to_install+=("$package")
    fi
  done

  printf 'Profile: %s\nStatus: valid\n\nPackages:\n' "$profile_name"
  printf '  Already installed:\n'
  if (( ${#already_installed[@]} == 0 )); then
    printf '    (none)\n'
  else
    for package in "${already_installed[@]}"; do printf '    %s\n' "$package"; done
  fi
  printf '\n  To install:\n'
  if (( ${#to_install[@]} == 0 )); then
    printf '    (none)\n'
  else
    for package in "${to_install[@]}"; do printf '    %s\n' "$package"; done
  fi

  if (( dry_run )); then
    printf '\nDry run complete.\nNo changes were made.\n'
    return 0
  fi
  if (( ${#to_install[@]} == 0 )); then
    printf '\nAll profile packages are already installed.\n'
    return 0
  fi

  if (( EUID != 0 )); then
    sudo_bin=$(type -P sudo 2>/dev/null || true)
    if [[ -z "$sudo_bin" ]]; then
      error "Installation needs root privileges; sudo is unavailable."
      return 1
    fi
  fi

  if (( ! assume_yes )); then
    if ! read -r -p $'\nContinue? [y/N]: ' response; then
      response=""
    fi
    response=${response,,}
    case "$response" in
      y|yes)
        ;;
      *)
        warn "Installation cancelled; no packages were changed."
        return 1
        ;;
    esac
  fi

  printf '\nInstalling %d package(s) for profile %s.\n' "${#to_install[@]}" "$profile_name"
  if (( EUID == 0 )); then
    if "$pacman_bin" -S --needed -- "${to_install[@]}"; then
      success "Package installation completed for profile '$profile_name'."
      return 0
    else
      status=$?
    fi
  else
    if "$sudo_bin" "$pacman_bin" -S --needed -- "${to_install[@]}"; then
      success "Package installation completed for profile '$profile_name'."
      return 0
    else
      status=$?
    fi
  fi

  error "Package installation failed (exit code $status)."
  return "$status"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  installer_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
  exec "$installer_root/arclith.sh" install "$@"
fi
