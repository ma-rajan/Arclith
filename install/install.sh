#!/usr/bin/env bash
# Package installation entry point. Planning and mutation are separate so the
# configure command can show one combined plan and authorize installation once.

INSTALL_PLAN_PROFILE=
INSTALL_PLAN_PACMAN=
INSTALL_PLAN_PACKAGES=()
INSTALL_PLAN_INSTALLED=()
INSTALL_PLAN_PENDING=()
INSTALL_PLAN_SUDO=

prepare_install_package_plan() {
  local profile_name=$1 pacman_bin installed_output installed_package package
  local -A installed_set=()
  INSTALL_PLAN_PROFILE=$profile_name
  INSTALL_PLAN_PACMAN=
  INSTALL_PLAN_PACKAGES=()
  INSTALL_PLAN_INSTALLED=()
  INSTALL_PLAN_PENDING=()
  INSTALL_PLAN_SUDO=
  [[ $profile_name =~ ^[a-z][a-z0-9_-]*$ && -d "$PROJECT_ROOT/profiles/$profile_name" ]] || {
    error "Unknown profile: $profile_name"; return 2;
  }
  resolve_profile_packages "$profile_name" || { error "Profile '$profile_name' is invalid; no packages will be installed."; return 1; }
  INSTALL_PLAN_PACKAGES=("${PROFILE_PACKAGE_PLAN[@]}")
  pacman_bin=$(type -P pacman 2>/dev/null || true)
  [[ -n $pacman_bin ]] || { error 'pacman is unavailable; package planning requires an Arch Linux or pacman-based system.'; return 1; }
  source "$PROJECT_ROOT/hardware/recommend.sh"
  is_arch_based || { error 'This system is not identified as Arch Linux or Arch-based; refusing package operation.'; return 1; }
  if ! installed_output=$("$pacman_bin" -Qq); then error 'Could not query installed packages with pacman.'; return 1; fi
  while IFS= read -r installed_package || [[ -n $installed_package ]]; do
    [[ $installed_package =~ ^[[:alnum:]@][[:alnum:]@._+-]*$ ]] || continue
    installed_set["$installed_package"]=1
  done <<< "$installed_output"
  for package in "${INSTALL_PLAN_PACKAGES[@]}"; do
    if [[ -n ${installed_set[$package]+present} ]]; then INSTALL_PLAN_INSTALLED+=("$package"); else INSTALL_PLAN_PENDING+=("$package"); fi
  done
  INSTALL_PLAN_PACMAN=$pacman_bin
}

validate_prepared_install_capability() {
  if (( ${#INSTALL_PLAN_PENDING[@]} == 0 || EUID == 0 )); then return 0; fi
  INSTALL_PLAN_SUDO=$(type -P sudo 2>/dev/null || true)
  [[ -n $INSTALL_PLAN_SUDO ]] || { error 'Installation needs root privileges; sudo is unavailable.'; return 1; }
}

install_prepared_package_plan() {
  local status=0
  if (( ${#INSTALL_PLAN_PENDING[@]} == 0 )); then printf 'All profile packages are already installed.\n'; return 0; fi
  validate_prepared_install_capability || return $?
  printf 'Installing %d package(s) for profile %s.\n' "${#INSTALL_PLAN_PENDING[@]}" "$INSTALL_PLAN_PROFILE"
  if (( EUID == 0 )); then
    if "$INSTALL_PLAN_PACMAN" -S --needed -- "${INSTALL_PLAN_PENDING[@]}"; then success "Package installation completed for profile '$INSTALL_PLAN_PROFILE'."; return 0; else status=$?; fi
  else
    if "$INSTALL_PLAN_SUDO" "$INSTALL_PLAN_PACMAN" -S --needed -- "${INSTALL_PLAN_PENDING[@]}"; then success "Package installation completed for profile '$INSTALL_PLAN_PROFILE'."; return 0; else status=$?; fi
  fi
  error "Package installation failed (exit code $status)."
  return "$status"
}

install_profile() {
  local profile_name=${1-}
  local option=""
  local dry_run=0
  local assume_yes=0
  local package=""
  local response=""

  if [[ $profile_name == default ]]; then
    profile_name=$(configured_default_profile) || return 1
  fi

  if (( $# < 1 )); then
    error "Usage: ${0##*/} install <profile|default> [--dry-run|--yes]"
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
        printf 'Usage: %s install <profile|default> [--dry-run|--yes]\n' "${0##*/}" >&2
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

  prepare_install_package_plan "$profile_name" || return $?

  printf 'Profile: %s\nStatus: valid\n\nPackages:\n' "$profile_name"
  printf '  Already installed:\n'
  if (( ${#INSTALL_PLAN_INSTALLED[@]} == 0 )); then
    printf '    (none)\n'
  else
    for package in "${INSTALL_PLAN_INSTALLED[@]}"; do printf '    %s\n' "$package"; done
  fi
  printf '\n  To install:\n'
  if (( ${#INSTALL_PLAN_PENDING[@]} == 0 )); then
    printf '    (none)\n'
  else
    for package in "${INSTALL_PLAN_PENDING[@]}"; do printf '    %s\n' "$package"; done
  fi

  if (( dry_run )); then
    printf '\nDry run complete.\nNo changes were made.\n'
    return 0
  fi
  if (( ${#INSTALL_PLAN_PENDING[@]} == 0 )); then
    printf '\nAll profile packages are already installed.\n'
    return 0
  fi

  validate_prepared_install_capability || return $?

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

  install_prepared_package_plan
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  installer_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
  exec "$installer_root/arclith.sh" install "$@"
fi
