#!/usr/bin/env bash
# Configuration discovery, validation, preview, and guarded deployment.
# Registry entries are parsed as data; source files are never executed.

CONFIG_COMPONENT_NAMES=()
declare -A CONFIG_DESCRIPTIONS=()
declare -A CONFIG_SOURCES=()
declare -A CONFIG_TARGETS=()
declare -A CONFIG_ENABLED=()

config_error() { printf '[ERROR] %s\n' "$*" >&2; }

CONFIG_TXN_PARSE_REASON=
CONFIG_TXN_PARSE_OPERATIONAL=no

config_safe_relative_path() {
  local path=$1 part
  local -a parts=()
  [[ -n $path && $path != /* && $path != *$'\n'* && $path != *$'\r'* ]] || return 1
  [[ $path =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] || return 1
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do [[ $part != . && $part != .. ]] || return 1; done
}

config_expected_source() { printf 'core/configs/%s' "$1"; }
config_expected_target() {
  case $1 in
    hyprland) printf '.config/hypr' ;;
    waybar) printf '.config/waybar' ;;
    rofi) printf '.config/rofi' ;;
    kitty) printf '.config/kitty' ;;
    zsh) printf '.zshrc' ;;
    wallust) printf '.config/wallust' ;;
    *) return 1 ;;
  esac
}

config_path_has_symlink() {
  local base=$1 relative=$2 current=$1 part
  local -a parts=()
  IFS=/ read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    current="$current/$part"
    [[ -L $current ]] && return 0
  done
  return 1
}

config_path_has_non_directory_ancestor() {
  local current=$1 relative=$2 part
  local -a parts=()
  IFS=/ read -r -a parts <<< "$relative"
  for part in "${parts[@]}"; do
    current="$current/$part"
    if [[ -e $current && ! -d $current ]]; then return 0; fi
  done
  return 1
}

config_target_inspection_status() {
  local home=$1 relative=$2 current=$1 part index
  local -a parts=()
  [[ ! -L $home && -d $home ]] || { printf 'unsafe'; return; }
  [[ -x $home ]] || { printf 'inaccessible'; return; }
  config_safe_relative_path "$relative" || { printf 'unsafe'; return; }
  IFS=/ read -r -a parts <<< "$relative"
  for index in "${!parts[@]}"; do
    part=${parts[index]}
    current="$current/$part"
    if [[ -L $current ]]; then
      printf 'unsafe'
      return
    elif [[ ! -e $current ]]; then
      printf 'missing'
      return
    elif (( index < ${#parts[@]} - 1 )); then
      if [[ ! -d $current ]]; then printf 'unsafe'; return; fi
      if [[ ! -x $current ]]; then printf 'inaccessible'; return; fi
    else
      if [[ ! -f $current ]]; then printf 'unsafe'; return; fi
      if [[ ! -r $current ]]; then printf 'inaccessible'; return; fi
    fi
  done
  printf 'accessible'
}

config_load_registry() {
  local root=$1 registry="$1/config/components.conf" line name description source target enabled extra
  local line_number=0 pipes
  CONFIG_COMPONENT_NAMES=()
  CONFIG_DESCRIPTIONS=()
  CONFIG_SOURCES=()
  CONFIG_TARGETS=()
  CONFIG_ENABLED=()
  if [[ -L "$root/config" || -L "$registry" || ! -f $registry || ! -r $registry ]]; then
    config_error "Configuration registry is missing, unreadable, or symlinked: $registry"
    return 1
  fi
  while IFS= read -r line || [[ -n $line ]]; do
    ((line_number += 1))
    [[ -z $line || $line == \#* ]] && continue
    pipes=${line//[^|]/}
    if (( ${#pipes} != 4 )); then
      config_error "$registry:$line_number: expected exactly five pipe-separated fields"
      return 1
    fi
    IFS='|' read -r name description source target enabled extra <<< "$line"
    if [[ ! $name =~ ^[a-z][a-z0-9_-]*$ ]] || ! config_expected_target "$name" >/dev/null; then
      config_error "$registry:$line_number: invalid or unsupported component name '$name'"
      return 1
    fi
    if [[ -z $description || -n $extra || -z $enabled || ( $enabled != true && $enabled != false ) ]]; then
      config_error "$registry:$line_number: invalid metadata for component '$name'"
      return 1
    fi
    if [[ -n ${CONFIG_DESCRIPTIONS[$name]+present} ]]; then
      config_error "$registry:$line_number: duplicate component '$name'"
      return 1
    fi
    if [[ $source != "$(config_expected_source "$name")" || $target != "$(config_expected_target "$name")" ]] || ! config_safe_relative_path "$source" || ! config_safe_relative_path "$target"; then
      config_error "$registry:$line_number: unsafe or unsupported source/target path for '$name'"
      return 1
    fi
    CONFIG_COMPONENT_NAMES+=("$name")
    CONFIG_DESCRIPTIONS[$name]=$description
    CONFIG_SOURCES[$name]=$source
    CONFIG_TARGETS[$name]=$target
    CONFIG_ENABLED[$name]=$enabled
  done < "$registry"
  if (( ${#CONFIG_COMPONENT_NAMES[@]} != 6 )); then
    config_error "$registry: expected all six supported component definitions"
    return 1
  fi
}

config_component_exists() {
  local wanted=$1 name
  for name in "${CONFIG_COMPONENT_NAMES[@]}"; do [[ $name == "$wanted" ]] && return 0; done
  return 1
}

config_source_status() {
  local root=$1 name=$2 source="${CONFIG_SOURCES[$2]}"
  local path="$root/$source"
  if config_path_has_symlink "$root" "$source"; then
    printf 'unsafe-symlink'
  elif [[ ! -d $path || ! -r $path ]]; then
    printf 'unavailable'
  elif find "$path" -mindepth 1 ! -type d ! -type f -print -quit | grep -q .; then
    printf 'unsafe-entry'
  elif find "$path" -mindepth 1 -type l -print -quit | grep -q .; then
    printf 'unsafe-symlink'
  elif find "$path" ! -readable -print -quit | grep -q .; then
    printf 'unreadable'
  elif ! find "$path" -type f -print -quit | grep -q .; then
    printf 'empty-source'
  else
    printf 'available'
  fi
}

config_validate_registry() {
  local root=$1 selected_component=${2:-} quiet=${3:-false} name status failed=0 component_failed source_dir relative
  if (( $# > 3 )) || [[ $quiet != true && $quiet != false ]]; then
    config_error 'Usage: config_validate_registry <root> [component] [quiet=true|false]'
    return 2
  fi
  config_load_registry "$root" || return 1
  if [[ -n $selected_component ]] && ! config_component_exists "$selected_component"; then
    config_error "Unknown configuration component: $selected_component"
    return 2
  fi
  for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
    [[ -z $selected_component || $selected_component == "$name" ]] || continue
    component_failed=0
    status=$(config_source_status "$root" "$name")
    case $status in
      available)
        source_dir="$root/${CONFIG_SOURCES[$name]}"
        while IFS= read -r -d '' relative; do
          relative=${relative#"$source_dir"/}
          if ! config_safe_relative_path "$relative"; then
            printf '%s: invalid (unsafe source file path: %s)\n' "$name" "$relative"
            failed=1
            component_failed=1
          elif [[ ! -s "$source_dir/$relative" ]] || ! LC_ALL=C grep -Iq . -- "$source_dir/$relative"; then
            printf '%s: invalid (source file must be non-empty text: %s)\n' "$name" "$relative"
            failed=1
            component_failed=1
          fi
        done < <(find "$source_dir" -type f -print0)
        if (( component_failed == 0 )) && [[ $quiet != true ]]; then
          printf '%s: source available (non-empty text; component syntax not checked)\n' "$name"
        fi
        ;;
      unavailable) printf '%s: unavailable (source directory missing or unreadable: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      unsafe-symlink) printf '%s: invalid (source path contains a symlink: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      unsafe-entry) printf '%s: invalid (source contains an unsupported filesystem entry: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      unreadable) printf '%s: invalid (source contains unreadable paths: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      empty-source) printf '%s: unavailable (source directory contains no configuration files: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
    esac
  done
  (( failed == 0 ))
}

config_doctor() {
  local root=$1 home=${HOME:-} settings="$1/config/arclith.conf" line key value line_number=0
  local failed=0 warnings=0 name status source target target_path parent current candidate part source_dir relative source_failed
  local -a _doctor_parts=()
  local -A values=()
  printf 'Arclith configuration doctor (read-only)\n'
  if [[ -L $root/config || -L $settings || ! -f $settings || ! -r $settings ]]; then
    printf 'FAIL config file: missing, unreadable, or symlinked (%s)\n' "$settings"
    failed=1
  else
    while IFS= read -r line || [[ -n $line ]]; do
      ((line_number += 1))
      line=${line%%#*}
      [[ $line =~ ^[[:space:]]*$ ]] && continue
      if [[ ! $line =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*([^[:space:]]+)[[:space:]]*$ ]]; then
        printf 'FAIL config syntax: malformed setting at line %d\n' "$line_number"
        failed=1
        continue
      fi
      key=${BASH_REMATCH[1]}; value=${BASH_REMATCH[2]}
      if [[ -n ${values[$key]+present} ]]; then
        printf 'FAIL config syntax: duplicate setting %s at line %d\n' "$key" "$line_number"
        failed=1
      else
        values[$key]=$value
      fi
      case $key in
        PROFILE|INSTALL_AUR_HELPER|BACKUP_EXISTING_CONFIG) ;;
        *) printf 'FAIL config reference: unsupported setting %s at line %d\n' "$key" "$line_number"; failed=1 ;;
      esac
    done < "$settings"
    for key in PROFILE INSTALL_AUR_HELPER BACKUP_EXISTING_CONFIG; do
      if [[ -z ${values[$key]+present} ]]; then
        printf 'FAIL config setting: required setting %s is missing\n' "$key"
        failed=1
      fi
    done
    for key in INSTALL_AUR_HELPER BACKUP_EXISTING_CONFIG; do
      if [[ -n ${values[$key]+present} && ${values[$key]} != true && ${values[$key]} != false ]]; then
        printf 'FAIL config setting: %s must be true or false\n' "$key"
        failed=1
      fi
    done
    if [[ -n ${values[PROFILE]+present} ]]; then
      if [[ ! ${values[PROFILE]} =~ ^[a-z][a-z0-9_-]*$ || ! -f $root/profiles/${values[PROFILE]}/profile.conf || -L $root/profiles/${values[PROFILE]}/profile.conf ]]; then
        printf 'FAIL config reference: PROFILE references a missing or invalid profile (%s)\n' "${values[PROFILE]}"
        failed=1
      elif declare -F validate_profile >/dev/null && ! validate_profile "${values[PROFILE]}" true >/dev/null; then
        printf 'FAIL config reference: PROFILE references an invalid profile (%s)\n' "${values[PROFILE]}"
        failed=1
      else
        printf 'PASS config reference: PROFILE=%s\n' "${values[PROFILE]}"
      fi
    fi
    if (( failed == 0 )); then printf 'PASS config file: syntax and required settings are valid\n'; fi
  fi

  if ! config_load_registry "$root"; then
    printf 'FAIL component registry: invalid or unavailable\n'
    failed=1
  else
    for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
      status=$(config_source_status "$root" "$name")
      case $status in
        available)
          source_dir="$root/${CONFIG_SOURCES[$name]}"
          source_failed=0
          while IFS= read -r -d '' relative; do
            relative=${relative#"$source_dir"/}
            if ! config_safe_relative_path "$relative" || [[ ! -s $source_dir/$relative ]] || ! LC_ALL=C grep -Iq . -- "$source_dir/$relative"; then
              printf 'FAIL component source: %s has an invalid source file (%s)\n' "$name" "$relative"
              failed=1
              source_failed=1
            fi
          done < <(find "$source_dir" -type f -print0)
          (( source_failed )) || printf 'PASS component source: %s is available (readable non-empty text)\n' "$name"
          ;;
        unavailable|empty-source)
          printf 'WARN optional component source: %s is %s (%s)\n' "$name" "$status" "${CONFIG_SOURCES[$name]}"
          warnings=$((warnings + 1))
          ;;
        *)
          printf 'FAIL component source: %s is %s (%s)\n' "$name" "$status" "${CONFIG_SOURCES[$name]}"
          failed=1
          ;;
      esac
    done
    if [[ ! $home == /* || -L $home || ! -d $home || ! -x $home ]]; then
      printf 'FAIL destination paths: HOME is not an accessible absolute directory\n'
      failed=1
    else
      for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
        target=${CONFIG_TARGETS[$name]}
        target_path="$home/$target"
        if config_path_has_symlink "$home" "$target"; then
          printf 'FAIL destination path: %s contains a symlink\n' "$target_path"
          failed=1
          continue
        fi
        if [[ -e $target_path && ! -f $target_path && ! -d $target_path ]]; then
          printf 'FAIL destination path: unsupported target type (%s)\n' "$target_path"
          failed=1
          continue
        fi
        if [[ -e $target_path && -f $target_path && $target != .zshrc ]]; then
          printf 'FAIL destination path: expected a directory but found a file (%s)\n' "$target_path"
          failed=1
          continue
        fi
        if [[ -e $target_path && -d $target_path && $target == .zshrc ]]; then
          printf 'FAIL destination path: expected a file but found a directory (%s)\n' "$target_path"
          failed=1
          continue
        fi
        parent=$target
        [[ $parent == */* ]] && parent=${parent%/*} || parent=.
        current=$home
        IFS=/ read -r -a _doctor_parts <<< "$parent"
        for part in "${_doctor_parts[@]}"; do
          [[ -z $part || $part == . ]] && continue
          candidate="$current/$part"
          [[ -e $candidate || -L $candidate ]] || break
          current=$candidate
          [[ -d $current ]] || break
        done
        if [[ -d $target_path ]]; then current=$target_path; fi
        if [[ ! -d $current || ! -x $current || ! -w $current ]]; then
          printf 'FAIL destination path: nearest existing parent is not writable/searchable (%s)\n' "$current"
          failed=1
        elif [[ -e $target_path && ! -w $target_path ]]; then
          printf 'FAIL destination path: existing target is not writable (%s)\n' "$target_path"
          failed=1
        else
          printf 'PASS destination path: %s is valid%s\n' "$target_path" "$([[ -e $target_path ]] && printf ' (present)' || printf ' (not installed)')"
        fi
      done
    fi
  fi
  if (( failed )); then printf 'Doctor result: FAIL (%d warning(s))\n' "$warnings"; return 1; fi
  printf 'Doctor result: PASS (%d warning(s))\n' "$warnings"
}

config_list() {
  local root=$1 name status
  config_load_registry "$root" || return 1
  printf 'Configuration components (read-only):\n'
  for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
    status=$(config_source_status "$root" "$name")
    [[ ${CONFIG_ENABLED[$name]} == true ]] || status=disabled
    printf '%-10s %-12s %s\n  source: %s\n  target: ~/%s\n' "$name" "$status" "${CONFIG_DESCRIPTIONS[$name]}" "${CONFIG_SOURCES[$name]}" "${CONFIG_TARGETS[$name]}"
  done
}

config_info() {
  local root=$1 name=$2 status
  config_load_registry "$root" || return 1
  if ! config_component_exists "$name"; then
    config_error "Unknown configuration component: $name"
    return 2
  fi
  status=$(config_source_status "$root" "$name")
  printf 'Name: %s\nDescription: %s\nEnabled: %s\nSource: %s\nTarget: ~/%s\nStatus: %s\n' \
    "$name" "${CONFIG_DESCRIPTIONS[$name]}" "${CONFIG_ENABLED[$name]}" "${CONFIG_SOURCES[$name]}" "${CONFIG_TARGETS[$name]}" "$status"
}

config_preview() {
  local root=$1 name=$2 source source_dir relative target home target_rel target_parent status inspection found=0 invalid=0
  local -a files=()
  config_load_registry "$root" || return 1
  if ! config_component_exists "$name"; then
    config_error "Unknown configuration component: $name"
    return 2
  fi
  source=${CONFIG_SOURCES[$name]}
  source_dir="$root/$source"
  target=${CONFIG_TARGETS[$name]}
  status=$(config_source_status "$root" "$name")
  printf 'Configuration preview: %s (read-only)\nSource: %s\nTarget: ~/%s\n' "$name" "$source" "$target"
  if [[ $status != available ]]; then
    printf 'Status: %s\nNo files would be deployed because the source is unavailable or unsafe.\n' "$status"
    if [[ $status == unsafe-entry ]]; then
      while IFS= read -r -d '' relative; do printf '  unsupported source entry: %s\n' "${relative#"$source_dir"/}"; done \
        < <(find "$source_dir" -mindepth 1 ! -type d ! -type f -print0)
    elif [[ $status == unsafe-symlink ]]; then
      printf '  unsafe source path: %s\n' "$source"
    fi
    return 1
  fi
  while IFS= read -r -d '' relative; do files+=("$relative"); done < <(find "$source_dir" -mindepth 1 ! -type d ! -type f -print0)
  if (( ${#files[@]} > 0 )); then
    printf 'Status: invalid (source contains unsupported entries)\n'
    for relative in "${files[@]}"; do printf '  unsupported source entry: %s\n' "$relative"; done
    return 1
  fi
  files=()
  while IFS= read -r -d '' relative; do files+=("${relative#"$source_dir"/}"); done < <(find "$source_dir" -type f -print0)
  home=${HOME:-}
  if [[ ! $home == /* || -L $home || ! -d $home ]]; then
    printf 'Status: invalid (HOME must be an existing absolute, non-symlink directory)\n'
    return 1
  fi
  home=$(cd -- "$home" && pwd -P)
  if (( ${#files[@]} == 0 )); then
    printf 'Status: available (source contains no regular files)\n'
    return 0
  fi
  if [[ $name == zsh && ( ${#files[@]} != 1 || ${files[0]} != .zshrc ) ]]; then
    printf 'Status: invalid (Zsh source must contain exactly one file named .zshrc)\n'
    return 1
  fi
  printf 'Files:\n'
  for relative in "${files[@]}"; do
    if ! config_safe_relative_path "$relative"; then
      printf '  INVALID SOURCE PATH: %s\n' "$relative"
      found=1
      invalid=1
      continue
    fi
    target_rel="$target/$relative"
    if [[ $target == .zshrc ]]; then target_rel=$target; fi
    if [[ $target_rel == */* ]]; then target_parent=${target_rel%/*}; else target_parent=; fi
    if [[ -n $target_parent ]] && config_path_has_symlink "$home" "$target_parent"; then
      printf '  INVALID   %s -> %s (target parent contains a symlink)\n' "$source/$relative" "$home/$target_rel"
      found=1
      invalid=1
      continue
    fi
    if [[ -n $target_parent ]] && config_path_has_non_directory_ancestor "$home" "$target_parent"; then
      printf '  INVALID   %s -> %s (target parent is not a directory)\n' "$source/$relative" "$home/$target_rel"
      found=1
      invalid=1
      continue
    fi
    inspection=$(config_target_inspection_status "$home" "$target_rel")
    if [[ $inspection == inaccessible ]]; then
      printf '  INACCESSIBLE %s -> %s (target cannot be inspected)\n' "$source/$relative" "$home/$target_rel"
      found=1
      invalid=1
      continue
    fi
    if [[ -L "$home/$target_rel" || -e "$home/$target_rel" ]]; then
      printf '  CONFLICT  %s -> %s\n' "$source/$relative" "$home/$target_rel"
      found=1
    else
      printf '  NEW       %s -> %s\n' "$source/$relative" "$home/$target_rel"
    fi
  done
  (( found == 0 )) || printf 'Existing paths are preserved; no files were changed.\n'
  printf 'Preview complete; no files were changed.\n'
  (( invalid == 0 ))
}

CONFIG_STATE_MANAGED_COMPONENTS=()
CONFIG_STATE_MANAGED_TARGETS=()
CONFIG_STATE_MANAGED_HASHES=()
CONFIG_STATE_BACKUP_IDS=()
CONFIG_STATE_BACKUP_COMPONENTS=()
CONFIG_STATE_BACKUP_TARGETS=()
CONFIG_STATE_BACKUP_HASHES=()
CONFIG_STATE_BACKUP_MODES=()
CONFIG_STATE_BACKUP_GROUPS=()

config_state_directory() { printf '%s/.local/state/arclith' "$1"; }

CONFIG_LOCK_FD=
CONFIG_LOCK_FLOCK_BIN=
CONFIG_LOCK_OWNER_PID=
CONFIG_LOCK_HOME=
CONFIG_LOCK_BUSY_STATUS=75

# Read-only prediction for the new-only apply policy. The line-delimited
# manifest is emitted in stable source-path order for locked drift checks.
config_plan_new_only_component() {
  local root=$1 home=${2:-${HOME:-}} name=$3 source_dir target target_rel target_path relative status digest expected parent i
  local -A managed=()
  local -a files=()
  config_load_registry "$root" || return 1
  config_component_exists "$name" || { config_error "Unknown configuration component: $name"; return 2; }
  [[ ${CONFIG_ENABLED[$name]} == true ]] || { config_error "Configuration component is disabled: $name"; return 1; }
  status=$(config_source_status "$root" "$name")
  [[ $status == available ]] || { config_error "Cannot plan '$name': source status is $status"; return 1; }
  config_validate_registry "$root" "$name" true >&2 || { config_error "Cannot plan '$name': source validation failed"; return 1; }
  [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
  home=$(cd -- "$home" && pwd -P) || return 1
  config_state_load "$home" || return 1
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do managed["${CONFIG_STATE_MANAGED_TARGETS[i]}"]=${CONFIG_STATE_MANAGED_HASHES[i]}; done
  source_dir="$root/${CONFIG_SOURCES[$name]}"
  target=${CONFIG_TARGETS[$name]}
  while IFS= read -r -d '' relative; do files+=("${relative#"$source_dir"/}"); done < <(find "$source_dir" -type f -print0 | sort -z)
  (( ${#files[@]} > 0 )) || { config_error "Cannot plan '$name': source contains no regular files"; return 1; }
  if [[ $name == zsh && ( ${#files[@]} != 1 || ${files[0]} != .zshrc ) ]]; then config_error 'Zsh source must contain exactly one file named .zshrc'; return 1; fi
  for relative in "${files[@]}"; do
    config_safe_relative_path "$relative" || { config_error "Invalid source file path: $relative"; return 1; }
    target_rel="$target/$relative"; [[ $target == .zshrc ]] && target_rel=$target
    target_path="$home/$target_rel"
    status=$(config_target_inspection_status "$home" "$target_rel")
    [[ $status != inaccessible ]] || { config_error "Cannot inspect target path: $target_path"; return 1; }
    parent=${target_rel%/*}; [[ $parent == "$target_rel" ]] && parent=
    if [[ -n $parent ]] && { config_path_has_symlink "$home" "$parent" || config_path_has_non_directory_ancestor "$home" "$parent"; }; then
      config_error "Unsafe target parent: $home/$parent"; return 1
    fi
    if [[ -n ${managed[$target_rel]+present} ]]; then
      if [[ -L $target_path || ( -e $target_path && ! -f $target_path ) ]]; then config_error "Unsafe tracked target: $target_path"; return 1
      elif [[ ! -e $target_path ]]; then
        printf 'preserve-missing-tracked|%s|-\n' "$target_rel"
      else
        digest=$(config_file_hash "$target_path") || { config_error "Cannot hash managed target: $target_rel"; return 1; }
        expected=${managed[$target_rel]}
        if [[ $digest != "$expected" ]]; then printf 'preserve-local-edit|%s|%s\n' "$target_rel" "$digest"
        else printf 'preserve-tracked|%s|%s\n' "$target_rel" "$digest"; fi
      fi
    elif [[ -L $target_path || ( -e $target_path && ! -f $target_path ) ]]; then
      config_error "Unsafe new-file target: $target_path"; return 1
    elif [[ -e $target_path ]]; then
      digest=$(config_file_hash "$target_path") || { config_error "Cannot hash unmanaged conflict: $target_rel"; return 1; }
      printf 'preserve-unmanaged|%s|%s\n' "$target_rel" "$digest"
    else
      digest=$(config_file_hash "$source_dir/$relative") || { config_error "Cannot hash source file: $relative"; return 1; }
      printf 'add|%s|%s\n' "$target_rel" "$digest"
    fi
  done
}

config_lock_acquire() {
  local home=${1:-} state_dir lock_path current path_info fd_info mode old_umask
  local fd_device fd_inode fd_owner fd_mode fd_links fd_type
  local flock_status
  local -a ancestors=()

  if (( $# != 1 )); then
    config_error 'Usage: config_lock_acquire <home>'
    return 2
  fi
  if [[ -n $CONFIG_LOCK_FD ]]; then
    config_error 'An Arclith configuration lock is already held by this shell'
    return 1
  fi
  if [[ ! $home == /* || -L $home || ! -d $home ]]; then
    config_error 'Configuration lock requires an existing absolute, non-symlink home directory'
    return 1
  fi
  home=$(cd -- "$home" && pwd -P) || { config_error 'Cannot resolve home directory for configuration lock'; return 1; }
  state_dir=$(config_state_directory "$home")
  lock_path="$state_dir/operation.lock"

  if config_path_has_symlink "$home" .local/state/arclith \
    || config_path_has_non_directory_ancestor "$home" .local/state/arclith; then
    config_error "Unsafe configuration lock state path: $state_dir"
    return 1
  fi

  ancestors=("$home/.local" "$home/.local/state")
  for current in "${ancestors[@]}"; do
    if [[ -e $current ]]; then
      if [[ ! -d $current || -L $current || $(stat -c '%u' -- "$current" 2>/dev/null || true) != "$EUID" ]]; then
        config_error "Unsafe configuration lock directory: $current"
        return 1
      fi
      mode=$(stat -c '%a' -- "$current" 2>/dev/null || true)
      [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 022) == 0 )) || {
        config_error "Configuration lock parent must not be group- or world-writable: $current"
        return 1
      }
      [[ -x $current ]] || { config_error "Cannot traverse configuration lock parent: $current"; return 1; }
    fi
  done

  if [[ -e $state_dir ]]; then
    if [[ ! -d $state_dir || -L $state_dir || $(stat -c '%u' -- "$state_dir" 2>/dev/null || true) != "$EUID" ]]; then
      config_error "Unsafe configuration lock state directory: $state_dir"
      return 1
    fi
    mode=$(stat -c '%a' -- "$state_dir" 2>/dev/null || true)
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) || {
      config_error "Configuration lock state directory permissions must exclude group and other access: $state_dir"
      return 1
    }
    [[ -x $state_dir && -w $state_dir ]] || { config_error "Cannot access configuration lock state directory: $state_dir"; return 1; }
  else
    old_umask=$(umask)
    umask 077
    if ! mkdir -p -m 700 -- "$state_dir"; then
      umask "$old_umask"
      config_error "Cannot create configuration lock state directory: $state_dir"
      return 1
    fi
    umask "$old_umask"
    if [[ -L $state_dir || ! -d $state_dir || $(stat -c '%u' -- "$state_dir" 2>/dev/null || true) != "$EUID" ]]; then
      config_error "Unsafe configuration lock state directory after creation: $state_dir"
      return 1
    fi
    mode=$(stat -c '%a' -- "$state_dir" 2>/dev/null || true)
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) || {
      config_error "Configuration lock state directory permissions must exclude group and other access: $state_dir"
      return 1
    }
  fi

  if [[ ! -e $lock_path && ! -L $lock_path ]]; then
    old_umask=$(umask)
    umask 077
    (set -o noclobber; : > "$lock_path") 2>/dev/null || true
    umask "$old_umask"
  fi
  if [[ -L $lock_path || ! -f $lock_path || $(stat -c '%u' -- "$lock_path" 2>/dev/null || true) != "$EUID" ]]; then
    config_error "Unsafe configuration lock file: $lock_path"
    return 1
  fi
  mode=$(stat -c '%a' -- "$lock_path" 2>/dev/null || true)
  path_info=$(stat -c '%d:%i:%u:%a:%h:%F' -- "$lock_path" 2>/dev/null || true)
  if [[ $mode != 600 || $path_info != *:1:regular* ]]; then
    config_error "Configuration lock file must be a private, single-link regular file: $lock_path"
    return 1
  fi
  old_umask=$(umask)
  umask 077
  if ! exec {CONFIG_LOCK_FD}<>"$lock_path"; then
    umask "$old_umask"
    CONFIG_LOCK_FD=
    config_error "Cannot open configuration lock file: $lock_path"
    return 1
  fi
  umask "$old_umask"
  fd_info=$(stat -Lc '%d:%i:%u:%a:%h:%F' -- "/proc/$BASHPID/fd/$CONFIG_LOCK_FD" 2>/dev/null || true)
  path_info=$(stat -c '%d:%i:%u:%a:%h:%F' -- "$lock_path" 2>/dev/null || true)
  IFS=: read -r fd_device fd_inode fd_owner fd_mode fd_links fd_type <<< "$fd_info"
  if config_path_has_symlink "$home" .local/state/arclith \
    || config_path_has_non_directory_ancestor "$home" .local/state/arclith \
    || [[ -L $lock_path || -z $fd_info || $fd_info != "$path_info" \
    || $fd_owner != "$EUID" || $fd_mode != 600 || $fd_links != 1 || $fd_type != regular* ]]; then
    exec {CONFIG_LOCK_FD}>&-
    CONFIG_LOCK_FD=
    config_error "Configuration lock file changed or cannot be verified: $lock_path"
    return 1
  fi

  CONFIG_LOCK_FLOCK_BIN=$(type -P flock 2>/dev/null || true)
  if [[ -z $CONFIG_LOCK_FLOCK_BIN ]]; then
    exec {CONFIG_LOCK_FD}>&-
    CONFIG_LOCK_FD=
    config_error 'Cannot acquire configuration lock: flock is unavailable; no operation lock was taken'
    return 1
  fi
  if "$CONFIG_LOCK_FLOCK_BIN" -E "$CONFIG_LOCK_BUSY_STATUS" -n -x "$CONFIG_LOCK_FD"; then
    CONFIG_LOCK_OWNER_PID=$BASHPID
    CONFIG_LOCK_HOME=$home
    return 0
  else
    flock_status=$?
  fi
  exec {CONFIG_LOCK_FD}>&-
  CONFIG_LOCK_FD=
  if (( flock_status == CONFIG_LOCK_BUSY_STATUS )); then
    config_error 'Another Arclith configuration operation holds the lock'
    return "$CONFIG_LOCK_BUSY_STATUS"
  fi
  config_error "Cannot acquire configuration lock (flock status $flock_status): $lock_path"
  return 1
}

config_lock_release() {
  local fd=${CONFIG_LOCK_FD:-} status=0
  [[ $fd =~ ^[0-9]+$ ]] || { config_error 'No Arclith configuration lock is held by this shell'; return 1; }
  if [[ $CONFIG_LOCK_OWNER_PID != "$BASHPID" ]]; then
    config_error 'Configuration lock must be released by the Bash process that acquired it'
    return 1
  fi
  if [[ -z $CONFIG_LOCK_FLOCK_BIN || ! -x $CONFIG_LOCK_FLOCK_BIN ]]; then
    config_error 'Cannot explicitly release configuration lock: flock is unavailable; closing its descriptor'
    status=1
  elif ! "$CONFIG_LOCK_FLOCK_BIN" -u "$fd"; then
    config_error 'Could not explicitly unlock configuration operation; closing its descriptor to release it'
    status=1
  fi
  exec {CONFIG_LOCK_FD}>&- || status=1
  CONFIG_LOCK_FD=
  CONFIG_LOCK_FLOCK_BIN=
  CONFIG_LOCK_OWNER_PID=
  CONFIG_LOCK_HOME=
  return "$status"
}

# Run one complete home deployment mutation under its lock. The operation is
# called in this shell so its lock descriptor remains owned until cleanup.
config_lock_execute() {
  local home=$1 operation=$2 status release_status
  shift 2
  config_lock_acquire "$home" || return $?
  if "$operation" "$@"; then status=0; else status=$?; fi
  if config_lock_release; then
    release_status=0
  else
    release_status=$?
  fi
  if (( status == 0 && release_status != 0 )); then return "$release_status"; fi
  return "$status"
}

CONFIG_TXN_JOURNAL_ID=
CONFIG_TXN_JOURNAL_OPERATION=
CONFIG_TXN_JOURNAL_COMPONENT=
CONFIG_TXN_JOURNAL_STATE=
CONFIG_TXN_JOURNAL_CREATED_UTC=
CONFIG_TXN_JOURNAL_UPDATED_UTC=

config_transaction_journal_validate_timestamp() {
  local timestamp=$1 normalized
  [[ $timestamp =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  normalized=$(date -u -d "$timestamp" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || return 1
  [[ $normalized == "$timestamp" ]]
}

config_transaction_journal_valid_operation() {
  case ${1:-} in apply|apply-new|restore|uninstall|prune) return 0 ;; *) return 1 ;; esac
}

config_transaction_journal_valid_state() {
  case ${1:-} in
    PREPARING|PREPARED|APPLYING|COMMITTING|COMPLETE|ROLLING_BACK|ROLLED_BACK|UNCERTAIN) return 0 ;;
    *) return 1 ;;
  esac
}

config_transaction_journal_transition_allowed() {
  local from=$1 to=$2
  case $from:$to in
    PREPARING:PREPARED|PREPARING:ROLLING_BACK|PREPARING:UNCERTAIN \
    |PREPARED:APPLYING|PREPARED:ROLLING_BACK|PREPARED:UNCERTAIN \
    |APPLYING:COMMITTING|APPLYING:ROLLING_BACK|APPLYING:UNCERTAIN \
    |COMMITTING:COMPLETE|COMMITTING:ROLLING_BACK|COMMITTING:UNCERTAIN \
    |ROLLING_BACK:ROLLED_BACK|ROLLING_BACK:UNCERTAIN) return 0 ;;
    *) return 1 ;;
  esac
}

config_transaction_journal_home() {
  local home=${1:-}
  [[ $home == /* && ! -L $home && -d $home ]] || {
    config_error 'Transaction journal requires an existing absolute, non-symlink home directory'
    return 1
  }
  home=$(cd -- "$home" && pwd -P) || { config_error 'Cannot resolve transaction journal home'; return 1; }
  if config_path_has_symlink "$home" .local/state/arclith/transactions \
    || config_path_has_non_directory_ancestor "$home" .local/state/arclith/transactions; then
    config_error "Unsafe transaction journal directory: $home/.local/state/arclith/transactions"
    return 1
  fi
  printf '%s' "$home"
}

config_transaction_journal_require_lock() {
  local home=$1 locked_home
  if [[ -z ${CONFIG_LOCK_FD:-} || $CONFIG_LOCK_OWNER_PID != "$BASHPID" ]]; then
    config_error 'Transaction journal writes require this Bash process to hold the per-home configuration lock'
    return 1
  fi
  locked_home=$(config_transaction_journal_home "$CONFIG_LOCK_HOME") || return 1
  if [[ $locked_home != "$home" ]]; then
    config_error 'Transaction journal writes require the matching per-home configuration lock'
    return 1
  fi
}

config_transaction_journal_directory() {
  local home=$1 state_dir journal_dir owner mode
  state_dir=$(config_state_directory "$home")
  journal_dir="$state_dir/transactions"
  [[ -d $state_dir && ! -L $state_dir ]] || { config_error "Unsafe transaction journal parent: $state_dir"; return 1; }
  owner=$(stat -c '%u' -- "$state_dir" 2>/dev/null) || { config_error "Cannot inspect transaction journal parent: $state_dir"; return 1; }
  mode=$(stat -c '%a' -- "$state_dir" 2>/dev/null) || { config_error "Cannot inspect transaction journal parent: $state_dir"; return 1; }
  [[ $owner == "$EUID" && $mode =~ ^[0-7]{3,4}$ ]] \
    && (( (8#$mode & 077) == 0 )) || { config_error "Unsafe transaction journal parent: $state_dir"; return 1; }
  if [[ -e $journal_dir || -L $journal_dir ]]; then
    owner=$(stat -c '%u' -- "$journal_dir" 2>/dev/null || true)
    mode=$(stat -c '%a' -- "$journal_dir" 2>/dev/null || true)
    [[ -d $journal_dir && ! -L $journal_dir && $owner == "$EUID" && $mode == 700 ]] || {
      config_error "Unsafe transaction journal directory: $journal_dir"
      return 1
    }
  else
    local old_umask
    old_umask=$(umask)
    umask 077
    if ! mkdir -m 700 -- "$journal_dir"; then
      umask "$old_umask"
      config_error "Cannot create transaction journal directory: $journal_dir"
      return 1
    fi
    umask "$old_umask"
  fi
  printf '%s' "$journal_dir"
}

config_transaction_journal_check_directory() {
  local home=$1 state_dir journal_dir owner mode
  state_dir=$(config_state_directory "$home")
  journal_dir="$state_dir/transactions"
  [[ -d $state_dir && ! -L $state_dir ]] || { config_error "Unsafe transaction journal parent: $state_dir"; return 1; }
  owner=$(stat -c '%u' -- "$state_dir" 2>/dev/null) || { config_error "Cannot inspect transaction journal parent: $state_dir"; return 1; }
  mode=$(stat -c '%a' -- "$state_dir" 2>/dev/null) || { config_error "Cannot inspect transaction journal parent: $state_dir"; return 1; }
  [[ $owner == "$EUID" && $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) \
    || { config_error "Unsafe transaction journal parent: $state_dir"; return 1; }
  [[ -d $journal_dir && ! -L $journal_dir ]] || { config_error "Transaction journal directory is unavailable: $journal_dir"; return 1; }
  owner=$(stat -c '%u' -- "$journal_dir" 2>/dev/null) || { config_error "Cannot inspect transaction journal directory: $journal_dir"; return 1; }
  mode=$(stat -c '%a' -- "$journal_dir" 2>/dev/null) || { config_error "Cannot inspect transaction journal directory: $journal_dir"; return 1; }
  [[ $owner == "$EUID" && $mode == 700 ]] || { config_error "Unsafe transaction journal directory: $journal_dir"; return 1; }
}

config_transaction_journal_path() {
  local directory=$1 id=$2
  [[ $id =~ ^[a-f0-9]{32}$ ]] || { config_error 'Invalid transaction journal identifier'; return 1; }
  printf '%s/%s.v1' "$directory" "$id"
}

config_transaction_journal_parse_fd() {
  local path=$1 expected_id=$2 fd=$3 metadata path_metadata fd_path="/proc/$BASHPID/fd/$3"
  local owner mode links type size key extra separators i read_status
  local id operation component state created updated
  local -a lines=()
  CONFIG_TXN_PARSE_REASON=MALFORMED_RECORD
  CONFIG_TXN_PARSE_OPERATIONAL=no
  [[ -f $path && ! -L $path ]] || { CONFIG_TXN_PARSE_REASON=UNSAFE_STORAGE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Transaction journal is not a regular file: $path"; return 1; }
  metadata=$(stat -Lc '%d:%i:%u:%a:%h:%F' -- "$fd_path" 2>/dev/null) || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot inspect open transaction journal: $path"; return 1; }
  path_metadata=$(stat -c '%d:%i:%u:%a:%h:%F' -- "$path" 2>/dev/null) || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot inspect transaction journal: $path"; return 1; }
  [[ $metadata == "$path_metadata" ]] || { CONFIG_TXN_PARSE_REASON=UNSAFE_STORAGE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Transaction journal changed while opening: $path"; return 1; }
  IFS=: read -r _ _ owner mode links type <<< "$metadata"
  [[ $owner == "$EUID" && $mode == 600 && $links == 1 && $type == 'regular file' ]] || {
    CONFIG_TXN_PARSE_REASON=UNSAFE_STORAGE; CONFIG_TXN_PARSE_OPERATIONAL=yes
    config_error "Unsafe transaction journal file: $path"
    return 1
  }
  size=$(stat -Lc '%s' -- "$fd_path" 2>/dev/null) || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot inspect transaction journal size: $path"; return 1; }
  [[ $size =~ ^[0-9]{1,4}$ ]] && (( size <= 1024 )) \
    || { config_error "Transaction journal exceeds the supported record size: $path"; return 1; }
  if LC_ALL=C grep -Iq . -- "$fd_path"; then :; else
    read_status=$?
    if (( read_status > 1 )); then CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; fi
    config_error "Transaction journal is empty or contains binary data: $path"
    return 1
  fi
  mapfile -u "$fd" -t lines || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot read transaction journal: $path"; return 1; }
  [[ ${lines[0]:-} == ARCLITH_TXN\|* && ${lines[0]} != 'ARCLITH_TXN|1' ]] && { CONFIG_TXN_PARSE_REASON=UNSUPPORTED_SCHEMA; config_error "Unsupported transaction journal schema: $path"; return 1; }
  (( ${#lines[@]} == 7 )) || { CONFIG_TXN_PARSE_REASON=MALFORMED_RECORD; config_error "Malformed transaction journal: $path"; return 1; }
  [[ ${lines[0]} == 'ARCLITH_TXN|1' ]] || {
    config_error "Malformed or unsupported transaction journal: $path"
    return 1
  }
  for ((i=1; i<7; i++)); do
    separators=${lines[i]//[^|]/}
    [[ ${#separators} == 1 ]] || { config_error "Malformed transaction journal field: $path"; return 1; }
  done
  IFS='|' read -r key id extra <<< "${lines[1]}"
  [[ $key == ID && -z $extra && $id =~ ^[a-f0-9]{32}$ && $id == "$expected_id" ]] \
    || { CONFIG_TXN_PARSE_REASON=INVALID_IDENTIFIER; config_error "Invalid transaction journal ID: $path"; return 1; }
  IFS='|' read -r key operation extra <<< "${lines[2]}"
  [[ $key == OPERATION && -z $extra ]] && config_transaction_journal_valid_operation "$operation" \
    || { config_error "Invalid transaction journal operation: $path"; return 1; }
  IFS='|' read -r key component extra <<< "${lines[3]}"
  [[ $key == COMPONENT && -z $extra && $component =~ ^[a-z][a-z0-9_-]{0,63}$ ]] \
    || { config_error "Invalid transaction journal component: $path"; return 1; }
  IFS='|' read -r key state extra <<< "${lines[4]}"
  [[ $key == STATE && -z $extra ]] && config_transaction_journal_valid_state "$state" \
    || { config_error "Invalid transaction journal state: $path"; return 1; }
  IFS='|' read -r key created extra <<< "${lines[5]}"
  [[ $key == CREATED_UTC && -z $extra ]] && config_transaction_journal_validate_timestamp "$created" \
    || { CONFIG_TXN_PARSE_REASON=INVALID_TIMESTAMP; config_error "Invalid transaction journal creation timestamp: $path"; return 1; }
  IFS='|' read -r key updated extra <<< "${lines[6]}"
  [[ $key == UPDATED_UTC && -z $extra ]] && config_transaction_journal_validate_timestamp "$updated" \
    || { CONFIG_TXN_PARSE_REASON=INVALID_TIMESTAMP; config_error "Invalid transaction journal update timestamp: $path"; return 1; }
  CONFIG_TXN_JOURNAL_ID=$id
  CONFIG_TXN_JOURNAL_OPERATION=$operation
  CONFIG_TXN_JOURNAL_COMPONENT=$component
  CONFIG_TXN_JOURNAL_STATE=$state
  CONFIG_TXN_JOURNAL_CREATED_UTC=$created
  CONFIG_TXN_JOURNAL_UPDATED_UTC=$updated
}

config_transaction_journal_parse_file() {
  local path=$1 expected_id=$2 fd status=0
  CONFIG_TXN_PARSE_REASON=MALFORMED_RECORD
  CONFIG_TXN_PARSE_OPERATIONAL=no
  if ! exec {fd}< "$path"; then CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot open transaction journal: $path"; return 1; fi
  if config_transaction_journal_parse_fd "$path" "$expected_id" "$fd"; then
    status=0
  else
    status=$?
  fi
  exec {fd}<&- || { (( status != 0 )) || status=1; }
  return "$status"
}

config_transaction_journal_read() {
  local home directory path id=${2:-}
  (( $# == 2 )) || { config_error 'Usage: config_transaction_journal_read <home> <id>'; return 2; }
  [[ $id =~ ^[a-f0-9]{32}$ ]] || { config_error 'Invalid transaction journal identifier'; return 1; }
  home=$(config_transaction_journal_home "$1") || return 1
  config_transaction_journal_check_directory "$home" || return 1
  directory="$home/.local/state/arclith/transactions"
  path=$(config_transaction_journal_path "$directory" "$id") || return 1
  config_transaction_journal_parse_file "$path" "$id"
}

config_transaction_journal_serialize() {
  printf 'ARCLITH_TXN|1\nID|%s\nOPERATION|%s\nCOMPONENT|%s\nSTATE|%s\nCREATED_UTC|%s\nUPDATED_UTC|%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6"
}

config_transaction_journal_store() {
  local home=$1 id=$2 operation=$3 component=$4 state=$5 created=$6 updated=$7
  local directory path temp mv_status
  local saved_id=$CONFIG_TXN_JOURNAL_ID saved_operation=$CONFIG_TXN_JOURNAL_OPERATION
  local saved_component=$CONFIG_TXN_JOURNAL_COMPONENT saved_state=$CONFIG_TXN_JOURNAL_STATE
  local saved_created=$CONFIG_TXN_JOURNAL_CREATED_UTC saved_updated=$CONFIG_TXN_JOURNAL_UPDATED_UTC
  home=$(config_transaction_journal_home "$home") || return 1
  config_transaction_journal_require_lock "$home" || return 1
  [[ $id =~ ^[a-f0-9]{32}$ ]] || { config_error 'Invalid transaction journal identifier'; return 1; }
  config_transaction_journal_valid_operation "$operation" || { config_error "Invalid transaction operation: $operation"; return 1; }
  [[ $component =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || { config_error "Invalid transaction component: $component"; return 1; }
  config_transaction_journal_valid_state "$state" || { config_error "Invalid transaction state: $state"; return 1; }
  config_transaction_journal_validate_timestamp "$created" && config_transaction_journal_validate_timestamp "$updated" \
    || { config_error 'Invalid transaction journal timestamp'; return 1; }
  directory=$(config_transaction_journal_directory "$home") || return 1
  path=$(config_transaction_journal_path "$directory" "$id") || return 1
  temp=$(mktemp "$directory/.$id.tmp.XXXXXXXX") || { config_error "Cannot create transaction journal temporary file in: $directory"; return 1; }
  if ! chmod 600 -- "$temp" \
    || ! config_transaction_journal_serialize "$id" "$operation" "$component" "$state" "$created" "$updated" > "$temp"; then
    rm -f -- "$temp"
    CONFIG_TXN_JOURNAL_ID=$saved_id
    CONFIG_TXN_JOURNAL_OPERATION=$saved_operation
    CONFIG_TXN_JOURNAL_COMPONENT=$saved_component
    CONFIG_TXN_JOURNAL_STATE=$saved_state
    CONFIG_TXN_JOURNAL_CREATED_UTC=$saved_created
    CONFIG_TXN_JOURNAL_UPDATED_UTC=$saved_updated
    config_error "Could not write transaction journal temporary file: $temp"
    return 1
  fi
  if ! config_transaction_journal_parse_file "$temp" "$id"; then
    rm -f -- "$temp"
    CONFIG_TXN_JOURNAL_ID=$saved_id
    CONFIG_TXN_JOURNAL_OPERATION=$saved_operation
    CONFIG_TXN_JOURNAL_COMPONENT=$saved_component
    CONFIG_TXN_JOURNAL_STATE=$saved_state
    CONFIG_TXN_JOURNAL_CREATED_UTC=$saved_created
    CONFIG_TXN_JOURNAL_UPDATED_UTC=$saved_updated
    config_error 'Serialized transaction journal failed validation'
    return 1
  fi
  if mv -fT -- "$temp" "$path"; then
    config_transaction_journal_parse_file "$path" "$id"
    return $?
  else
    mv_status=$?
  fi
  if config_transaction_journal_parse_file "$path" "$id" 2>/dev/null \
    && [[ $CONFIG_TXN_JOURNAL_ID == "$id" \
      && $CONFIG_TXN_JOURNAL_OPERATION == "$operation" \
      && $CONFIG_TXN_JOURNAL_COMPONENT == "$component" \
      && $CONFIG_TXN_JOURNAL_STATE == "$state" \
      && $CONFIG_TXN_JOURNAL_CREATED_UTC == "$created" \
      && $CONFIG_TXN_JOURNAL_UPDATED_UTC == "$updated" ]]; then
    if [[ -e $temp || -L $temp ]]; then
      rm -f -- "$temp" || config_error "Journal state persisted, but temporary-file cleanup failed: $temp"
    fi
    return 0
  fi
  if [[ -e $temp || -L $temp ]]; then
    rm -f -- "$temp" || config_error "Could not remove journal temporary file after replacement failure: $temp"
  fi
  CONFIG_TXN_JOURNAL_ID=$saved_id
  CONFIG_TXN_JOURNAL_OPERATION=$saved_operation
  CONFIG_TXN_JOURNAL_COMPONENT=$saved_component
  CONFIG_TXN_JOURNAL_STATE=$saved_state
  CONFIG_TXN_JOURNAL_CREATED_UTC=$saved_created
  CONFIG_TXN_JOURNAL_UPDATED_UTC=$saved_updated
  config_error "Could not atomically replace transaction journal (mv status $mv_status); destination does not contain the requested record: $path"
  return 1
}

config_transaction_journal_create() {
  local home directory id operation=${2:-} component=${3:-} created attempt
  (( $# == 3 )) || { config_error 'Usage: config_transaction_journal_create <home> <operation> <component>'; return 2; }
  CONFIG_TXN_JOURNAL_ID=
  home=$(config_transaction_journal_home "$1") || return 1
  config_transaction_journal_require_lock "$home" || return 1
  config_transaction_journal_valid_operation "$operation" || { config_error "Invalid transaction operation: $operation"; return 1; }
  [[ $component =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || { config_error "Invalid transaction component: $component"; return 1; }
  directory=$(config_transaction_journal_directory "$home") || return 1
  for ((attempt=0; attempt<8; attempt++)); do
    id=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n') || { config_error 'Cannot generate a transaction journal identifier'; return 1; }
    [[ $id =~ ^[a-f0-9]{32}$ ]] || { config_error 'Generated transaction journal identifier is invalid'; return 1; }
    [[ ! -e $directory/$id.v1 && ! -L $directory/$id.v1 ]] || continue
    created=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || { config_error 'Cannot create transaction journal timestamp'; return 1; }
    if ! config_transaction_journal_store "$home" "$id" "$operation" "$component" PREPARING "$created" "$created"; then
      # A rename wrapper or filesystem can report failure after replacement.
      # Expose a valid persisted record to the caller so it can retain an
      # explicit uncertain outcome instead of silently losing the allocated ID.
      if config_transaction_journal_parse_file "$directory/$id.v1" "$id" \
        && [[ $CONFIG_TXN_JOURNAL_ID == "$id" \
          && $CONFIG_TXN_JOURNAL_OPERATION == "$operation" \
          && $CONFIG_TXN_JOURNAL_COMPONENT == "$component" \
          && $CONFIG_TXN_JOURNAL_STATE == PREPARING \
          && $CONFIG_TXN_JOURNAL_CREATED_UTC == "$created" \
          && $CONFIG_TXN_JOURNAL_UPDATED_UTC == "$created" ]]; then
        CONFIG_TXN_JOURNAL_ID=$id
      else
        CONFIG_TXN_JOURNAL_ID=
        CONFIG_TXN_JOURNAL_OPERATION=
        CONFIG_TXN_JOURNAL_COMPONENT=
        CONFIG_TXN_JOURNAL_STATE=
        CONFIG_TXN_JOURNAL_CREATED_UTC=
        CONFIG_TXN_JOURNAL_UPDATED_UTC=
      fi
      return 1
    fi
    CONFIG_TXN_JOURNAL_ID=$id
    return 0
  done
  config_error 'Could not allocate a unique transaction journal identifier'
  return 1
}

config_transaction_journal_transition() {
  local home id=${2:-} next_state=${3:-} operation component created updated
  (( $# == 3 )) || { config_error 'Usage: config_transaction_journal_transition <home> <id> <state>'; return 2; }
  home=$(config_transaction_journal_home "$1") || return 1
  config_transaction_journal_require_lock "$home" || return 1
  config_transaction_journal_read "$home" "$id" || return 1
  if ! config_transaction_journal_transition_allowed "$CONFIG_TXN_JOURNAL_STATE" "$next_state"; then
    config_error "Invalid transaction journal transition: $CONFIG_TXN_JOURNAL_STATE -> $next_state"
    return 1
  fi
  operation=$CONFIG_TXN_JOURNAL_OPERATION
  component=$CONFIG_TXN_JOURNAL_COMPONENT
  created=$CONFIG_TXN_JOURNAL_CREATED_UTC
  updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || { config_error 'Cannot update transaction journal timestamp'; return 1; }
  config_transaction_journal_store "$home" "$id" "$operation" "$component" "$next_state" "$created" "$updated"
}

CONFIG_TXN_TARGET_TRANSACTION=
CONFIG_TXN_TARGET_OPERATION=
CONFIG_TXN_TARGET_COMPONENT=
CONFIG_TXN_TARGET_INDEX=
CONFIG_TXN_TARGET_PATH=
CONFIG_TXN_TARGET_ORIGINAL=
CONFIG_TXN_TARGET_BACKUP=
CONFIG_TXN_TARGET_SOURCE_BACKUP=
CONFIG_TXN_TARGET_ROLLBACK_BACKUP=
CONFIG_TXN_TARGET_STATE=
CONFIG_TXN_TARGET_UPDATED_UTC=

config_transaction_target_valid_state() {
  case ${1:-} in PLANNED|STAGED|MUTATION_INTENT|APPLIED|ROLLBACK_INTENT|ROLLED_BACK|NOT_MUTATED|ALREADY_ABSENT|UNCERTAIN) return 0 ;; *) return 1 ;; esac
}

config_transaction_target_transition_allowed() {
  case $1:$2 in
    PLANNED:STAGED|PLANNED:NOT_MUTATED|PLANNED:ALREADY_ABSENT|PLANNED:UNCERTAIN \
    |STAGED:MUTATION_INTENT|STAGED:NOT_MUTATED|STAGED:UNCERTAIN \
    |MUTATION_INTENT:APPLIED|MUTATION_INTENT:ROLLBACK_INTENT|MUTATION_INTENT:NOT_MUTATED|MUTATION_INTENT:UNCERTAIN \
    |APPLIED:ROLLBACK_INTENT|APPLIED:UNCERTAIN \
    |ROLLBACK_INTENT:ROLLED_BACK|ROLLBACK_INTENT:UNCERTAIN) return 0 ;;
    *) return 1 ;;
  esac
}

config_transaction_target_directory() {
  local home=$1 transaction=$2 directory
  [[ $transaction =~ ^[a-f0-9]{32}$ ]] || { config_error 'Invalid transaction identifier for target checkpoint'; return 1; }
  config_transaction_journal_check_directory "$home" || return 1
  directory="$home/.local/state/arclith/transactions/$transaction.targets"
  if [[ -e $directory || -L $directory ]]; then
    [[ -d $directory && ! -L $directory && $(stat -c '%u:%a' -- "$directory" 2>/dev/null) == "$EUID:700" ]] \
      || { config_error "Unsafe transaction target-checkpoint directory: $directory"; return 1; }
  else
    local old_umask
    old_umask=$(umask)
    umask 077
    if ! mkdir -m 700 -- "$directory"; then
      umask "$old_umask"
      config_error "Cannot create transaction target-checkpoint directory: $directory"
      return 1
    fi
    umask "$old_umask"
  fi
  printf '%s' "$directory"
}

config_transaction_target_parse_fd() {
  local path=$1 transaction=$2 index=$3 fd=$4 metadata path_metadata fd_path="/proc/$BASHPID/fd/$4"
  local owner mode links type size i separators key extra version read_status
  local record_transaction operation component record_index target original backup source_backup rollback_backup state updated
  local -a lines=()
  CONFIG_TXN_PARSE_REASON=MALFORMED_RECORD
  CONFIG_TXN_PARSE_OPERATIONAL=no
  [[ -f $path && ! -L $path ]] || { CONFIG_TXN_PARSE_REASON=UNSAFE_STORAGE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Target checkpoint is not a regular file: $path"; return 1; }
  metadata=$(stat -Lc '%d:%i:%u:%a:%h:%F' -- "$fd_path" 2>/dev/null) || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot inspect open target checkpoint: $path"; return 1; }
  path_metadata=$(stat -c '%d:%i:%u:%a:%h:%F' -- "$path" 2>/dev/null) || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot inspect target checkpoint: $path"; return 1; }
  [[ $metadata == "$path_metadata" ]] || { CONFIG_TXN_PARSE_REASON=UNSAFE_STORAGE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Target checkpoint changed while opening: $path"; return 1; }
  IFS=: read -r _ _ owner mode links type <<< "$metadata"
  [[ $owner == "$EUID" && $mode == 600 && $links == 1 && $type == 'regular file' ]] \
    || { CONFIG_TXN_PARSE_REASON=UNSAFE_STORAGE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Unsafe target checkpoint file: $path"; return 1; }
  size=$(stat -Lc '%s' -- "$fd_path" 2>/dev/null) || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; return 1; }
  [[ $size =~ ^[0-9]{1,4}$ ]] && (( size <= 1024 )) \
    || { config_error "Target checkpoint exceeds supported size: $path"; return 1; }
  if LC_ALL=C grep -Iq . -- "$fd_path"; then :; else
    read_status=$?
    if (( read_status > 1 )); then CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; fi
    config_error "Target checkpoint is empty or binary: $path"
    return 1
  fi
  mapfile -u "$fd" -t lines || { CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; return 1; }
  case ${lines[0]:-} in
    'ARCLITH_TARGET|1') version=1; (( ${#lines[@]} == 10 )) || { config_error "Malformed target checkpoint: $path"; return 1; } ;;
    'ARCLITH_TARGET|2') version=2; (( ${#lines[@]} == 11 )) || { config_error "Malformed target checkpoint: $path"; return 1; } ;;
    *) [[ ${lines[0]:-} == ARCLITH_TARGET\|* ]] && CONFIG_TXN_PARSE_REASON=UNSUPPORTED_SCHEMA; config_error "Malformed or unsupported target checkpoint: $path"; return 1 ;;
  esac
  for ((i=1; i<${#lines[@]}; i++)); do
    separators=${lines[i]//[^|]/}
    [[ ${#separators} == 1 ]] || { config_error "Malformed target checkpoint field: $path"; return 1; }
  done
  IFS='|' read -r key record_transaction extra <<< "${lines[1]}"
  [[ $key == TRANSACTION && -z $extra && $record_transaction == "$transaction" ]] || { CONFIG_TXN_PARSE_REASON=IDENTITY_MISMATCH; return 1; }
  IFS='|' read -r key operation extra <<< "${lines[2]}"
  [[ $key == OPERATION && -z $extra ]] || return 1
  IFS='|' read -r key component extra <<< "${lines[3]}"
  [[ $key == COMPONENT && -z $extra && $component =~ ^[a-z][a-z0-9_-]{0,63}$ ]] || return 1
  IFS='|' read -r key record_index extra <<< "${lines[4]}"
  [[ $key == INDEX && -z $extra && $record_index == "$index" ]] || { CONFIG_TXN_PARSE_REASON=IDENTITY_MISMATCH; return 1; }
  IFS='|' read -r key target extra <<< "${lines[5]}"
  [[ $key == TARGET && -z $extra ]] && config_safe_relative_path "$target" \
    || { CONFIG_TXN_PARSE_REASON=INVALID_TARGET_PATH; config_error "Invalid target path in checkpoint: $path"; return 1; }
  config_state_target_valid "$component" "$target" || { CONFIG_TXN_PARSE_REASON=INVALID_TARGET_PATH; config_error "Target is outside its registered component: $path"; return 1; }
  IFS='|' read -r key original extra <<< "${lines[6]}"
  [[ $key == ORIGINAL && -z $extra && ( $original == yes || $original == no ) ]] || return 1
  if [[ $version == 1 ]]; then
    [[ $operation == apply || $operation == apply-new || $operation == uninstall || $operation == prune ]] \
      || { config_error 'Version 1 target checkpoints are valid only for apply, apply-new, uninstall, or prune operations'; return 1; }
    IFS='|' read -r key backup extra <<< "${lines[7]}"
    [[ $key == BACKUP && -z $extra && ( $backup == - || $backup =~ ^[A-Za-z0-9]{8}$ ) ]] || return 1
    source_backup=-
    rollback_backup=$backup
    IFS='|' read -r key state extra <<< "${lines[8]}"
    [[ $key == STATE && -z $extra ]] && config_transaction_target_valid_state "$state" || { CONFIG_TXN_PARSE_REASON=INVALID_TARGET_STATE; return 1; }
    if [[ $state == ALREADY_ABSENT ]]; then
      [[ ( $operation == uninstall || $operation == prune ) && $original == no && $backup == - ]] || return 1
    fi
    IFS='|' read -r key updated extra <<< "${lines[9]}"
    [[ $key == UPDATED_UTC && -z $extra ]] && config_transaction_journal_validate_timestamp "$updated" || { CONFIG_TXN_PARSE_REASON=INVALID_TIMESTAMP; return 1; }
  else
    [[ $operation == restore ]] || { config_error 'Version 2 target checkpoints are valid only for restore'; return 1; }
    IFS='|' read -r key source_backup extra <<< "${lines[7]}"
    [[ $key == SOURCE_BACKUP && -z $extra && $source_backup =~ ^[A-Za-z0-9]{8}$ ]] || return 1
    IFS='|' read -r key rollback_backup extra <<< "${lines[8]}"
    [[ $key == ROLLBACK_BACKUP && -z $extra && ( $rollback_backup == - || $rollback_backup =~ ^[A-Za-z0-9]{8}$ ) ]] || return 1
    [[ $original == yes || $rollback_backup == - ]] || { config_error 'Absent original target cannot reference a rollback backup'; return 1; }
    IFS='|' read -r key state extra <<< "${lines[9]}"
    [[ $key == STATE && -z $extra ]] && config_transaction_target_valid_state "$state" || { CONFIG_TXN_PARSE_REASON=INVALID_TARGET_STATE; return 1; }
    [[ $state != ALREADY_ABSENT ]] || { config_error 'ALREADY_ABSENT is valid only for uninstall and prune records'; return 1; }
    IFS='|' read -r key updated extra <<< "${lines[10]}"
    [[ $key == UPDATED_UTC && -z $extra ]] && config_transaction_journal_validate_timestamp "$updated" || { CONFIG_TXN_PARSE_REASON=INVALID_TIMESTAMP; return 1; }
  fi
  CONFIG_TXN_TARGET_TRANSACTION=$record_transaction
  CONFIG_TXN_TARGET_OPERATION=$operation
  CONFIG_TXN_TARGET_COMPONENT=$component
  CONFIG_TXN_TARGET_INDEX=$record_index
  CONFIG_TXN_TARGET_PATH=$target
  CONFIG_TXN_TARGET_ORIGINAL=$original
  CONFIG_TXN_TARGET_BACKUP=$rollback_backup
  CONFIG_TXN_TARGET_SOURCE_BACKUP=$source_backup
  CONFIG_TXN_TARGET_ROLLBACK_BACKUP=$rollback_backup
  CONFIG_TXN_TARGET_STATE=$state
  CONFIG_TXN_TARGET_UPDATED_UTC=$updated
}

config_transaction_target_parse_file() {
  local path=$1 transaction=$2 index=$3 fd status=0
  CONFIG_TXN_PARSE_REASON=MALFORMED_RECORD
  CONFIG_TXN_PARSE_OPERATIONAL=no
  if ! exec {fd}< "$path"; then CONFIG_TXN_PARSE_REASON=RECORD_INACCESSIBLE; CONFIG_TXN_PARSE_OPERATIONAL=yes; config_error "Cannot open target checkpoint: $path"; return 1; fi
  if config_transaction_target_parse_fd "$path" "$transaction" "$index" "$fd"; then status=0; else status=$?; fi
  exec {fd}<&- || { (( status != 0 )) || status=1; }
  return "$status"
}

config_transaction_target_read() {
  local home=$1 transaction=$2 index=$3 directory path
  [[ $index =~ ^[0-9]{6}$ ]] || { config_error 'Invalid target checkpoint index'; return 1; }
  home=$(config_transaction_journal_home "$home") || return 1
  [[ $transaction =~ ^[a-f0-9]{32}$ ]] || { config_error 'Invalid transaction identifier for target checkpoint'; return 1; }
  config_transaction_journal_check_directory "$home" || return 1
  directory="$home/.local/state/arclith/transactions/$transaction.targets"
  [[ -d $directory && ! -L $directory && $(stat -c '%u:%a' -- "$directory" 2>/dev/null) == "$EUID:700" ]] \
    || { config_error "Target checkpoint directory is unavailable or unsafe: $directory"; return 1; }
  if [[ ( -e $directory/$index.v1 || -L $directory/$index.v1 ) && ( -e $directory/$index.v2 || -L $directory/$index.v2 ) ]]; then
    config_error 'Conflicting target checkpoint versions exist for one index'
    return 1
  fi
  if [[ -e $directory/$index.v2 || -L $directory/$index.v2 ]]; then
    path="$directory/$index.v2"
  else
    path="$directory/$index.v1"
  fi
  config_transaction_target_parse_file "$path" "$transaction" "$index" || return 1
  config_transaction_journal_read "$home" "$transaction" || return 1
  [[ $CONFIG_TXN_JOURNAL_OPERATION == "$CONFIG_TXN_TARGET_OPERATION" \
    && $CONFIG_TXN_JOURNAL_COMPONENT == "$CONFIG_TXN_TARGET_COMPONENT" ]] \
    || { config_error 'Target checkpoint does not match its transaction record'; return 1; }
}

config_transaction_target_serialize() {
  printf 'ARCLITH_TARGET|1\nTRANSACTION|%s\nOPERATION|%s\nCOMPONENT|%s\nINDEX|%s\nTARGET|%s\nORIGINAL|%s\nBACKUP|%s\nSTATE|%s\nUPDATED_UTC|%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

config_transaction_target_serialize_v2() {
  printf 'ARCLITH_TARGET|2\nTRANSACTION|%s\nOPERATION|%s\nCOMPONENT|%s\nINDEX|%s\nTARGET|%s\nORIGINAL|%s\nSOURCE_BACKUP|%s\nROLLBACK_BACKUP|%s\nSTATE|%s\nUPDATED_UTC|%s\n' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9" "${10}"
}

config_transaction_target_checkpoint() {
  local home=$1 transaction=$2 index=$3 operation=$4 component=$5 target=$6 original=$7 backup=$8 state=$9
  local directory path temp updated
  local prior_backup prior_state
  [[ $index =~ ^[0-9]{6}$ ]] || { config_error 'Invalid target checkpoint index'; return 1; }
  [[ $operation == apply || $operation == apply-new || $operation == uninstall || $operation == prune ]] \
    || { config_error 'Unsupported target checkpoint operation'; return 1; }
  config_safe_relative_path "$target" && config_state_target_valid "$component" "$target" \
    || { config_error "Invalid target identifier for checkpoint: $target"; return 1; }
  [[ $original == yes || $original == no ]] || { config_error 'Invalid original-target presence value'; return 1; }
  [[ $backup == - || $backup =~ ^[A-Za-z0-9]{8}$ ]] || { config_error 'Invalid target backup reference'; return 1; }
  if [[ $operation == uninstall || $operation == prune ]]; then
    [[ $original == yes || $backup == - ]] || { config_error 'Absent target cannot reference a recovery backup'; return 1; }
    if [[ $state == ALREADY_ABSENT ]]; then
      [[ $original == no && $backup == - ]] || { config_error 'ALREADY_ABSENT requires an absent target without a recovery backup'; return 1; }
    fi
  fi
  config_transaction_target_valid_state "$state" || { config_error "Invalid target checkpoint state: $state"; return 1; }
  home=$(config_transaction_journal_home "$home") || return 1
  config_transaction_journal_require_lock "$home" || return 1
  config_transaction_journal_read "$home" "$transaction" || return 1
  [[ $CONFIG_TXN_JOURNAL_OPERATION == "$operation" && $CONFIG_TXN_JOURNAL_COMPONENT == "$component" ]] \
    || { config_error 'Target checkpoint does not match its transaction record'; return 1; }
  case $state:$CONFIG_TXN_JOURNAL_STATE in
    PLANNED:PREPARING|STAGED:PREPARING|MUTATION_INTENT:APPLYING|APPLIED:APPLYING \
    |ROLLBACK_INTENT:ROLLING_BACK|ROLLED_BACK:ROLLING_BACK|NOT_MUTATED:ROLLING_BACK \
    |UNCERTAIN:PREPARING|UNCERTAIN:PREPARED|UNCERTAIN:APPLYING|UNCERTAIN:COMMITTING|UNCERTAIN:ROLLING_BACK) ;;
    NOT_MUTATED:APPLYING|ALREADY_ABSENT:APPLYING)
      [[ ( $operation == uninstall || $operation == prune ) && ( $state != ALREADY_ABSENT || $original == no ) ]] \
        || { config_error 'No-op target outcome is invalid for this operation or target'; return 1; } ;;
    *) config_error "Target checkpoint state $state is invalid while transaction is $CONFIG_TXN_JOURNAL_STATE"; return 1 ;;
  esac
  directory=$(config_transaction_target_directory "$home" "$transaction") || return 1
  path="$directory/$index.v1"
  if [[ -e $directory/$index.v2 || -L $directory/$index.v2 ]]; then
    config_error 'Cannot mix version 1 and version 2 records at one target index'
    return 1
  fi
  if [[ -e $path || -L $path ]]; then
    config_transaction_target_parse_file "$path" "$transaction" "$index" || return 1
    [[ $CONFIG_TXN_TARGET_OPERATION == "$operation" && $CONFIG_TXN_TARGET_COMPONENT == "$component" \
      && $CONFIG_TXN_TARGET_PATH == "$target" && $CONFIG_TXN_TARGET_ORIGINAL == "$original" ]] \
      || { config_error 'Target checkpoint identity fields cannot be changed'; return 1; }
    prior_backup=$CONFIG_TXN_TARGET_BACKUP
    prior_state=$CONFIG_TXN_TARGET_STATE
    if [[ $prior_backup != "$backup" && $prior_backup != - ]]; then
      config_error 'Target checkpoint backup reference cannot be changed after staging'
      return 1
    fi
    if [[ $prior_backup == - && $backup != - && $prior_state != PLANNED ]]; then
      config_error 'Target backup reference must be recorded before the target is staged'
      return 1
    fi
    if [[ $prior_state != "$state" ]] && ! config_transaction_target_transition_allowed "$prior_state" "$state"; then
      config_error "Invalid target checkpoint transition: $prior_state -> $state"
      return 1
    fi
  else
    [[ $state == PLANNED && $backup == - ]] || { config_error 'New target checkpoints must begin in PLANNED without a backup'; return 1; }
  fi
  updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || { config_error 'Cannot timestamp target checkpoint'; return 1; }
  temp=$(mktemp "$directory/.$index.tmp.XXXXXXXX") || { config_error "Cannot create target checkpoint temporary file: $directory"; return 1; }
  if ! chmod 600 -- "$temp" \
    || ! config_transaction_target_serialize "$transaction" "$operation" "$component" "$index" "$target" "$original" "$backup" "$state" "$updated" > "$temp" \
    || ! config_transaction_target_parse_file "$temp" "$transaction" "$index"; then
    rm -f -- "$temp"
    config_error "Could not validate target checkpoint temporary file: $temp"
    return 1
  fi
  if ! mv -fT -- "$temp" "$path"; then
    rm -f -- "$temp"
    config_error "Could not atomically replace target checkpoint: $path"
    return 1
  fi
  config_transaction_target_parse_file "$path" "$transaction" "$index"
}

config_transaction_target_checkpoint_v2() {
  local home=$1 transaction=$2 index=$3 operation=$4 component=$5 target=$6 original=$7 source_backup=$8 rollback_backup=$9 state=${10}
  local directory path temp updated prior_source prior_rollback prior_state
  [[ $index =~ ^[0-9]{6}$ && $operation == restore ]] || { config_error 'Invalid version 2 target checkpoint identity'; return 1; }
  config_safe_relative_path "$target" && config_state_target_valid "$component" "$target" \
    || { config_error "Invalid target identifier for checkpoint: $target"; return 1; }
  [[ $original == yes || $original == no ]] || { config_error 'Invalid original-target presence value'; return 1; }
  [[ $source_backup =~ ^[A-Za-z0-9]{8}$ ]] || { config_error 'Invalid source-backup reference'; return 1; }
  [[ $rollback_backup == - || $rollback_backup =~ ^[A-Za-z0-9]{8}$ ]] || { config_error 'Invalid rollback-backup reference'; return 1; }
  [[ $original == yes || $rollback_backup == - ]] || { config_error 'Absent original target cannot reference a rollback backup'; return 1; }
  if [[ $original == yes && $state != PLANNED && $state != NOT_MUTATED && $rollback_backup == - ]]; then
    config_error 'A present original target requires its rollback backup before staging'
    return 1
  fi
  config_transaction_target_valid_state "$state" || { config_error "Invalid target checkpoint state: $state"; return 1; }
  home=$(config_transaction_journal_home "$home") || return 1
  config_transaction_journal_require_lock "$home" || return 1
  config_transaction_journal_read "$home" "$transaction" || return 1
  [[ $CONFIG_TXN_JOURNAL_OPERATION == restore && $CONFIG_TXN_JOURNAL_COMPONENT == "$component" ]] \
    || { config_error 'Target checkpoint does not match its restore transaction'; return 1; }
  case $state:$CONFIG_TXN_JOURNAL_STATE in
    PLANNED:PREPARING|STAGED:PREPARING|MUTATION_INTENT:APPLYING|APPLIED:APPLYING \
    |ROLLBACK_INTENT:ROLLING_BACK|ROLLED_BACK:ROLLING_BACK|NOT_MUTATED:ROLLING_BACK \
    |UNCERTAIN:PREPARING|UNCERTAIN:PREPARED|UNCERTAIN:APPLYING|UNCERTAIN:COMMITTING|UNCERTAIN:ROLLING_BACK) ;;
    *) config_error "Target checkpoint state $state is invalid while transaction is $CONFIG_TXN_JOURNAL_STATE"; return 1 ;;
  esac
  directory=$(config_transaction_target_directory "$home" "$transaction") || return 1
  path="$directory/$index.v2"
  if [[ -e $directory/$index.v1 || -L $directory/$index.v1 ]]; then
    config_error 'Cannot mix version 1 and version 2 records at one target index'
    return 1
  fi
  if [[ -e $path || -L $path ]]; then
    config_transaction_target_parse_file "$path" "$transaction" "$index" || return 1
    [[ $CONFIG_TXN_TARGET_OPERATION == restore && $CONFIG_TXN_TARGET_COMPONENT == "$component" \
      && $CONFIG_TXN_TARGET_PATH == "$target" && $CONFIG_TXN_TARGET_ORIGINAL == "$original" ]] \
      || { config_error 'Target checkpoint identity fields cannot be changed'; return 1; }
    prior_source=$CONFIG_TXN_TARGET_SOURCE_BACKUP
    prior_rollback=$CONFIG_TXN_TARGET_ROLLBACK_BACKUP
    prior_state=$CONFIG_TXN_TARGET_STATE
    [[ $prior_source == "$source_backup" ]] || { config_error 'Restore source-backup reference cannot be changed'; return 1; }
    if [[ $prior_rollback != "$rollback_backup" && $prior_rollback != - ]]; then
      config_error 'Rollback-backup reference cannot be changed after staging'
      return 1
    fi
    if [[ $prior_rollback == - && $rollback_backup != - && $prior_state != PLANNED ]]; then
      config_error 'Rollback-backup reference must be recorded while PLANNED'
      return 1
    fi
    if [[ $prior_state != "$state" ]] && ! config_transaction_target_transition_allowed "$prior_state" "$state"; then
      config_error "Invalid target checkpoint transition: $prior_state -> $state"
      return 1
    fi
  else
    [[ $state == PLANNED && $rollback_backup == - ]] || { config_error 'New version 2 checkpoints must begin PLANNED without a rollback backup'; return 1; }
  fi
  updated=$(date -u '+%Y-%m-%dT%H:%M:%SZ') || { config_error 'Cannot timestamp target checkpoint'; return 1; }
  temp=$(mktemp "$directory/.$index.v2.tmp.XXXXXXXX") || { config_error "Cannot create target checkpoint temporary file: $directory"; return 1; }
  if ! chmod 600 -- "$temp" \
    || ! config_transaction_target_serialize_v2 "$transaction" "$operation" "$component" "$index" "$target" "$original" "$source_backup" "$rollback_backup" "$state" "$updated" > "$temp" \
    || ! config_transaction_target_parse_file "$temp" "$transaction" "$index"; then
    rm -f -- "$temp"
    config_error "Could not validate target checkpoint temporary file: $temp"
    return 1
  fi
  if ! mv -fT -- "$temp" "$path"; then
    rm -f -- "$temp"
    config_error "Could not atomically replace target checkpoint: $path"
    return 1
  fi
  config_transaction_target_parse_file "$path" "$transaction" "$index"
}

config_state_target_valid() {
  local name=$1 relative=$2 registered
  registered=$(config_expected_target "$name") || return 1
  config_safe_relative_path "$relative" || return 1
  if [[ $registered == .zshrc ]]; then
    [[ $relative == .zshrc ]]
  else
    [[ $relative == "$registered/"* ]]
  fi
}

config_state_load() {
  local home=$1 state_dir registry="$1/.local/state/arclith/deployments.v1" line kind name target digest backup_id mode group extra
  local line_number=0 pipes i field_count first
  CONFIG_STATE_MANAGED_COMPONENTS=()
  CONFIG_STATE_MANAGED_TARGETS=()
  CONFIG_STATE_MANAGED_HASHES=()
  CONFIG_STATE_BACKUP_IDS=()
  CONFIG_STATE_BACKUP_COMPONENTS=()
  CONFIG_STATE_BACKUP_TARGETS=()
  CONFIG_STATE_BACKUP_HASHES=()
  CONFIG_STATE_BACKUP_MODES=()
  CONFIG_STATE_BACKUP_GROUPS=()
  state_dir=$(config_state_directory "$home")

  if config_path_has_symlink "$home" .local/state/arclith; then
    config_error "Deployment state path contains a symlink: $state_dir"
    return 1
  fi
  if config_path_has_non_directory_ancestor "$home" .local/state/arclith; then
    config_error "Deployment state path has a non-directory ancestor: $state_dir"
    return 1
  fi
  if [[ -e $state_dir ]] && { [[ ! -d $state_dir || -L $state_dir || $(stat -c '%u' -- "$state_dir") != "$EUID" ]]; }; then
    config_error "Unsafe deployment state directory: $state_dir"
    return 1
  fi
  if [[ -d $state_dir ]]; then
    mode=$(stat -c '%a' -- "$state_dir")
    [[ $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) || { config_error "Deployment state directory permissions must exclude group and other access: $state_dir"; return 1; }
  fi
  if [[ -L $registry ]]; then
    config_error "Unsafe deployment state manifest: $registry"
    return 1
  fi
  [[ -e $registry ]] || return 0
  if [[ ! -f $registry || ! -r $registry || $(stat -c '%u' -- "$registry") != "$EUID" ]]; then
    config_error "Unsafe deployment state manifest: $registry"
    return 1
  fi
  mode=$(stat -c '%a' -- "$registry")
  if [[ ! $mode =~ ^[0-7]{3,4}$ ]] || (( (8#$mode & 077) != 0 )); then
    config_error "Deployment state manifest permissions must exclude group and other access: $registry"
    return 1
  fi
  IFS= read -r first < "$registry" || { config_error "Empty deployment state manifest: $registry"; return 1; }
  [[ $first == 'ARCLITH_STATE|1' ]] || { config_error "Unsupported deployment state manifest version: $registry"; return 1; }
  line_number=1
  while IFS= read -r line || [[ -n $line ]]; do
    ((line_number += 1))
    [[ -n $line ]] || { config_error "$registry:$line_number: blank records are invalid"; return 1; }
    pipes=${line//[^|]/}
    IFS='|' read -r kind name target digest backup_id mode group extra <<< "$line"
    case $kind in
      M)
        (( ${#pipes} == 3 )) || { config_error "$registry:$line_number: malformed managed-file record"; return 1; }
        [[ -z $extra && $name =~ ^[a-z][a-z0-9_-]*$ ]] && config_component_exists "$name" \
          && config_state_target_valid "$name" "$target" && [[ $digest =~ ^[a-f0-9]{64}$ ]] \
          || { config_error "$registry:$line_number: invalid managed-file record"; return 1; }
        for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
          [[ ${CONFIG_STATE_MANAGED_TARGETS[i]} != "$target" ]] || { config_error "$registry:$line_number: duplicate managed target"; return 1; }
        done
        CONFIG_STATE_MANAGED_COMPONENTS+=("$name")
        CONFIG_STATE_MANAGED_TARGETS+=("$target")
        CONFIG_STATE_MANAGED_HASHES+=("$digest")
        ;;
      B)
        IFS='|' read -r kind backup_id name target digest mode group extra <<< "$line"
        (( ${#pipes} == 6 )) || { config_error "$registry:$line_number: malformed backup record"; return 1; }
        [[ -z $extra && $backup_id =~ ^[A-Za-z0-9]{8}$ && $name =~ ^[a-z][a-z0-9_-]*$ ]] \
          && config_component_exists "$name" && config_state_target_valid "$name" "$target" \
          && [[ $digest =~ ^[a-f0-9]{64}$ && $mode =~ ^[0-7]{3,4}$ && $group =~ ^[0-9]+$ ]] \
          || { config_error "$registry:$line_number: invalid backup record"; return 1; }
        for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
          [[ ${CONFIG_STATE_BACKUP_IDS[i]} != "$backup_id" ]] || { config_error "$registry:$line_number: duplicate backup identifier"; return 1; }
        done
        CONFIG_STATE_BACKUP_IDS+=("$backup_id")
        CONFIG_STATE_BACKUP_COMPONENTS+=("$name")
        CONFIG_STATE_BACKUP_TARGETS+=("$target")
        CONFIG_STATE_BACKUP_HASHES+=("$digest")
        CONFIG_STATE_BACKUP_MODES+=("$mode")
        CONFIG_STATE_BACKUP_GROUPS+=("$group")
        ;;
      *) config_error "$registry:$line_number: unknown record type"; return 1 ;;
    esac
  done < <(tail -n +2 "$registry")
}

config_file_hash() {
  local digest
  IFS=' ' read -r digest _ < <(sha256sum -- "$1") || return 1
  printf '%s' "$digest"
}

config_rollback_target_matches() {
  local path=$1 expected_id=$2 expected_hash=$3 current_id current_hash
  [[ -n $expected_id && -n $expected_hash && -f $path && ! -L $path ]] || return 1
  current_id=$(stat -c '%d:%i' -- "$path" 2>/dev/null) || return 1
  [[ $current_id == "$expected_id" ]] || return 1
  current_hash=$(config_file_hash "$path" 2>/dev/null) || return 1
  [[ $current_hash == "$expected_hash" ]]
}

config_state_set_managed() {
  local name=$1 target=$2 digest=$3 i
  [[ $digest =~ ^[a-f0-9]{64}$ ]] || { config_error "Refusing invalid managed-file digest for: $target"; return 1; }
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    if [[ ${CONFIG_STATE_MANAGED_TARGETS[i]} == "$target" ]]; then
      CONFIG_STATE_MANAGED_COMPONENTS[i]=$name
      CONFIG_STATE_MANAGED_HASHES[i]=$digest
      return 0
    fi
  done
  CONFIG_STATE_MANAGED_COMPONENTS+=("$name")
  CONFIG_STATE_MANAGED_TARGETS+=("$target")
  CONFIG_STATE_MANAGED_HASHES+=("$digest")
}

config_state_remove_managed_target() {
  local target=$1 i
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    if [[ ${CONFIG_STATE_MANAGED_TARGETS[i]} == "$target" ]]; then
      unset 'CONFIG_STATE_MANAGED_COMPONENTS[i]' 'CONFIG_STATE_MANAGED_TARGETS[i]' 'CONFIG_STATE_MANAGED_HASHES[i]'
    fi
  done
  CONFIG_STATE_MANAGED_COMPONENTS=("${CONFIG_STATE_MANAGED_COMPONENTS[@]}")
  CONFIG_STATE_MANAGED_TARGETS=("${CONFIG_STATE_MANAGED_TARGETS[@]}")
  CONFIG_STATE_MANAGED_HASHES=("${CONFIG_STATE_MANAGED_HASHES[@]}")
}

config_state_add_backup() {
  [[ $4 =~ ^[a-f0-9]{64}$ ]] || { config_error "Refusing invalid backup digest for: $3"; return 1; }
  CONFIG_STATE_BACKUP_IDS+=("$1")
  CONFIG_STATE_BACKUP_COMPONENTS+=("$2")
  CONFIG_STATE_BACKUP_TARGETS+=("$3")
  CONFIG_STATE_BACKUP_HASHES+=("$4")
  CONFIG_STATE_BACKUP_MODES+=("$5")
  CONFIG_STATE_BACKUP_GROUPS+=("$6")
}

config_state_save() {
  local home=$1 state_dir registry line existing_mode temp old new_hash
  state_dir=$(config_state_directory "$home")
  registry="$state_dir/deployments.v1"
  if [[ -L $registry ]] || config_path_has_symlink "$home" .local/state/arclith; then
    config_error "Refusing symlinked deployment state path: $registry"
    return 1
  fi
  mkdir -p -m 700 -- "$state_dir" || { config_error "Cannot create deployment state directory: $state_dir"; return 1; }
  chmod 700 -- "$state_dir" || return 1
  if [[ -e $registry ]]; then
    [[ -f $registry && $(stat -c '%u' -- "$registry") == "$EUID" ]] || { config_error "Unsafe deployment state manifest: $registry"; return 1; }
    existing_mode=$(stat -c '%a' -- "$registry")
    [[ $existing_mode =~ ^[0-7]{3,4}$ ]] && (( (8#$existing_mode & 077) == 0 )) || { config_error "Unsafe deployment state manifest permissions: $registry"; return 1; }
  fi
  for line in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    [[ ${CONFIG_STATE_MANAGED_HASHES[line]:-} =~ ^[a-f0-9]{64}$ ]] || { config_error 'Refusing to save invalid managed-file digest'; return 1; }
  done
  for line in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
    [[ ${CONFIG_STATE_BACKUP_HASHES[line]:-} =~ ^[a-f0-9]{64}$ ]] || { config_error 'Refusing to save invalid backup digest'; return 1; }
  done
  temp=$(mktemp "$state_dir/.deployments.XXXXXXXX") || return 1
  chmod 600 -- "$temp" || { rm -f -- "$temp"; return 1; }
  {
    printf 'ARCLITH_STATE|1\n'
    for line in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
      printf 'M|%s|%s|%s\n' "${CONFIG_STATE_MANAGED_COMPONENTS[line]}" "${CONFIG_STATE_MANAGED_TARGETS[line]}" "${CONFIG_STATE_MANAGED_HASHES[line]}"
    done
    for line in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
      printf 'B|%s|%s|%s|%s|%s|%s\n' "${CONFIG_STATE_BACKUP_IDS[line]}" "${CONFIG_STATE_BACKUP_COMPONENTS[line]}" "${CONFIG_STATE_BACKUP_TARGETS[line]}" "${CONFIG_STATE_BACKUP_HASHES[line]}" "${CONFIG_STATE_BACKUP_MODES[line]}" "${CONFIG_STATE_BACKUP_GROUPS[line]}"
    done
  } > "$temp" || { rm -f -- "$temp"; return 1; }
  if [[ -e $registry ]]; then
    old=$(mktemp "$state_dir/.deployments-old.XXXXXXXX") || { rm -f -- "$temp"; return 1; }
    cp -- "$registry" "$old" && chmod 600 -- "$old" || { rm -f -- "$temp" "$old"; return 1; }
    new_hash=$(config_file_hash "$temp") || { rm -f -- "$temp" "$old"; return 1; }
    if mv -T -- "$temp" "$registry"; then
      rm -f -- "$old"
    else
      if mv -T -- "$old" "$registry"; then
        rm -f -- "$temp"
        return 1
      elif [[ -f $registry && $(config_file_hash "$registry") == "$new_hash" ]]; then
        config_error "State replacement completed; retaining the matching manifest after rollback rename failed"
        rm -f -- "$old" "$temp"
        return 0
      else
        config_error "State rollback failed; previous manifest is at $old"
      fi
      rm -f -- "$temp"
      return 1
    fi
  else
    new_hash=$(config_file_hash "$temp") || { rm -f -- "$temp"; return 1; }
    if mv -T -- "$temp" "$registry"; then
      :
    elif [[ ! -e $temp && -f $registry ]] && [[ $(config_file_hash "$registry") == "$new_hash" ]]; then
      return 0
    else
      rm -f -- "$temp"
      return 1
    fi
  fi
}

config_state_backup_path() {
  printf '%s/%s.arclith-backup.%s' "$1" "$2" "$3"
}

config_state_backup_status() {
  local home=$1 index=$2 path expected_hash mode relative
  relative="${CONFIG_STATE_BACKUP_TARGETS[index]}.arclith-backup.${CONFIG_STATE_BACKUP_IDS[index]}"
  path=$(config_state_backup_path "$home" "${CONFIG_STATE_BACKUP_TARGETS[index]}" "${CONFIG_STATE_BACKUP_IDS[index]}")
  if config_path_has_symlink "$home" "$relative" || [[ -L $path ]]; then
    printf 'unsafe'
  elif [[ ! -f $path || $(stat -c '%u' -- "$path" 2>/dev/null || true) != "$EUID" ]]; then
    printf 'missing-or-unsafe'
  else
    mode=$(stat -c '%a' -- "$path")
    expected_hash=$(config_file_hash "$path")
    if [[ $expected_hash == "${CONFIG_STATE_BACKUP_HASHES[index]}" && $mode == 600 ]]; then
      printf 'available'
    else
      printf 'invalid'
    fi
  fi
}

config_backup_list() {
  local root=$1 home=$2 filter=${3:-} i status shown=0
  config_load_registry "$root" || return 1
  [[ -z $filter ]] || config_component_exists "$filter" || { config_error "Unknown configuration component: $filter"; return 2; }
  config_state_load "$home" || return 1
  printf 'Arclith configuration backups (state validated):\n'
  for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
    [[ -z $filter || ${CONFIG_STATE_BACKUP_COMPONENTS[i]} == "$filter" ]] || continue
    status=$(config_state_backup_status "$home" "$i")
    printf '%s  %s  %s  %s\n' "${CONFIG_STATE_BACKUP_IDS[i]}" "${CONFIG_STATE_BACKUP_COMPONENTS[i]}" "${CONFIG_STATE_BACKUP_TARGETS[i]}" "$status"
    ((shown += 1))
  done
  (( shown > 0 )) || printf 'No tracked backups.\n'
}

config_artifacts() {
  local LC_ALL=C
  local root=$1 home=$2 filter=${3:-} i name relative source_dir source_status source_path source_relative
  local target_path parent inspection backup_path backup_status digest candidate suffix kind token j ordered_target
  local state_manifest_inspection
  local shown=0 incomplete=0 tracked
  local -a ordered_targets=()
  local -A targets=()
  config_load_registry "$root" || return 1
  [[ -z $filter ]] || config_component_exists "$filter" || { config_error "Unknown configuration component: $filter"; return 2; }
  state_manifest_inspection=$(config_target_inspection_status "$home" .local/state/arclith/deployments.v1)
  case $state_manifest_inspection in
    inaccessible) config_error 'Cannot inspect deployment state; artifact inventory is incomplete'; return 1 ;;
    unsafe) config_error 'Deployment state path is unsafe; artifact inventory is incomplete'; return 1 ;;
  esac
  config_state_load "$home" || return 1
  printf 'Arclith recovery artifact inventory (read-only):\n'
  printf 'Scope: recorded targets and targets from currently available bundled sources, plus deployment-state temporary names. Historical targets without records or bundled sources may be outside this inventory.\n'
  printf 'Transaction status is unavailable: this version has no operation journal or live-operation marker. Untracked candidates may be active or needed for recovery; no removal or recovery decision was made.\n'

  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    name=${CONFIG_STATE_MANAGED_COMPONENTS[i]}
    [[ -z $filter || $name == "$filter" ]] || continue
    targets["${CONFIG_STATE_MANAGED_TARGETS[i]}"]=$name
  done
  for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
    name=${CONFIG_STATE_BACKUP_COMPONENTS[i]}
    [[ -z $filter || $name == "$filter" ]] || continue
    relative=${CONFIG_STATE_BACKUP_TARGETS[i]}
    targets["$relative"]=$name
    backup_path="${relative}.arclith-backup.${CONFIG_STATE_BACKUP_IDS[i]}"
    inspection=$(config_target_inspection_status "$home" "$backup_path")
    case $inspection in
      missing) backup_status=missing ;;
      inaccessible) backup_status=inaccessible ;;
      unsafe) backup_status=unsafe ;;
      accessible)
        if [[ $(stat -c '%u' -- "$home/$backup_path" 2>/dev/null || true) != "$EUID" ]]; then
          backup_status=unsafe
        elif [[ $(stat -c '%a' -- "$home/$backup_path" 2>/dev/null || true) != 600 ]]; then
          backup_status=invalid
        else
          digest=$(config_file_hash "$home/$backup_path" 2>/dev/null || true)
          if [[ -z $digest ]]; then backup_status=inaccessible
          elif [[ $digest == "${CONFIG_STATE_BACKUP_HASHES[i]}" ]]; then backup_status=valid
          else backup_status=invalid
          fi
        fi
        ;;
      *) config_error "Unexpected backup inspection status for $backup_path: $inspection"; return 1 ;;
    esac
    printf 'TRACKED %s BACKUP  %s  %s  %s  %q\n' "$backup_status" "${CONFIG_STATE_BACKUP_IDS[i]}" "$name" "$relative" "$home/$backup_path"
    ((shown += 1))
  done

  for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
    [[ -z $filter || $name == "$filter" ]] || continue
    source_status=$(config_source_status "$root" "$name")
    [[ $source_status == available ]] || continue
    source_dir="$root/${CONFIG_SOURCES[$name]}"
    while IFS= read -r -d '' source_path; do
      source_relative=${source_path#"$source_dir"/}
      if [[ ${CONFIG_TARGETS[$name]} == .zshrc ]]; then relative=.zshrc
      else relative="${CONFIG_TARGETS[$name]}/$source_relative"
      fi
      config_safe_relative_path "$relative" || continue
      targets["$relative"]=$name
    done < <(find "$source_dir" -type f -print0)
  done

  ordered_targets=("${!targets[@]}")
  for ((i = 1; i < ${#ordered_targets[@]}; i++)); do
    ordered_target=${ordered_targets[i]}
    j=$((i - 1))
    while (( j >= 0 )) && [[ ${ordered_targets[j]} > $ordered_target ]]; do
      ordered_targets[j + 1]=${ordered_targets[j]}
      j=$((j - 1))
    done
    ordered_targets[j + 1]=$ordered_target
  done
  for relative in "${ordered_targets[@]}"; do
    name=${targets[$relative]}
    target_path="$home/$relative"
    parent=${relative%/*}
    [[ $parent == "$relative" ]] && parent=
    if [[ -n $parent ]]; then
      if config_path_has_symlink "$home" "$parent" || config_path_has_non_directory_ancestor "$home" "$parent"; then
        printf 'SCAN INCOMPLETE unsafe target directory  %q\n' "$home/$parent"
        incomplete=1
        continue
      fi
      parent="$home/$parent"
      [[ -e $parent ]] || continue
    else
      parent=$home
    fi
    if [[ ! -d $parent ]]; then
      printf 'SCAN INCOMPLETE unsafe target directory  %q\n' "$parent"
      incomplete=1
      continue
    elif [[ ! -r $parent || ! -x $parent ]]; then
      printf 'SCAN INCOMPLETE inaccessible target directory  %q\n' "$parent"
      incomplete=1
      continue
    fi
    for candidate in "$target_path".arclith-*; do
      [[ -L $candidate || -e $candidate ]] || continue
      suffix=${candidate#"$target_path".arclith-}
      kind=${suffix%%.*}
      token=${suffix#*.}
      case $kind in
        backup|new|restore|rollback) ;;
        *) continue ;;
      esac
      tracked=0
      if [[ $kind == backup && $token =~ ^[A-Za-z0-9]{8}$ ]]; then
        for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
          if [[ ${CONFIG_STATE_BACKUP_COMPONENTS[i]} == "$name" \
            && ${CONFIG_STATE_BACKUP_TARGETS[i]} == "$relative" \
            && ${CONFIG_STATE_BACKUP_IDS[i]} == "$token" ]]; then tracked=1; break; fi
        done
      fi
      (( tracked )) && continue
      if [[ -L $candidate ]]; then
        printf 'UNTRACKED UNSAFE SYMLINK CANDIDATE  %s  %q (not followed)\n' "$kind" "$candidate"
      elif [[ ! -f $candidate ]]; then
        printf 'UNTRACKED UNSAFE PATH CANDIDATE  %s  %q (not opened)\n' "$kind" "$candidate"
      elif [[ ! -r $candidate ]]; then
        printf 'UNTRACKED INACCESSIBLE CANDIDATE  %s  %q (not opened)\n' "$kind" "$candidate"
        incomplete=1
      elif [[ $token =~ ^[A-Za-z0-9]{8}$ ]]; then
        printf 'UNTRACKED UNCERTAIN CANDIDATE  %s  %q (operation and recovery purpose unknown)\n' "$kind" "$candidate"
      else
        printf 'UNTRACKED MALFORMED-NAME CANDIDATE  %s  %q (not interpreted)\n' "$kind" "$candidate"
      fi
      ((shown += 1))
    done
  done

  local state_dir="$home/.local/state/arclith"
  if [[ -e $state_dir ]]; then
    if [[ -L $state_dir || ! -d $state_dir ]]; then
      printf 'SCAN INCOMPLETE unsafe deployment-state directory  %q\n' "$state_dir"
      incomplete=1
    elif [[ ! -r $state_dir || ! -x $state_dir ]]; then
      printf 'SCAN INCOMPLETE inaccessible deployment-state directory  %q\n' "$state_dir"
      incomplete=1
    else
      for candidate in "$state_dir"/.deployments.* "$state_dir"/.deployments-old.*; do
        [[ -L $candidate || -e $candidate ]] || continue
        suffix=${candidate##*.deployments}
        suffix=${suffix#-old}
        suffix=${suffix#.}
        if [[ ! $suffix =~ ^[A-Za-z0-9]{8}$ ]]; then
          printf 'UNTRACKED MALFORMED-NAME STATE CANDIDATE  %q (not opened)\n' "$candidate"
          ((shown += 1))
          continue
        fi
        if [[ -L $candidate ]]; then
          printf 'UNTRACKED UNSAFE STATE SYMLINK  %q (not followed)\n' "$candidate"
        elif [[ ! -f $candidate ]]; then
          printf 'UNTRACKED UNSAFE STATE PATH  %q (not opened)\n' "$candidate"
        elif [[ ! -r $candidate ]]; then
          printf 'UNTRACKED INACCESSIBLE STATE CANDIDATE  %q (not opened)\n' "$candidate"
          incomplete=1
        else
          printf 'UNTRACKED UNCERTAIN STATE CANDIDATE  %q (may contain recovery state; not opened)\n' "$candidate"
        fi
        ((shown += 1))
      done
    fi
  fi
  (( shown > 0 )) || printf 'No matching artifacts found in the bounded inventory scope.\n'
  (( incomplete == 0 ))
}

config_state_status() {
  local root=$1 home=$2 filter=${3:-} i path status digest shown=0 relative inspection
  config_load_registry "$root" || return 1
  [[ -z $filter ]] || config_component_exists "$filter" || { config_error "Unknown configuration component: $filter"; return 2; }
  config_state_load "$home" || return 1
  printf 'Arclith deployment state (manifest validated):\n'
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    [[ -z $filter || ${CONFIG_STATE_MANAGED_COMPONENTS[i]} == "$filter" ]] || continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[i]}
    path="$home/$relative"
    inspection=$(config_target_inspection_status "$home" "$relative")
    case $inspection in
      missing) status=missing ;;
      inaccessible) status=inaccessible ;;
      unsafe) status=unsafe ;;
      accessible)
        digest=$(config_file_hash "$path") || { config_error "Cannot inspect managed target: $relative"; return 1; }
        if [[ $digest == "${CONFIG_STATE_MANAGED_HASHES[i]}" ]]; then status=unchanged; else status=modified; fi
        ;;
      *) config_error "Unexpected target inspection status for $relative: $inspection"; return 1 ;;
    esac
    printf '%s  %s  %s\n' "${CONFIG_STATE_MANAGED_COMPONENTS[i]}" "${CONFIG_STATE_MANAGED_TARGETS[i]}" "$status"
    ((shown += 1))
  done
  (( shown > 0 )) || printf 'No managed configuration files.\n'
}

config_updates() {
  local root=$1 home=$2 filter=${3:-} i name relative path source_relative source_path source_dir target_rel target_path
  local target_hash source_hash failed=0 shown=0 source_status inspection
  local -a source_files=()
  local -A managed_targets=()
  config_load_registry "$root" || return 1
  [[ -z $filter ]] || config_component_exists "$filter" || { config_error "Unknown configuration component: $filter"; return 2; }
  config_state_load "$home" || return 1
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    managed_targets["${CONFIG_STATE_MANAGED_TARGETS[i]}"]=1
  done
  printf 'Arclith configuration update check (read-only):\n'
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    name=${CONFIG_STATE_MANAGED_COMPONENTS[i]}
    [[ -z $filter || $name == "$filter" ]] || continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[i]}
    path="$home/$relative"
    source_status=$(config_source_status "$root" "$name")

    inspection=$(config_target_inspection_status "$home" "$relative")
    if [[ $inspection == unsafe ]]; then
      printf 'FAIL UNSAFE TARGET  %s  %s\n' "$name" "$relative"
      failed=1
      ((shown += 1))
      continue
    fi
    if [[ $inspection == inaccessible ]]; then
      printf 'FAIL INACCESSIBLE TARGET  %s  %s (target cannot be inspected; no decision was made)\n' "$name" "$relative"
      failed=1
      ((shown += 1))
      continue
    fi
    if [[ $inspection == missing ]]; then
      printf 'WARN MISSING TARGET  %s  %s (run config apply %s after reviewing the source)\n' "$name" "$relative" "$name"
      ((shown += 1))
      continue
    fi
    target_hash=$(config_file_hash "$path") || { config_error "Cannot hash managed target: $relative"; return 1; }
    if [[ $target_hash != "${CONFIG_STATE_MANAGED_HASHES[i]}" ]]; then
      printf 'WARN LOCAL MODIFICATION  %s  %s (preserved; review before applying)\n' "$name" "$relative"
      ((shown += 1))
      continue
    fi
    case $source_status in
      unavailable|empty-source)
        printf 'WARN SOURCE UNAVAILABLE  %s  %s (%s)\n' "$name" "$relative" "${CONFIG_SOURCES[$name]}"
        ;;
      unsafe-symlink|unsafe-entry|unreadable)
        printf 'FAIL SOURCE INVALID  %s  %s (%s)\n' "$name" "$relative" "$source_status"
        failed=1
        ;;
      available)
        if [[ ${CONFIG_TARGETS[$name]} == .zshrc ]]; then
          source_relative=.zshrc
        else
          source_relative=${relative#"${CONFIG_TARGETS[$name]}/"}
        fi
        source_path="$root/${CONFIG_SOURCES[$name]}/$source_relative"
        if [[ ! -f $source_path || -L $source_path ]]; then
          printf 'WARN SOURCE REMOVED  %s  %s (source file is no longer bundled)\n' "$name" "$relative"
        elif [[ ! -r $source_path || ! -s $source_path ]] || ! LC_ALL=C grep -Iq . -- "$source_path"; then
          printf 'FAIL SOURCE INVALID  %s  %s (source must be readable non-empty text)\n' "$name" "$relative"
          failed=1
        else
          source_hash=$(config_file_hash "$source_path") || { config_error "Cannot hash bundled source: $source_path"; return 1; }
          if [[ $source_hash == "${CONFIG_STATE_MANAGED_HASHES[i]}" ]]; then
            printf 'CURRENT  %s  %s\n' "$name" "$relative"
          else
            printf 'UPDATE AVAILABLE  %s  %s (review, then run config apply %s)\n' "$name" "$relative" "$name"
          fi
        fi
        ;;
    esac
    ((shown += 1))
  done

  # Also discover bundled files that have no deployment record yet. These can
  # be proposed as new files, but existing unmanaged targets are only warnings.
  for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
    [[ -z $filter || $name == "$filter" ]] || continue
    source_dir="$root/${CONFIG_SOURCES[$name]}"
    source_status=$(config_source_status "$root" "$name")
    case $source_status in
      unavailable|empty-source) continue ;;
      unsafe-symlink|unsafe-entry|unreadable)
        printf 'FAIL SOURCE INVALID  %s  %s\n' "$name" "$source_status"
        failed=1
        ((shown += 1))
        continue
        ;;
      available) ;;
      *)
        config_error "Unexpected source status for $name: $source_status"
        return 1
        ;;
    esac
    source_files=()
    while IFS= read -r -d '' source_path; do source_files+=("$source_path"); done \
      < <(find "$source_dir" -type f -print0)
    if [[ $name == zsh && ( ${#source_files[@]} != 1 || ${source_files[0]#"$source_dir"/} != .zshrc ) ]]; then
      printf 'FAIL SOURCE INVALID  %s  (Zsh source must contain exactly one .zshrc file)\n' "$name"
      failed=1
      ((shown += 1))
      continue
    fi
    for source_path in "${source_files[@]}"; do
      source_relative=${source_path#"$source_dir"/}
      if ! config_safe_relative_path "$source_relative" \
        || [[ ! -r $source_path || ! -s $source_path ]] \
        || ! LC_ALL=C grep -Iq . -- "$source_path"; then
        printf 'FAIL SOURCE INVALID  %s  %s (source must be a safe, readable, non-empty text file)\n' "$name" "$source_relative"
        failed=1
        ((shown += 1))
        continue
      fi
      target_rel="${CONFIG_TARGETS[$name]}/$source_relative"
      [[ ${CONFIG_TARGETS[$name]} == .zshrc ]] && target_rel=.zshrc
      [[ -z ${managed_targets[$target_rel]+present} ]] || continue
      target_path="$home/$target_rel"
      relative=${target_rel%/*}
      [[ $relative == "$target_rel" ]] && relative=
      inspection=$(config_target_inspection_status "$home" "$target_rel")
      if [[ $inspection == unsafe ]]; then
        printf 'FAIL UNSAFE TARGET  %s  %s\n' "$name" "$target_rel"
        failed=1
      elif [[ $inspection == inaccessible ]]; then
        printf 'FAIL INACCESSIBLE TARGET  %s  %s (target cannot be inspected; no decision was made)\n' "$name" "$target_rel"
        failed=1
      elif [[ -e $target_path ]]; then
        printf 'WARN UNMANAGED CONFLICT  %s  %s (existing file preserved; review before applying)\n' "$name" "$target_rel"
      else
        printf 'NEW FILE AVAILABLE  %s  %s (review, then run config apply %s)\n' "$name" "$target_rel" "$name"
      fi
      ((shown += 1))
    done
  done
  (( shown > 0 )) || printf 'No managed or available configuration files to check.\n'
  (( failed == 0 ))
}

config_uninstall_component_unlocked() {
  local root=$1 home=$2 name=$3 action=$4 selection=${5:-all} i index relative target digest status reply attempt existing_id collision missing=0 inspection
  local source_status source_dir source_path source_relative target_rel
  local backup backup_id backup_hash original_mode original_group staged failed=0 conflicts=0 changed=0
  local transaction_id transaction_operation checkpoint_index checkpoint_state journal_failed=0 rollback_failed=0 manifest_touched=0 remove_status
  local -a candidates=() source_files=() indexes=() statuses=() backup_paths=() backup_ids=() backup_hashes=() modes=() groups=() removed=() remove_targets=()
  local -a checkpointed=()
  local -A bundled_targets=()
  local -a old_components=() old_targets=() old_hashes=()
  config_load_registry "$root" || return 1
  if ! config_component_exists "$name"; then config_error "Unknown configuration component: $name"; return 2; fi
  if [[ ! $home == /* || -L $home || ! -d $home ]]; then config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; fi
  home=$(cd -- "$home" && pwd -P)
  if [[ $selection != stale-only && ! -f $home/.local/state/arclith/deployments.v1 ]]; then
    config_error "Cannot uninstall '$name': no trusted deployment state exists; no files are authorized for removal"
    return 1
  fi
  config_state_load "$home" || return 1
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    [[ ${CONFIG_STATE_MANAGED_COMPONENTS[i]} == "$name" ]] || continue
    candidates+=("$i")
  done
  if (( ${#candidates[@]} == 0 )); then
    if [[ $selection == stale-only ]]; then
      printf 'No stale managed files to prune for %s.\n' "$name"
      return 0
    fi
    config_error "Cannot uninstall '$name': no managed-file ownership records authorize removal"
    return 1
  fi

  if [[ $selection == stale-only ]]; then
    source_status=$(config_source_status "$root" "$name")
    if [[ $source_status != available ]]; then
      config_error "Cannot prune '$name': bundled source status is $source_status; no files were changed"
      return 1
    fi
    source_dir="$root/${CONFIG_SOURCES[$name]}"
    while IFS= read -r -d '' source_path; do source_files+=("$source_path"); done \
      < <(find "$source_dir" -type f -print0)
    if [[ $name == zsh && ( ${#source_files[@]} != 1 || ${source_files[0]#"$source_dir"/} != .zshrc ) ]]; then
      config_error "Cannot prune '$name': bundled Zsh source is invalid; no files were changed"
      return 1
    fi
    for source_path in "${source_files[@]}"; do
      source_relative=${source_path#"$source_dir"/}
      if ! config_safe_relative_path "$source_relative" \
        || [[ ! -r $source_path || ! -s $source_path ]] \
        || ! LC_ALL=C grep -Iq . -- "$source_path"; then
        config_error "Cannot prune '$name': invalid bundled source file '$source_relative'; no files were changed"
        return 1
      fi
      target_rel="${CONFIG_TARGETS[$name]}/$source_relative"
      [[ ${CONFIG_TARGETS[$name]} == .zshrc ]] && target_rel=.zshrc
      bundled_targets["$target_rel"]=1
    done
    for i in "${candidates[@]}"; do
      relative=${CONFIG_STATE_MANAGED_TARGETS[i]}
      [[ -n ${bundled_targets[$relative]+present} ]] || indexes+=("$i")
    done
    if (( ${#indexes[@]} == 0 )); then
      printf 'No stale managed files to prune for %s.\n' "$name"
      return 0
    fi
  else
    indexes=("${candidates[@]}")
  fi

  if [[ $selection == stale-only ]]; then printf 'Configuration stale-file prune preview: %s\n' "$name"
  else printf 'Configuration uninstall preview: %s\n' "$name"; fi
  for i in "${indexes[@]}"; do
    relative=${CONFIG_STATE_MANAGED_TARGETS[i]}
    if ! config_state_target_valid "$name" "$relative"; then
      config_error "Unsafe managed target in state: $relative"; return 1
    fi
    target="$home/$relative"
    inspection=$(config_target_inspection_status "$home" "$relative")
    if [[ $inspection == inaccessible ]]; then
      status=inaccessible
      conflicts=1
      printf '  REFUSE           %s (target cannot be inspected; preserved)\n' "$relative"
    elif [[ $inspection == unsafe ]]; then
      config_error "Unsafe managed target path; refusing uninstall: $relative"; return 1
    elif [[ $inspection == missing ]]; then
      status=missing
      ((missing += 1))
      printf '  ALREADY MISSING  %s (ownership record will be cleared)\n' "$relative"
    elif [[ $(stat -c '%u' -- "$target" 2>/dev/null || true) != "$EUID" ]]; then
      status=unsafe
      printf '  REFUSE           %s (not a current-user regular file; preserved)\n' "$relative"
      conflicts=1
    else
      digest=$(config_file_hash "$target") || { config_error "Cannot hash managed target: $relative"; return 1; }
      if [[ $digest == "${CONFIG_STATE_MANAGED_HASHES[i]}" ]]; then
        status=unchanged
        printf '  REMOVE           %s (verified deployed hash)\n' "$relative"
        ((changed += 1))
      else
        status=modified
        printf '  PRESERVE         %s (content differs from deployed hash)\n' "$relative"
        conflicts=1
      fi
    fi
    statuses+=("$status")
  done
  if [[ $action == preview ]]; then
    printf 'Dry run complete; no files or state were changed.\n'
    (( conflicts == 0 ))
    return
  fi
  if (( changed == 0 && missing == 0 )); then
    config_error "No unchanged managed files are safe to remove for '$name'"
    return 1
  fi
  if [[ $action != yes ]]; then
    printf "Remove only the verified unchanged files listed above? [y/N]: " >&2
    if ! IFS= read -r reply || [[ ! $reply =~ ^([yY]|[yY][eE][sS])$ ]]; then
      printf 'Skipped: no files were changed.\n'
      return 1
    fi
  fi

  if [[ $selection == stale-only ]]; then transaction_operation=prune; else transaction_operation=uninstall; fi
  if ! config_transaction_journal_create "$home" "$transaction_operation" "$name"; then
    if [[ ${CONFIG_TXN_JOURNAL_ID:-} =~ ^[a-f0-9]{32}$ ]]; then
      config_transaction_journal_transition "$home" "$CONFIG_TXN_JOURNAL_ID" UNCERTAIN || true
    fi
    config_error "Could not create $transaction_operation transaction journal; no targets were changed"
    return 1
  fi
  transaction_id=$CONFIG_TXN_JOURNAL_ID
  for i in "${!indexes[@]}"; do
    checkpointed[i]=no
    [[ ${statuses[i]} == inaccessible ]] && continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
    original=yes
    [[ ${statuses[i]} != missing ]] || original=no
    printf -v checkpoint_index '%06d' "$i"
    if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
      "$name" "$relative" "$original" - PLANNED; then
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
      config_error 'Could not record selected target plan; no targets were changed'
      return 1
    fi
    checkpointed[i]=yes
  done
  old_components=("${CONFIG_STATE_MANAGED_COMPONENTS[@]}")
  old_targets=("${CONFIG_STATE_MANAGED_TARGETS[@]}")
  old_hashes=("${CONFIG_STATE_MANAGED_HASHES[@]}")

  # Make and register recovery copies before deleting any target.
  for i in "${!indexes[@]}"; do
    backup_paths[i]=; backup_ids[i]=; backup_hashes[i]=; modes[i]=; groups[i]=
    [[ ${statuses[i]} == unchanged ]] || continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
    target="$home/$relative"
    backup=
    for attempt in 1 2 3 4 5; do
      backup=$(mktemp "${target}.arclith-backup.XXXXXXXX") || break
      backup_id=${backup##*.arclith-backup.}
      collision=0
      for existing_id in "${CONFIG_STATE_BACKUP_IDS[@]}"; do [[ $existing_id != "$backup_id" ]] || collision=1; done
      for existing_id in "${backup_ids[@]}"; do [[ -z $existing_id || $existing_id != "$backup_id" ]] || collision=1; done
      (( collision == 0 )) && break
      rm -f -- "$backup"; backup=
    done
    if [[ -z $backup ]]; then config_error "Could not allocate recovery backup for: $relative"; failed=1; break; fi
    original_mode=$(stat -c '%a' -- "$target")
    original_group=$(stat -c '%g' -- "$target")
    if ! cp -p -- "$target" "$backup" || ! chmod 600 -- "$backup"; then
      rm -f -- "$backup"; config_error "Could not preserve managed file before removal: $relative"; failed=1; break
    fi
    backup_hash=$(config_file_hash "$backup") || { rm -f -- "$backup"; failed=1; break; }
    if [[ $backup_hash != "${CONFIG_STATE_MANAGED_HASHES[${indexes[i]}]}" ]]; then
      rm -f -- "$backup"; config_error "Managed file changed while creating its recovery copy: $relative"; failed=1; break
    fi
    backup_paths[i]=$backup; backup_ids[i]=$backup_id; backup_hashes[i]=$backup_hash; modes[i]=$original_mode; groups[i]=$original_group
    printf -v checkpoint_index '%06d' "$i"
    if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
      "$name" "$relative" yes "$backup_id" PLANNED \
      || ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
      "$name" "$relative" yes "$backup_id" STAGED; then
      config_error "Could not persist recovery-copy checkpoint for: $relative"
      failed=1
      journal_failed=1
      break
    fi
  done
  if (( ! failed )) && { ! config_transaction_journal_transition "$home" "$transaction_id" PREPARED \
    || ! config_transaction_journal_transition "$home" "$transaction_id" APPLYING; }; then
    config_error 'Could not persist the pre-mutation transaction state; no targets were deleted'
    failed=1
    journal_failed=1
  fi
  if (( ! failed )); then
    for i in "${!indexes[@]}"; do
      [[ ${checkpointed[i]:-no} == yes ]] || continue
      relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
      printf -v checkpoint_index '%06d' "$i"
      case ${statuses[i]} in
        missing) ;;
        modified|unsafe)
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
            "$name" "$relative" yes - NOT_MUTATED || { failed=1; journal_failed=1; break; }
          ;;
      esac
    done
  fi
  for i in "${!indexes[@]}"; do
    (( failed == 0 )) || break
    [[ -n ${backup_ids[i]} ]] || continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
    config_state_add_backup "${backup_ids[i]}" "$name" "$relative" "${backup_hashes[i]}" "${modes[i]}" "${groups[i]}"
  done
  if (( ! failed && changed > 0 )); then
    manifest_touched=1
    if ! config_state_save "$home"; then
      config_error 'Could not register recovery backups; no managed files were removed'
      failed=1
    fi
  fi

  for i in "${!indexes[@]}"; do
    (( failed == 0 )) || break
    [[ ${statuses[i]} == unchanged ]] || continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
    target="$home/$relative"
    if config_path_has_symlink "$home" "$relative" || [[ ! -f $target ]] \
      || [[ $(config_file_hash "$target") != "${CONFIG_STATE_MANAGED_HASHES[${indexes[i]}]}" ]]; then
      config_error "Managed file changed before removal; preserving it: $relative"
      failed=1; break
    fi
    printf -v checkpoint_index '%06d' "$i"
    if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
      "$name" "$relative" yes "${backup_ids[i]}" MUTATION_INTENT; then
      config_error "Could not persist deletion intent; preserving target: $relative"
      failed=1
      journal_failed=1
      break
    fi
    remove_status=0
    rm -f -- "$target" || remove_status=$?
    inspection=$(config_target_inspection_status "$home" "$relative")
    if [[ $inspection == missing ]]; then
      removed+=("$i")
      if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
        "$name" "$relative" yes "${backup_ids[i]}" APPLIED; then
        config_error "Target was removed but its completion checkpoint failed: $relative"
        failed=1
        journal_failed=1
        break
      fi
    fi
    if (( remove_status != 0 )); then
      config_error "Could not remove verified managed file: $relative"
      failed=1; break
    fi
    if [[ $inspection != missing ]]; then
      config_error "Target remains after removal attempt; preserving its ownership record: $relative"
      failed=1; break
    fi
    printf 'Removed: %s\n' "$relative"
  done

  if (( ! failed )); then
    # Reconfirm initially absent targets immediately before clearing their
    # ownership entries; a newly appeared path is preserved as a conflict.
    for i in "${!indexes[@]}"; do
      [[ ${statuses[i]} == missing && ${checkpointed[i]:-no} == yes ]] || continue
      relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
      printf -v checkpoint_index '%06d' "$i"
      if [[ $(config_target_inspection_status "$home" "$relative") == missing ]]; then
        if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
          "$name" "$relative" no - ALREADY_ABSENT; then
          config_error "Could not checkpoint already-absent target: $relative"
          failed=1
          journal_failed=1
          break
        fi
      else
        statuses[i]=unsafe
        conflicts=1
        if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
          "$name" "$relative" no - NOT_MUTATED; then
          failed=1
          journal_failed=1
          break
        fi
        config_error "Target appeared after it was classified absent; preserving it: $relative"
      fi
    done
  fi
  if (( ! failed )); then
    if ! config_transaction_journal_transition "$home" "$transaction_id" COMMITTING; then
      config_error 'Targets were removed but transaction could not enter COMMITTING'
      failed=1
      journal_failed=1
    fi
  fi
  if (( ! failed )); then
    for i in "${!indexes[@]}"; do
      [[ ${statuses[i]} == modified || ${statuses[i]} == unsafe || ${statuses[i]} == inaccessible ]] && continue
      remove_targets+=("${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}")
    done
    for relative in "${remove_targets[@]}"; do config_state_remove_managed_target "$relative"; done
    manifest_touched=1
    if ! config_state_save "$home"; then
      config_error 'State update failed after removal; restoring removed files from tracked backups'
      failed=1
    fi
  fi
  if (( ! failed )) && ! config_transaction_journal_transition "$home" "$transaction_id" COMPLETE; then
    config_error 'Targets and manifest were updated, but transaction completion could not be persisted'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi
  if (( failed )); then
    CONFIG_STATE_MANAGED_COMPONENTS=("${old_components[@]}")
    CONFIG_STATE_MANAGED_TARGETS=("${old_targets[@]}")
    CONFIG_STATE_MANAGED_HASHES=("${old_hashes[@]}")
    if (( manifest_touched )) && ! config_state_save "$home"; then
      config_error 'Could not restore prior ownership state; inspect deployment manifest and recovery backups'
      rollback_failed=1
    fi
    if config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK; then
      # A later confirmed NOT_MUTATED/ROLLED_BACK checkpoint resolves an
      # earlier failed target checkpoint write; only failures during this
      # reconciliation make the terminal transaction outcome uncertain.
      journal_failed=0
    else
      journal_failed=1
    fi
    for i in "${!indexes[@]}"; do
      [[ ${checkpointed[i]:-no} == yes ]] || continue
      in_removed=0
      for index in "${removed[@]}"; do [[ $index != "$i" ]] || in_removed=1; done
      (( in_removed == 0 )) || continue
      printf -v checkpoint_index '%06d' "$i"
      config_transaction_target_read "$home" "$transaction_id" "$checkpoint_index" || { journal_failed=1; continue; }
      checkpoint_state=$CONFIG_TXN_TARGET_STATE
      case $checkpoint_state in
        PLANNED|STAGED)
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
            "$name" "${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}" "${CONFIG_TXN_TARGET_ORIGINAL}" "$CONFIG_TXN_TARGET_BACKUP" NOT_MUTATED || journal_failed=1
          ;;
        MUTATION_INTENT)
          relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
          inspection=$(config_target_inspection_status "$home" "$relative")
          if [[ $inspection == accessible ]] \
            && [[ $(config_file_hash "$home/$relative" 2>/dev/null || true) == "${CONFIG_STATE_MANAGED_HASHES[${indexes[i]}]}" ]]; then
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
              "$name" "$relative" yes "$CONFIG_TXN_TARGET_BACKUP" NOT_MUTATED || journal_failed=1
          else
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
              "$name" "$relative" yes "$CONFIG_TXN_TARGET_BACKUP" UNCERTAIN || journal_failed=1
            rollback_failed=1
          fi
          ;;
      esac
    done
    for i in "${removed[@]}"; do
      relative=${CONFIG_STATE_MANAGED_TARGETS[${indexes[i]}]}
      target="$home/$relative"
      printf -v checkpoint_index '%06d' "$i"
      if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
        "$name" "$relative" yes "${backup_ids[i]}" ROLLBACK_INTENT; then
        config_error "Rollback intent could not be persisted; target was left unchanged: $relative"
        rollback_failed=1
        journal_failed=1
        continue
      fi
      if [[ -e $target || -L $target ]]; then
        config_error "Rollback found a new path; preserving it: $relative"
        rollback_failed=1
        config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
          "$name" "$relative" yes "${backup_ids[i]}" UNCERTAIN || journal_failed=1
        continue
      fi
      staged=$(mktemp "${target}.arclith-rollback.XXXXXXXX") || {
        config_error "Rollback staging failed; recovery backup: ${backup_paths[i]}"
        rollback_failed=1
        config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
          "$name" "$relative" yes "${backup_ids[i]}" UNCERTAIN || journal_failed=1
        continue
      }
      if cp -- "${backup_paths[i]}" "$staged" && chmod "${modes[i]}" -- "$staged" && chgrp "${groups[i]}" -- "$staged" && mv -T -- "$staged" "$target"; then
        if cmp -s -- "$target" "${backup_paths[i]}"; then
          printf 'Rollback restored: %s\n' "$relative"
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
            "$name" "$relative" yes "${backup_ids[i]}" ROLLED_BACK || journal_failed=1
        else
          config_error "Rollback verification failed; recovery backup remains: ${backup_paths[i]}"
          rollback_failed=1
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
            "$name" "$relative" yes "${backup_ids[i]}" UNCERTAIN || journal_failed=1
        fi
      else
        rm -f -- "$staged"
        config_error "Rollback failed; recovery backup remains: ${backup_paths[i]}"
        rollback_failed=1
        config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$transaction_operation" \
          "$name" "$relative" yes "${backup_ids[i]}" UNCERTAIN || journal_failed=1
      fi
    done
    if (( rollback_failed || journal_failed )); then
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    else
      config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    fi
    return 1
  fi
  printf 'Success: verified files for %s were removed; recovery backups were retained.\n' "$name"
  (( conflicts == 0 ))
}

config_uninstall_component() {
  local root=$1 home=$2 name=$3 action=$4
  shift 4
  if [[ $action == preview ]]; then
    config_uninstall_component_unlocked "$root" "$home" "$name" "$action" "$@"
    return $?
  fi
  config_lock_execute "$home" config_uninstall_component_unlocked "$root" "$home" "$name" "$action" "$@"
}

config_restore_backup_unlocked() {
  local root=$1 home=$2 selected_id=$3 confirm_all=$4 i selected=-1 backup status target relative parent
  local reply staged current_backup current_id current_hash staged_backup_hash restored_hash installed_id replacement_hash failed=0 existed=no collision attempt i
  local original_mode original_group transaction_id checkpoint_index rollback_backup_id manifest_before manifest_after
  local journal_failed=0 rollback_failed=0 rollback_status target_inspection journal_operation=restore
  config_load_registry "$root" || return 1
  if [[ ! $selected_id =~ ^[A-Za-z0-9]{8}$ ]]; then config_error 'Backup identifier must be an 8-character Arclith ID'; return 2; fi
  if [[ ! $home == /* || -L $home || ! -d $home ]]; then config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; fi
  home=$(cd -- "$home" && pwd -P)
  config_state_load "$home" || return 1
  for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
    if [[ ${CONFIG_STATE_BACKUP_IDS[i]} == "$selected_id" ]]; then selected=$i; break; fi
  done
  if (( selected < 0 )); then config_error "Backup is not present in trusted Arclith state: $selected_id"; return 1; fi
  status=$(config_state_backup_status "$home" "$selected")
  if [[ $status != available ]]; then config_error "Backup cannot be restored; state status is $status"; return 1; fi
  replacement_hash=${CONFIG_STATE_BACKUP_HASHES[selected]}

  relative=${CONFIG_STATE_BACKUP_TARGETS[selected]}
  target="$home/$relative"
  backup=$(config_state_backup_path "$home" "$relative" "$selected_id")
  parent=${relative%/*}
  [[ $parent == "$relative" ]] && parent=
  if [[ -n $parent ]] && { config_path_has_symlink "$home" "$parent" || config_path_has_non_directory_ancestor "$home" "$parent"; }; then
    config_error "Unsafe restore target parent: $home/$parent"
    return 1
  fi
  if [[ -L $target || ( -e $target && ! -f $target ) ]]; then config_error "Unsafe restore target: $target"; return 1; fi
  if [[ -e $target && $(stat -c '%u' -- "$target") != "$EUID" ]]; then config_error "Refusing to replace a file not owned by the current user: $target"; return 1; fi

  printf 'Restore preview:\n  backup: %s\n  target: %s\n' "$selected_id" "$relative"
  if [[ -e $target ]]; then
    printf '  current target: present (will be preserved as a new backup)\n'
    if [[ $confirm_all != yes ]]; then
      printf 'Replace the current target with this backup? [y/N]: ' >&2
      if ! IFS= read -r reply || [[ ! $reply =~ ^([yY]|[yY][eE][sS])$ ]]; then
        printf 'Skipped: target was not changed.\n'
        return 1
      fi
    fi
    existed=yes
    original_mode=$(stat -c '%a' -- "$target")
    original_group=$(stat -c '%g' -- "$target")
  else
    printf '  current target: absent (restore will create it)\n'
    existed=no
  fi

  manifest_before=-
  if [[ -f $home/.local/state/arclith/deployments.v1 && ! -L $home/.local/state/arclith/deployments.v1 ]]; then
    manifest_before=$(config_file_hash "$home/.local/state/arclith/deployments.v1") || return 1
  fi
  if ! config_transaction_journal_create "$home" restore "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}"; then
    if [[ ${CONFIG_TXN_JOURNAL_ID:-} =~ ^[a-f0-9]{32}$ ]]; then
      config_transaction_journal_transition "$home" "$CONFIG_TXN_JOURNAL_ID" UNCERTAIN || true
    fi
    config_error 'Could not create restore transaction journal; target was not changed'
    return 1
  fi
  transaction_id=$CONFIG_TXN_JOURNAL_ID
  checkpoint_index=000000
  if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
    "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" - PLANNED; then
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    config_error 'Could not record restore target; target was not changed'
    return 1
  fi

  current_backup=
  current_id=
  current_hash=
  if [[ $existed == yes ]]; then
    current_backup=
    for attempt in 1 2 3 4 5; do
      current_backup=$(mktemp "${target}.arclith-backup.XXXXXXXX") || break
      current_id=${current_backup##*.arclith-backup.}
      collision=0
      for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
        [[ ${CONFIG_STATE_BACKUP_IDS[i]} != "$current_id" ]] || collision=1
      done
      (( collision == 0 )) && break
      rm -f -- "$current_backup"
      current_backup=
    done
    if [[ -z $current_backup ]]; then
      config_error 'Could not allocate a unique backup identifier'
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
      return 1
    fi
    if ! cp -p -- "$target" "$current_backup" || ! chmod 600 -- "$current_backup"; then
      rm -f -- "$current_backup"
      config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK || journal_failed=1
      if (( ! journal_failed )); then
        config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
          "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" - NOT_MUTATED || journal_failed=1
      fi
      if (( journal_failed )); then config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
      else config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true; fi
      config_error "Could not preserve current target: $target"
      return 1
    fi
    current_hash=$(config_file_hash "$current_backup" 2>/dev/null) || current_hash=
    if [[ ! $current_hash =~ ^[a-f0-9]{64}$ ]]; then
      config_error "Could not fingerprint current-target recovery copy; retaining it at $current_backup"
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
      return 1
    fi
    rollback_backup_id=$current_id
    if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
      "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" PLANNED; then
      config_error 'Could not record restore rollback copy; target was not changed'
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
      return 1
    fi
  else
    original_mode=
    original_group=
    rollback_backup_id=-
  fi

  staged=$(mktemp "${target}.arclith-restore.XXXXXXXX") || {
    config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK || journal_failed=1
    if (( ! journal_failed )); then config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
      "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "${rollback_backup_id:--}" NOT_MUTATED || journal_failed=1; fi
    if (( journal_failed )); then config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    else config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true; fi
    return 1
  }
  if ! cp -- "$backup" "$staged" \
    || ! chmod "${CONFIG_STATE_BACKUP_MODES[selected]}" -- "$staged" \
    || ! chgrp "${CONFIG_STATE_BACKUP_GROUPS[selected]}" -- "$staged"; then
    rm -f -- "$staged"
    config_error 'Could not stage the selected backup'
    config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK || journal_failed=1
    if (( ! journal_failed )); then config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
      "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "${rollback_backup_id:--}" NOT_MUTATED || journal_failed=1; fi
    if (( journal_failed )); then config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    else config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true; fi
    return 1
  fi
  if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
    "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" STAGED; then
    rm -f -- "$staged"
    config_error 'Could not persist staged restore checkpoint; target was not changed'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi
  if [[ -e $target ]] && ! cmp -s -- "$target" "$current_backup"; then
    rm -f -- "$staged"
    config_error 'Target changed during restore; refusing to replace it'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  elif [[ $existed == no && -e $target ]]; then
    rm -f -- "$staged"
    config_error 'Target appeared during restore; refusing to replace it'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi
  if [[ -L $backup || ! -f $backup || $(config_file_hash "$backup") != "${CONFIG_STATE_BACKUP_HASHES[selected]}" ]] \
    || { [[ -n $parent ]] && config_path_has_symlink "$home" "$parent"; } \
    || [[ -L $target || ( $existed == no && -e $target ) || ( $existed == yes && ! -f $target ) ]] \
    || { [[ $existed == yes ]] && ! cmp -s -- "$target" "$current_backup"; }; then
    rm -f -- "$staged"
    config_error 'Backup or restore target changed during restore; refusing to continue'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi

  if ! config_transaction_journal_transition "$home" "$transaction_id" PREPARED \
    || ! config_transaction_journal_transition "$home" "$transaction_id" APPLYING; then
    rm -f -- "$staged"
    config_error 'Could not persist pre-mutation restore state; target was not changed'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi
  if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
    "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" MUTATION_INTENT; then
    rm -f -- "$staged"
    config_error 'Could not persist restore mutation intent; target was not changed'
    config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK || journal_failed=1
    if (( ! journal_failed )); then config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
      "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" NOT_MUTATED || journal_failed=1; fi
    if (( journal_failed )); then config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    else config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true; fi
    return 1
  fi

  installed_id=$(stat -c '%d:%i' -- "$staged") || installed_id=
  if [[ -z $installed_id ]]; then
    config_error 'Could not record staged restore identity; target was not replaced'
    failed=1
  elif mv -T -- "$staged" "$target"; then
    printf 'Restored: %s\n' "$relative"
  else
    if [[ -e $staged || -L $staged ]]; then installed_id=; fi
    config_error "Restore failed: $target"
    failed=1
  fi
  if (( ! failed )) && ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
    "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" APPLIED; then
    config_error 'Restore target changed, but its completion checkpoint failed'
    failed=1
  fi
  if (( ! failed )); then
    restored_hash=$(config_file_hash "$target") || restored_hash=
    if [[ ! $restored_hash =~ ^[a-f0-9]{64}$ ]]; then
      config_error "Could not verify restored target digest; deployment state was not updated: $relative"
      failed=1
    elif ! config_state_set_managed "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$restored_hash"; then
      failed=1
    fi
  fi
  if (( ! failed )); then
    if [[ $existed == yes ]]; then
      config_state_add_backup "$current_id" "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$current_hash" "$original_mode" "$original_group" || failed=1
    fi
  fi
  if (( ! failed )); then
    if ! config_transaction_journal_transition "$home" "$transaction_id" COMMITTING; then
      config_error 'Could not persist COMMITTING before deployment-state update'
      failed=1
    elif ! config_state_save "$home"; then
      config_error 'Restore completed but state could not be saved; attempting rollback'
      failed=1
    fi
  fi
  if (( ! failed )) && ! config_transaction_journal_transition "$home" "$transaction_id" COMPLETE; then
    config_error 'Restore target and manifest were saved, but transaction completion could not be persisted'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi
  if (( failed )); then
    config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK || journal_failed=1
    if [[ $manifest_before == - ]]; then
      [[ ! -e $home/.local/state/arclith/deployments.v1 && ! -L $home/.local/state/arclith/deployments.v1 ]] || rollback_failed=1
    elif [[ -f $home/.local/state/arclith/deployments.v1 && ! -L $home/.local/state/arclith/deployments.v1 ]]; then
      manifest_after=$(config_file_hash "$home/.local/state/arclith/deployments.v1") || manifest_after=
      [[ $manifest_after == "$manifest_before" ]] || rollback_failed=1
    else
      rollback_failed=1
    fi
    (( rollback_failed == 0 )) || config_error 'Deployment manifest outcome differs from its pre-restore state; transaction outcome is uncertain'
    if [[ -n $installed_id ]]; then
      if (( ! journal_failed )); then config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
        "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" ROLLBACK_INTENT || journal_failed=1; fi
      if (( journal_failed )); then
        rollback_failed=1
        config_error 'Rollback intent could not be persisted; target was left unchanged by rollback'
      elif ! config_rollback_target_matches "$target" "$installed_id" "$replacement_hash"; then
        rollback_failed=1
        config_error "Rollback stopped because the target is missing, unsafe, replaced, or has changed content; preserving the target and recovery copies: $relative"
        if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
          "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" UNCERTAIN; then
          journal_failed=1
          config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
        fi
      elif [[ $existed == yes ]]; then
        staged=$(mktemp "${target}.arclith-rollback.XXXXXXXX") || {
          config_error "Rollback staging failed; prior target backup remains at $current_backup"
          config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
            "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" UNCERTAIN || journal_failed=1
          config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
          return 1
        }
        if cp -p -- "$current_backup" "$staged" && chmod "$original_mode" -- "$staged" && chgrp "$original_group" -- "$staged"; then
          staged_backup_hash=$(config_file_hash "$staged" 2>/dev/null) || staged_backup_hash=
          if [[ ! $staged_backup_hash =~ ^[a-f0-9]{64}$ || $staged_backup_hash != "$current_hash" ]]; then
            rm -f -- "$staged" || config_error "Rollback staging cleanup failed; inspect before retrying: $staged"
            rollback_failed=1
            config_error "Rollback recovery copy failed hash verification; target was left unchanged and backup retained: $relative"
            config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
              "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" UNCERTAIN || journal_failed=1
          elif ! config_rollback_target_matches "$target" "$installed_id" "$replacement_hash"; then
            rm -f -- "$staged"
            rollback_failed=1
            config_error "Rollback stopped because the target changed before restoration; preserving the target and recovery copies: $relative"
            if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
              "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" UNCERTAIN; then
              journal_failed=1
              config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
            fi
          elif mv -T -- "$staged" "$target"; then
            printf 'Rollback restored the prior target.\n'
            [[ $journal_failed == 1 ]] || config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
              "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" ROLLED_BACK || journal_failed=1
          else
            rm -f -- "$staged"
            config_error "Rollback failed; prior target backup remains at $current_backup"
            config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
              "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" UNCERTAIN || journal_failed=1
            config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
            return 1
          fi
        else
          rm -f -- "$staged"
          config_error "Rollback failed; prior target backup remains at $current_backup"
          config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
            "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" UNCERTAIN || journal_failed=1
          config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
          return 1
        fi
      else
        rollback_status=0
        if config_rollback_target_matches "$target" "$installed_id" "$replacement_hash"; then
          rm -f -- "$target" || rollback_status=$?
          target_inspection=$(config_target_inspection_status "$home" "$relative")
          if [[ $target_inspection == missing ]]; then
            [[ $journal_failed == 1 ]] || config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
              "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" no "$selected_id" - ROLLED_BACK || journal_failed=1
          else
            config_error "Rollback failed or is uncertain; restored file may remain at $target (remove status $rollback_status)"
            config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
              "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" no "$selected_id" - UNCERTAIN || journal_failed=1
            rollback_failed=1
          fi
        else
          config_error "Rollback stopped because the target changed before removal; preserving the target and recovery copies: $relative"
          if ! config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
            "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" no "$selected_id" "$rollback_backup_id" UNCERTAIN; then
            journal_failed=1
            config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
          fi
          rollback_failed=1
        fi
      fi
    elif [[ -z $installed_id ]]; then
      if [[ $existed == yes && -f $target && ! -L $target ]] && cmp -s -- "$target" "$current_backup"; then
        [[ $journal_failed == 1 ]] || config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
          "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" yes "$selected_id" "$rollback_backup_id" NOT_MUTATED || journal_failed=1
      elif [[ $existed == no ]] && [[ ! -e $target && ! -L $target ]]; then
        [[ $journal_failed == 1 ]] || config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
          "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" no "$selected_id" - NOT_MUTATED || journal_failed=1
      else
        config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
          "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" UNCERTAIN || journal_failed=1
        rollback_failed=1
      fi
    else
      config_transaction_target_checkpoint_v2 "$home" "$transaction_id" "$checkpoint_index" restore \
        "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$existed" "$selected_id" "$rollback_backup_id" UNCERTAIN || journal_failed=1
      rollback_failed=1
    fi
    if [[ -n $current_backup && -f $current_backup ]]; then
      config_error "Current target recovery copy was retained at $current_backup"
    fi
    if (( rollback_failed || journal_failed )); then
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    else
      config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    fi
    return 1
  fi
  [[ -z $current_backup ]] || printf 'Current target backup: %s\n' "$current_backup"
  printf 'Success: backup %s restored.\n' "$selected_id"
}

config_restore_backup() {
  local root=$1 home=$2
  config_lock_execute "$home" config_restore_backup_unlocked "$@"
}

config_apply_unlocked() {
  local root=$1 name=$2 confirm_all=$3 selection=${4:-all} action=${5:-apply}
  local source source_dir target home status relative target_rel target_path parent digest state_hash removal_attempted staged_backup_hash
  local reply backup staged old_umask failed=0 rollback_failed=0 cleanup_failed=0 index target_changed parent_rel backup_id collision attempt i inspection rollback_inspection remove_status
  local transaction_id journal_operation checkpoint_index journal_failed=0 checkpoint_state rollback_index in_committed rollback_backup_id
  local -a files=() sources=() targets=() existed=() backups=() staged_files=() committed=() original_modes=() original_groups=() installed_ids=() replacement_hashes=() original_backup_hashes=()
  local -A managed_hash_by_target=()
  config_load_registry "$root" || return 1
  if ! config_component_exists "$name"; then
    config_error "Unknown configuration component: $name"
    return 2
  fi
  if [[ ${CONFIG_ENABLED[$name]} != true ]]; then
    config_error "Configuration component is disabled: $name"
    return 1
  fi
  source=${CONFIG_SOURCES[$name]}
  source_dir="$root/$source"
  target=${CONFIG_TARGETS[$name]}
  status=$(config_source_status "$root" "$name")
  if [[ $status != available ]]; then
    config_error "Cannot apply '$name': source status is $status"
    return 1
  fi
  home=${HOME:-}
  if [[ ! $home == /* || -L $home || ! -d $home ]]; then
    config_error 'HOME must be an existing absolute, non-symlink directory'
    return 1
  fi
  home=$(cd -- "$home" && pwd -P)
  config_state_load "$home" || return 1
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    managed_hash_by_target["${CONFIG_STATE_MANAGED_TARGETS[i]}"]=${CONFIG_STATE_MANAGED_HASHES[i]}
  done

  while IFS= read -r -d '' relative; do files+=("${relative#"$source_dir"/}"); done \
    < <(find "$source_dir" -type f -print0)
  if (( ${#files[@]} == 0 )); then
    config_error "Cannot apply '$name': source contains no regular files"
    return 1
  fi
  if [[ $name == zsh && ( ${#files[@]} != 1 || ${files[0]} != .zshrc ) ]]; then
    config_error 'Zsh source must contain exactly one file named .zshrc'
    return 1
  fi
  for relative in "${files[@]}"; do
    if [[ ! -s "$source_dir/$relative" ]] || ! LC_ALL=C grep -Iq . -- "$source_dir/$relative"; then
      config_error "Invalid source file (must be non-empty text): $source_dir/$relative"
      return 1
    fi
  done

  local conflicts=0
  for relative in "${files[@]}"; do
    if ! config_safe_relative_path "$relative"; then
      config_error "Invalid source file path: $relative"
      return 1
    fi
    target_rel="$target/$relative"
    [[ $target == .zshrc ]] && target_rel=$target
    target_path="$home/$target_rel"
    inspection=$(config_target_inspection_status "$home" "$target_rel")
    if [[ $inspection == inaccessible ]]; then
      config_error "Cannot inspect target path; refusing apply: $target_path"
      return 1
    fi
    parent=${target_rel%/*}
    [[ $parent == "$target_rel" ]] && parent=
    if [[ -n $parent ]] && config_path_has_symlink "$home" "$parent"; then
      config_error "Unsafe target parent contains a symlink: $home/$parent"
      return 1
    fi
    if [[ -n $parent ]] && config_path_has_non_directory_ancestor "$home" "$parent"; then
      config_error "Target parent is not a directory: $home/$parent"
      return 1
    fi
    if [[ $selection == new-only ]]; then
      if [[ -n ${managed_hash_by_target[$target_rel]+present} ]]; then
        if [[ -L $target_path || ( -e $target_path && ! -f $target_path ) ]]; then
          config_error "Unsafe tracked target: $target_path"
          return 1
        elif [[ ! -e $target_path ]]; then
          printf 'PRESERVE MISSING TRACKED FILE  %s (already has deployment state)\n' "$target_rel"
        else
          digest=$(config_file_hash "$target_path") || { config_error "Cannot hash managed target: $target_rel"; return 1; }
          state_hash=${managed_hash_by_target[$target_rel]}
          if [[ $digest != "$state_hash" ]]; then
            printf 'PRESERVE LOCAL MODIFICATION  %s\n' "$target_rel"
          else
            printf 'PRESERVE TRACKED FILE  %s\n' "$target_rel"
          fi
        fi
        continue
      fi
      if [[ -L $target_path || ( -e $target_path && ! -f $target_path ) ]]; then
        config_error "Unsafe new-file target: $target_path"
        return 1
      elif [[ -e $target_path ]]; then
        printf 'PRESERVE UNMANAGED CONFLICT  %s\n' "$target_rel"
        continue
      fi
    fi
    if [[ -L $target_path ]]; then
      config_error "Refusing symlink target: $target_path"
      return 1
    elif [[ -e $target_path && ! -f $target_path ]]; then
      config_error "Target exists but is not a regular file: $target_path"
      return 1
    elif [[ -e $target_path && $(stat -c '%u' -- "$target_path") != "$EUID" ]]; then
      config_error "Refusing to replace a file not owned by the current user: $target_path"
      return 1
    fi
    sources+=("$source_dir/$relative")
    targets+=("$target_path")
    if [[ -e $target_path ]]; then
      existed+=(yes)
      ((conflicts += 1))
      original_modes+=("$(stat -c '%a' -- "$target_path")")
      original_groups+=("$(stat -c '%g' -- "$target_path")")
    else
      existed+=(no)
      original_modes+=("")
      original_groups+=("")
    fi
    backups+=("")
    staged_files+=("")
  done

  if [[ $selection == new-only ]]; then
    if (( ${#targets[@]} == 0 )); then
      printf 'No new files to apply; existing targets were preserved.\n'
      return 0
    fi
    if [[ $action == dry-run ]]; then
      for target_path in "${targets[@]}"; do printf 'Would apply new file: %s\n' "${target_path#"$home"/}"; done
      printf 'Dry run complete; no files or state were changed.\n'
      return 0
    fi
  fi

  if (( conflicts > 0 )) && [[ $confirm_all != yes ]]; then
    printf 'This will replace %d existing file(s). Recoverable backups will be created beside them. Continue? [y/N]: ' "$conflicts" >&2
    if ! IFS= read -r reply || [[ ! $reply =~ ^([yY]|[yY][eE][sS])$ ]]; then
      printf 'Skipped: no files were changed.\n'
      return 1
    fi
  fi

  if [[ $selection == new-only && $confirm_all != yes ]]; then
    printf 'Apply %d new configuration file(s)? [y/N]: ' "${#targets[@]}" >&2
    if ! IFS= read -r reply || [[ ! $reply =~ ^([yY]|[yY][eE][sS])$ ]]; then
      printf 'Skipped: no files were changed.\n'
      return 1
    fi
  fi

  journal_operation=apply
  [[ $selection != new-only ]] || journal_operation=apply-new
  if ! config_transaction_journal_create "$home" "$journal_operation" "$name"; then
    config_error 'Could not create transaction journal; no target mutation was started'
    return 1
  fi
  transaction_id=$CONFIG_TXN_JOURNAL_ID
  for index in "${!targets[@]}"; do
    printf -v checkpoint_index '%06d' "$index"
    if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" "${existed[index]}" - PLANNED; then
      config_error 'Could not record the planned target set; no target mutation was started'
      return 1
    fi
  done

  # Create only missing registered target parents, with owner-only permissions.
  for target_path in "${targets[@]}"; do
    parent=${target_path%/*}
    if [[ $parent == "$home" ]]; then parent_rel=; else parent_rel=${parent#"$home"/}; fi
    if [[ -n $parent_rel ]] && { config_path_has_symlink "$home" "$parent_rel" || config_path_has_non_directory_ancestor "$home" "$parent_rel"; }; then
      config_error "Unsafe target parent before directory creation: $parent"
      return 1
    fi
    if [[ ! -d $parent ]]; then
      old_umask=$(umask)
      if ! (umask 077; mkdir -p -- "$parent"); then
        config_error "Failed to create target directory: $parent"
        return 1
      fi
      umask "$old_umask"
    fi
  done

  # Back up conflicts and stage every source before replacing any destination.
  for index in "${!targets[@]}"; do
    target_path=${targets[index]}
    if [[ -L ${sources[index]} || ! -f ${sources[index]} ]] || ! LC_ALL=C grep -Iq . -- "${sources[index]}"; then
      config_error "Source changed or became invalid during apply: ${sources[index]}"
      failed=1
      break
    fi
    if [[ ${existed[index]} == yes ]]; then
      if [[ -L $target_path || ! -f $target_path ]]; then
        config_error "Target changed during apply; refusing: $target_path"
        failed=1
        break
      fi
      backup=
      for attempt in 1 2 3 4 5; do
        backup=$(mktemp "${target_path}.arclith-backup.XXXXXXXX") || break
        backup_id=${backup##*.arclith-backup.}
        collision=0
        for i in "${!CONFIG_STATE_BACKUP_IDS[@]}"; do
          [[ ${CONFIG_STATE_BACKUP_IDS[i]} != "$backup_id" ]] || collision=1
        done
        (( collision == 0 )) && break
        rm -f -- "$backup"
        backup=
      done
      [[ -n $backup ]] || { failed=1; break; }
      backups[index]=$backup
      if ! cp -p -- "$target_path" "$backup" || ! chmod 600 -- "$backup"; then
        config_error "Could not create a restrictive backup for: $target_path"
        failed=1
        break
      fi
      original_backup_hashes[index]=$(config_file_hash "$backup" 2>/dev/null) || original_backup_hashes[index]=
      if [[ ! ${original_backup_hashes[index]} =~ ^[a-f0-9]{64}$ ]]; then
        config_error "Could not fingerprint recovery backup for: $target_path"
        failed=1
        break
      fi
      printf -v checkpoint_index '%06d' "$index"
      if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" yes "$backup_id" PLANNED; then
        config_error "Could not record the recovery-copy reference: $target_path"
        failed=1
        break
      fi
    fi
    staged=$(mktemp "${target_path}.arclith-new.XXXXXXXX") || { failed=1; break; }
    staged_files[index]=$staged
    if ! cp -- "${sources[index]}" "$staged" || ! chmod 600 -- "$staged"; then
      config_error "Could not stage source file: ${sources[index]}"
      failed=1
      break
    fi
    if [[ -L $staged || ! -f $staged || ! -s $staged ]] || ! LC_ALL=C grep -Iq . -- "$staged"; then
      config_error "Staged source is invalid (must be non-empty text); target will not be installed: ${sources[index]}"
      failed=1
      break
    fi
    replacement_hashes[index]=$(config_file_hash "$staged") || {
      config_error "Could not fingerprint staged source file: ${sources[index]}"
      failed=1
      break
    }
    printf -v checkpoint_index '%06d' "$index"
    backup_id=-
    [[ -z ${backups[index]} ]] || backup_id=${backups[index]##*.arclith-backup.}
    if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" "${existed[index]}" "$backup_id" STAGED; then
      config_error "Could not checkpoint staged target: ${targets[index]#"$home"/}"
      failed=1
      break
    fi
  done
  if (( failed )); then
    for staged in "${staged_files[@]}"; do
      [[ -n $staged ]] || continue
      if ! rm -f -- "$staged" && [[ -e $staged || -L $staged ]]; then
        config_error "Staged-file cleanup failed; inspect before retrying: $staged"
        cleanup_failed=1
      fi
    done
    (( cleanup_failed == 0 )) || config_error 'Staged-file cleanup was incomplete; inspect the reported paths before retrying'
    (( cleanup_failed == 0 )) || rollback_failed=1
    if ! config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK; then journal_failed=1; fi
    for index in "${!targets[@]}"; do
      printf -v checkpoint_index '%06d' "$index"
      in_committed=0
      for rollback_index in "${committed[@]}"; do [[ $rollback_index == "$index" ]] && in_committed=1; done
      (( in_committed == 0 )) || continue
      config_transaction_target_read "$home" "$transaction_id" "$checkpoint_index" || { journal_failed=1; continue; }
      checkpoint_state=$CONFIG_TXN_TARGET_STATE
      case $checkpoint_state in
        PLANNED|STAGED)
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" "${existed[index]}" "$CONFIG_TXN_TARGET_BACKUP" NOT_MUTATED || journal_failed=1
          ;;
      esac
    done
    if (( journal_failed || rollback_failed )); then
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
      if (( journal_failed )); then config_error 'Journal checkpoint persistence failed; no target replacement was attempted and the last persisted state remains'; fi
    else
      config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || journal_failed=1
    fi
    printf 'Failed: no target files were replaced. Any created backups were preserved.\n'
    return 1
  fi

  if ! config_transaction_journal_transition "$home" "$transaction_id" PREPARED \
    || ! config_transaction_journal_transition "$home" "$transaction_id" APPLYING; then
    config_error 'Could not persist the pre-mutation journal state; no target replacement was started'
    failed=1
  fi

  # Recheck immediately before each atomic rename, and roll back committed files
  # if any later rename or check fails.
  for index in "${!targets[@]}"; do
    (( failed == 0 )) || break
    target_path=${targets[index]}
    relative=${target_path#"$home"/}
    parent=${relative%/*}
    target_changed=0
    if [[ -L $target_path ]]; then
      target_changed=1
    elif [[ ${existed[index]} == yes ]]; then
      [[ -f $target_path ]] && cmp -s -- "$target_path" "${backups[index]}" || target_changed=1
    elif [[ -e $target_path ]]; then
      target_changed=1
    fi
    if (( target_changed )) || { [[ -n $parent ]] && config_path_has_symlink "$home" "$parent"; }; then
      config_error "Target changed during apply; refusing: $target_path"
      failed=1
      break
    fi
    printf -v checkpoint_index '%06d' "$index"
    backup_id=-
    [[ -z ${backups[index]} ]] || backup_id=${backups[index]##*.arclith-backup.}
    if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "$relative" "${existed[index]}" "$backup_id" MUTATION_INTENT; then
      config_error "Could not persist mutation intent; target was not replaced: $relative"
      failed=1
      break
    fi
    if [[ ! -f ${staged_files[index]} || -L ${staged_files[index]} ]] \
      || [[ $(config_file_hash "${staged_files[index]}" 2>/dev/null || true) != "${replacement_hashes[index]}" ]]; then
      config_error "Staged replacement changed before installation; target was not replaced: $relative"
      failed=1
      break
    fi
    installed_ids[index]=$(stat -c '%d:%i' -- "${staged_files[index]}") || {
      config_error "Could not record staged replacement identity; target was not replaced: $relative"
      failed=1
      break
    }
    if mv -T -- "${staged_files[index]}" "$target_path"; then
      committed+=("$index")
      staged_files[index]=
      printf 'Applied: %s\n' "$relative"
      if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "$relative" "${existed[index]}" "$backup_id" APPLIED; then
        config_error "Target changed but its completion checkpoint failed: $relative"
        failed=1
        break
      fi
    else
      # A wrapper or filesystem can report failure after completing a rename.
      if [[ ! -e ${staged_files[index]} && -f $target_path && ! -L $target_path ]]; then
        committed+=("$index")
      else
        installed_ids[index]=
      fi
      config_error "Failed to install: $target_path"
      failed=1
      break
    fi
  done

  if (( ! failed )) && ! config_transaction_journal_transition "$home" "$transaction_id" COMMITTING; then
    config_error 'All targets were applied, but the transaction could not enter COMMITTING; rolling targets back'
    failed=1
  fi
  if (( ! failed )); then
    for index in "${!targets[@]}"; do
      relative=${targets[index]#"$home"/}
      digest=$(config_file_hash "${targets[index]}") || digest=
      if [[ ! $digest =~ ^[a-f0-9]{64}$ ]]; then
        config_error "Could not verify installed target digest; deployment state was not updated: $relative"
        failed=1
        break
      fi
      config_state_set_managed "$name" "$relative" "$digest" || { failed=1; break; }
      if [[ -n ${backups[index]} ]]; then
        backup_id=${backups[index]##*.arclith-backup.}
        digest=$(config_file_hash "${backups[index]}") || digest=
        if [[ ! $digest =~ ^[a-f0-9]{64}$ || $digest != "${original_backup_hashes[index]}" ]]; then
          config_error "Could not verify recovery backup digest; deployment state was not updated: $relative"
          failed=1
          break
        fi
        config_state_add_backup "$backup_id" "$name" "$relative" "$digest" "${original_modes[index]}" "${original_groups[index]}" || { failed=1; break; }
      fi
    done
  fi
  if (( ! failed )) && ! config_state_save "$home"; then
    config_error 'Deployment succeeded but state could not be saved; rolling the deployed files back'
    failed=1
  fi

  if (( ! failed )) && ! config_transaction_journal_transition "$home" "$transaction_id" COMPLETE; then
    config_error 'Targets and deployment state were saved, but the journal completion checkpoint failed'
    config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    return 1
  fi

  if (( failed )); then
    for staged in "${staged_files[@]}"; do
      [[ -n $staged ]] || continue
      if ! rm -f -- "$staged" && [[ -e $staged || -L $staged ]]; then
        config_error "Staged-file cleanup failed; inspect before retrying: $staged"
        cleanup_failed=1
      fi
    done
    (( cleanup_failed == 0 )) || config_error 'Staged-file cleanup was incomplete; inspect the reported paths before retrying'
    (( cleanup_failed == 0 )) || rollback_failed=1
    if ! config_transaction_journal_transition "$home" "$transaction_id" ROLLING_BACK; then journal_failed=1; fi
    for index in "${!targets[@]}"; do
      printf -v checkpoint_index '%06d' "$index"
      in_committed=0
      for rollback_index in "${committed[@]}"; do [[ $rollback_index == "$index" ]] && in_committed=1; done
      (( in_committed == 0 )) || continue
      config_transaction_target_read "$home" "$transaction_id" "$checkpoint_index" || { journal_failed=1; continue; }
      checkpoint_state=$CONFIG_TXN_TARGET_STATE
      case $checkpoint_state in
        PLANNED|STAGED)
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" "${existed[index]}" "$CONFIG_TXN_TARGET_BACKUP" NOT_MUTATED || journal_failed=1
          ;;
        MUTATION_INTENT)
          if [[ ${existed[index]} == yes && -f ${targets[index]} && ! -L ${targets[index]} ]] \
            && [[ -n ${backups[index]} ]] && cmp -s -- "${targets[index]}" "${backups[index]}"; then
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" yes "$CONFIG_TXN_TARGET_BACKUP" NOT_MUTATED || journal_failed=1
          elif [[ ${existed[index]} == no && ! -e ${targets[index]} && ! -L ${targets[index]} ]]; then
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" no - NOT_MUTATED || journal_failed=1
          else
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${targets[index]#"$home"/}" "${existed[index]}" "$CONFIG_TXN_TARGET_BACKUP" UNCERTAIN || journal_failed=1
            rollback_failed=1
          fi
          ;;
      esac
    done
    for (( index=${#committed[@]}-1; index>=0; index-- )); do
      local committed_index=${committed[index]}
      target_path=${targets[committed_index]}
      printf -v checkpoint_index '%06d' "$committed_index"
      rollback_backup_id=-
      [[ -z ${backups[committed_index]} ]] || rollback_backup_id=${backups[committed_index]##*.arclith-backup.}
      if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" "${existed[committed_index]}" "$rollback_backup_id" ROLLBACK_INTENT; then
        config_error "Rollback intent could not be persisted; target was left unchanged by rollback: ${target_path#"$home"/}"
        rollback_failed=1
        journal_failed=1
        if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" "${existed[committed_index]}" "$rollback_backup_id" UNCERTAIN; then
          config_error 'Target uncertainty could not be persisted; the last target checkpoint remains in effect'
        fi
        continue
      fi
      if ! config_rollback_target_matches "$target_path" "${installed_ids[committed_index]:-}" "${replacement_hashes[committed_index]:-}"; then
        config_error "Rollback stopped because the target is missing, unsafe, replaced, or has changed content; preserving the target and recovery copies: ${target_path#"$home"/}"
        rollback_failed=1
        if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" "${existed[committed_index]}" "$rollback_backup_id" UNCERTAIN; then
          journal_failed=1
          config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
        fi
        continue
      fi
      if [[ ${existed[committed_index]} == yes ]]; then
        staged=$(mktemp "${target_path}.arclith-restore.XXXXXXXX") || {
          config_error "Rollback could not stage restoration for $target_path; recoverable backup remains at ${backups[committed_index]}"
          rollback_failed=1
          continue
        }
      if cp -p -- "${backups[committed_index]}" "$staged" \
        && chmod "${original_modes[committed_index]}" -- "$staged" \
        && chgrp "${original_groups[committed_index]}" -- "$staged"; then
        staged_backup_hash=$(config_file_hash "$staged" 2>/dev/null) || staged_backup_hash=
        if [[ ! $staged_backup_hash =~ ^[a-f0-9]{64}$ || $staged_backup_hash != "${original_backup_hashes[committed_index]:-}" ]]; then
          rm -f -- "$staged" || config_error "Rollback staging cleanup failed; inspect before retrying: $staged"
          config_error "Rollback recovery copy failed hash verification; target was left unchanged and backup retained: ${target_path#"$home"/}"
          rollback_failed=1
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" yes "$rollback_backup_id" UNCERTAIN || journal_failed=1
          continue
        fi
        if ! config_rollback_target_matches "$target_path" "${installed_ids[committed_index]:-}" "${replacement_hashes[committed_index]:-}"; then
          rm -f -- "$staged"
          config_error "Rollback stopped because the target changed before restoration; preserving the target and recovery copies: ${target_path#"$home"/}"
          rollback_failed=1
          if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" yes "$rollback_backup_id" UNCERTAIN; then
            journal_failed=1
            config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
          fi
          continue
        fi
        if mv -T -- "$staged" "$target_path"; then
          printf 'Restored: %s\n' "${target_path#"$home"/}"
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" "${existed[committed_index]}" "$rollback_backup_id" ROLLED_BACK || journal_failed=1
        else
          rm -f -- "$staged"
          config_error "Rollback failed; recoverable backup remains at ${backups[committed_index]}"
          rollback_failed=1
          config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" "${existed[committed_index]}" "$rollback_backup_id" UNCERTAIN || journal_failed=1
        fi
      else
        rm -f -- "$staged"
        config_error "Rollback failed; recoverable backup remains at ${backups[committed_index]}"
        rollback_failed=1
        config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" yes "$rollback_backup_id" UNCERTAIN || journal_failed=1
      fi
      elif config_rollback_target_matches "$target_path" "${installed_ids[committed_index]:-}" "${replacement_hashes[committed_index]:-}"; then
        remove_status=0
        removal_attempted=0
        if config_rollback_target_matches "$target_path" "${installed_ids[committed_index]:-}" "${replacement_hashes[committed_index]:-}"; then
          removal_attempted=1
          rm -f -- "$target_path" || remove_status=$?
        fi
        rollback_inspection=$(config_target_inspection_status "$home" "${target_path#"$home"/}")
        if (( removal_attempted == 0 )); then
          config_error "Rollback stopped because the target changed before removal; preserving the target and recovery copies: ${target_path#"$home"/}"
          rollback_failed=1
          if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - UNCERTAIN; then
            journal_failed=1
            config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
          fi
        else case $rollback_inspection in
          missing)
            if (( remove_status == 0 )); then
              printf 'Rolled back new file: %s\n' "${target_path#"$home"/}"
            else
              printf 'Rolled back new file despite remove reporting failure: %s\n' "${target_path#"$home"/}"
            fi
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - ROLLED_BACK || journal_failed=1
            ;;
          accessible)
            config_error "Rollback failed; newly deployed file remains at $target_path"
            rollback_failed=1
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - UNCERTAIN || journal_failed=1
            ;;
          inaccessible)
            config_error "Rollback incomplete; cannot inspect newly deployed target at $target_path"
            rollback_failed=1
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - UNCERTAIN || journal_failed=1
            ;;
          unsafe)
            config_error "Rollback incomplete; target path became unsafe during removal: $target_path"
            rollback_failed=1
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - UNCERTAIN || journal_failed=1
            ;;
          *)
            config_error "Rollback incomplete; could not determine target state for $target_path"
            rollback_failed=1
            config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - UNCERTAIN || journal_failed=1
            ;;
        esac
        fi
      else
        config_error "Rollback stopped because the target is missing, unsafe, replaced, or has changed content; preserving the target and recovery copies: ${target_path#"$home"/}"
        rollback_failed=1
        if ! config_transaction_target_checkpoint "$home" "$transaction_id" "$checkpoint_index" "$journal_operation" "$name" "${target_path#"$home"/}" no - UNCERTAIN; then
          journal_failed=1
          config_error 'Conflict was preserved, but its target checkpoint could not be recorded; transaction uncertainty will be recorded if possible'
        fi
      fi
    done
    if (( rollback_failed || journal_failed )); then
      config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    else
      config_transaction_journal_transition "$home" "$transaction_id" ROLLED_BACK || config_transaction_journal_transition "$home" "$transaction_id" UNCERTAIN || true
    fi
    if (( rollback_failed )); then
      config_error 'One or more rollback operations failed; inspect the reported target paths and recoverable backups'
      printf 'Failed: deployment rollback was incomplete.\n'
    else
      printf 'Failed: deployment rolled back successfully. Backups are retained.\n'
    fi
    return 1
  fi

  for index in "${!backups[@]}"; do
    [[ -z ${backups[index]} ]] || printf 'Backup: %s\n' "${backups[index]}"
  done
  printf 'Success: configuration component %s applied.\n' "$name"
}

config_apply() {
  local root=$1 name=$2 confirm_all=$3 selection=${4:-all} action=${5:-apply}
  if [[ $action == dry-run ]]; then
    config_apply_unlocked "$@"
    return $?
  fi
  config_lock_execute "${HOME:-}" config_apply_unlocked "$@"
}

config_transaction_inspection_directory() {
  local home=$1 state_dir journal_dir owner mode
  home=$(config_transaction_journal_home "$home") || return 3
  state_dir=$(config_state_directory "$home")
  journal_dir="$state_dir/transactions"
  if [[ ! -e $state_dir && ! -L $state_dir ]]; then printf '%s' ''; return 0; fi
  [[ -d $state_dir && ! -L $state_dir ]] || { config_error 'Transaction state directory is unsafe (reason=UNSAFE_STORAGE)'; return 3; }
  owner=$(stat -c '%u' -- "$state_dir" 2>/dev/null) || { config_error 'Cannot inspect transaction state directory (reason=RECORD_INACCESSIBLE)'; return 3; }
  mode=$(stat -c '%a' -- "$state_dir" 2>/dev/null) || { config_error 'Cannot inspect transaction state directory (reason=RECORD_INACCESSIBLE)'; return 3; }
  [[ $owner == "$EUID" && $mode =~ ^[0-7]{3,4}$ ]] && (( (8#$mode & 077) == 0 )) \
    || { config_error 'Transaction state directory has unsafe ownership or permissions (reason=UNSAFE_STORAGE)'; return 3; }
  if [[ ! -e $journal_dir && ! -L $journal_dir ]]; then printf '%s' ''; return 0; fi
  [[ -d $journal_dir && ! -L $journal_dir ]] || { config_error 'Transaction journal directory is unsafe (reason=UNSAFE_STORAGE)'; return 3; }
  owner=$(stat -c '%u' -- "$journal_dir" 2>/dev/null) || { config_error 'Cannot inspect transaction journal directory (reason=RECORD_INACCESSIBLE)'; return 3; }
  mode=$(stat -c '%a' -- "$journal_dir" 2>/dev/null) || { config_error 'Cannot inspect transaction journal directory (reason=RECORD_INACCESSIBLE)'; return 3; }
  [[ $owner == "$EUID" && $mode == 700 ]] || { config_error 'Transaction journal directory has unsafe ownership or permissions (reason=UNSAFE_STORAGE)'; return 3; }
  printf '%s' "$journal_dir"
}

config_transaction_inspection_target_compatible() {
  local transaction_state=$1 operation=$2 target_state=$3
  case $transaction_state:$target_state in
    PREPARING:PLANNED|PREPARING:STAGED|PREPARING:UNCERTAIN \
    |PREPARED:STAGED|PREPARED:UNCERTAIN \
    |APPLYING:PLANNED|APPLYING:STAGED|APPLYING:MUTATION_INTENT|APPLYING:APPLIED|APPLYING:NOT_MUTATED|APPLYING:ALREADY_ABSENT|APPLYING:UNCERTAIN \
    |COMMITTING:APPLIED|COMMITTING:NOT_MUTATED|COMMITTING:ALREADY_ABSENT|COMMITTING:UNCERTAIN \
    |ROLLING_BACK:PLANNED|ROLLING_BACK:STAGED|ROLLING_BACK:MUTATION_INTENT|ROLLING_BACK:APPLIED|ROLLING_BACK:ROLLBACK_INTENT|ROLLING_BACK:ROLLED_BACK|ROLLING_BACK:NOT_MUTATED|ROLLING_BACK:ALREADY_ABSENT|ROLLING_BACK:UNCERTAIN \
    |UNCERTAIN:PLANNED|UNCERTAIN:STAGED|UNCERTAIN:MUTATION_INTENT|UNCERTAIN:APPLIED|UNCERTAIN:ROLLBACK_INTENT|UNCERTAIN:ROLLED_BACK|UNCERTAIN:NOT_MUTATED|UNCERTAIN:ALREADY_ABSENT|UNCERTAIN:UNCERTAIN) return 0 ;;
    ROLLED_BACK:ROLLED_BACK|ROLLED_BACK:NOT_MUTATED) return 0 ;;
    ROLLED_BACK:ALREADY_ABSENT)
      [[ $operation == uninstall || $operation == prune ]] ;;
    COMPLETE:APPLIED) return 0 ;;
    COMPLETE:NOT_MUTATED|COMPLETE:ALREADY_ABSENT)
      [[ $operation == uninstall || $operation == prune ]] ;;
    *) return 1 ;;
  esac
}

config_transaction_inspect_one() {
  local home=$1 directory=$2 id=$3 journal_path target_dir name index version state class=VALID listing
  local target_count=0 target_error=0 target_state original operation component transaction_state
  local transaction_created transaction_updated journal_validation
  local -a target_entries=() names=() reasons=()
  [[ $id =~ ^[a-f0-9]{32}$ ]] || { config_error 'Transaction ID must be 32 lowercase hexadecimal characters'; return 2; }
  journal_path="$directory/$id.v1"
  if [[ ! -e $journal_path && ! -L $journal_path ]]; then printf '%s  MALFORMED reason=RECORD_NOT_FOUND\n' "$id"; return 1; fi
  [[ -r $journal_path ]] || { printf '%s  OPERATIONAL_ERROR reason=RECORD_INACCESSIBLE\n' "$id"; return 3; }
  if ! config_transaction_journal_parse_file "$journal_path" "$id" 2>/dev/null; then
    if [[ $CONFIG_TXN_PARSE_OPERATIONAL == yes ]]; then printf '%s  OPERATIONAL_ERROR reason=%s\n' "$id" "$CONFIG_TXN_PARSE_REASON"; return 3; fi
    printf '%s  MALFORMED reason=%s\n' "$id" "${CONFIG_TXN_PARSE_REASON:-MALFORMED_RECORD}"
    return 1
  fi
  operation=$CONFIG_TXN_JOURNAL_OPERATION
  component=$CONFIG_TXN_JOURNAL_COMPONENT
  transaction_state=$CONFIG_TXN_JOURNAL_STATE
  transaction_created=$CONFIG_TXN_JOURNAL_CREATED_UTC
  transaction_updated=$CONFIG_TXN_JOURNAL_UPDATED_UTC
  target_dir="$directory/$id.targets"
  if [[ -e $target_dir || -L $target_dir ]]; then
    if [[ ! -d $target_dir || -L $target_dir || $(stat -c '%u:%a' -- "$target_dir" 2>/dev/null) != "$EUID:700" ]]; then
      config_error 'Target checkpoint directory is unsafe or inaccessible (reason=UNSAFE_STORAGE)'
      return 3
    fi
    if ! listing=$(find "$target_dir" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null); then
      config_error 'Cannot enumerate target checkpoint records (reason=RECORD_INACCESSIBLE)'
      return 3
    fi
    if [[ -n $listing ]]; then mapfile -t names < <(printf '%s\n' "$listing" | LC_ALL=C sort); fi
    for name in "${names[@]}"; do
      [[ $name =~ ^\.[0-9]{6}(\.v2)?\.tmp\.[A-Za-z0-9]{8}$ ]] && continue
      if [[ $name =~ ^([0-9]{6})\.v([12])$ ]]; then
        index=${BASH_REMATCH[1]}; version=${BASH_REMATCH[2]}
        if [[ -e $target_dir/$index.v1 && -e $target_dir/$index.v2 ]]; then target_error=1; reasons+=(INCONSISTENT_CHECKPOINTS); continue; fi
        if [[ ! -r $target_dir/$name ]]; then printf '%s  OPERATIONAL_ERROR reason=RECORD_INACCESSIBLE\n' "$id"; return 3; fi
        if ! config_transaction_target_parse_file "$target_dir/$name" "$id" "$index" 2>/dev/null; then
          if [[ $CONFIG_TXN_PARSE_OPERATIONAL == yes ]]; then printf '%s  OPERATIONAL_ERROR reason=%s\n' "$id" "$CONFIG_TXN_PARSE_REASON"; return 3; fi
          target_error=1; reasons+=("${CONFIG_TXN_PARSE_REASON:-MALFORMED_RECORD}"); continue
        fi
        [[ $CONFIG_TXN_TARGET_OPERATION == "$operation" && $CONFIG_TXN_TARGET_COMPONENT == "$component" \
          && $CONFIG_TXN_TARGET_INDEX == "$index" ]] || { target_error=1; reasons+=(IDENTITY_MISMATCH); }
        if [[ ( $operation == uninstall || $operation == prune ) && $CONFIG_TXN_TARGET_STATE == APPLIED ]]; then
          [[ $CONFIG_TXN_TARGET_ORIGINAL == yes && $CONFIG_TXN_TARGET_BACKUP != - ]] || { target_error=1; reasons+=(INCONSISTENT_CHECKPOINTS); }
        fi
        if ! config_transaction_inspection_target_compatible "$transaction_state" "$operation" "$CONFIG_TXN_TARGET_STATE"; then
          target_error=1; reasons+=(INCOMPATIBLE_STATES)
        fi
        target_entries+=("$index|$CONFIG_TXN_TARGET_STATE|$CONFIG_TXN_TARGET_ORIGINAL|$version|$CONFIG_TXN_TARGET_UPDATED_UTC")
        ((target_count += 1))
      else
        target_error=1; reasons+=(MALFORMED_RECORD)
      fi
    done
  fi
  if (( target_error )); then
    class=INCONSISTENT
    journal_validation=FINDINGS
  else
    journal_validation=VALID
    if [[ $transaction_state == UNCERTAIN ]]; then class=UNCERTAIN
    elif [[ $transaction_state == COMPLETE || $transaction_state == ROLLED_BACK ]]; then class=COMPLETE
    else class=IN_PROGRESS
    fi
  fi
  printf '%s  %s  operation=%s component=%s transaction_state=%s targets=%d\n' \
    "$id" "$class" "$operation" "$component" "$transaction_state" "$target_count"
  for state in "${reasons[@]}"; do printf '  diagnostic reason=%s\n' "$state"; done
  if [[ ${CONFIG_TXN_INSPECT_DETAIL:-no} == yes ]]; then
    printf '  evidence_source=JOURNAL_ONLY journal_validation=%s transaction_schema=v1\n' "$journal_validation"
    printf '  transaction_created_utc=%s transaction_updated_utc=%s\n' "$transaction_created" "$transaction_updated"
    printf '  filesystem_check=NOT_PERFORMED target_and_manifest_outcomes=UNVERIFIED\n'
    printf '  snapshot_consistency=UNVERIFIED_LOCK_FREE (inspection does not acquire the mutation lock)\n'
    for state in "${target_entries[@]}"; do
      IFS='|' read -r index target_state original version target_updated <<< "$state"
      printf '  target[%s] state=%s original=%s schema=v%s updated_utc=%s\n' \
        "$index" "$target_state" "$original" "$version" "$target_updated"
    done
    printf '  manual_review=Inspect current targets and deployment state; verify backups with config artifacts. Preserve files; do not rerun based only on this report.\n'
  fi
  [[ $class != INCONSISTENT ]]
}

config_transactions_inspect() {
  local home=$1 requested=${2:-} directory entry id status=0 class listing
  local -a entries=() ids=()
  directory=$(config_transaction_inspection_directory "$home") || return $?
  if [[ -z $directory ]]; then
    if [[ -n $requested ]]; then printf '%s  MALFORMED reason=RECORD_NOT_FOUND\n' "$requested"; return 1; fi
    printf 'No transaction journals found.\n'
    return 0
  fi
  if ! listing=$(find "$directory" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null); then
    config_error 'Cannot enumerate transaction journal directory (reason=RECORD_INACCESSIBLE)'
    return 3
  fi
  if [[ -n $listing ]]; then mapfile -t entries < <(printf '%s\n' "$listing" | LC_ALL=C sort); fi
  if [[ -n $requested ]]; then
    CONFIG_TXN_INSPECT_DETAIL=yes
    if config_transaction_inspect_one "$home" "$directory" "$requested"; then status=0; else status=$?; fi
    CONFIG_TXN_INSPECT_DETAIL=no
    printf 'Target enumeration is incomplete by design: this report validates only records found; it cannot prove every target in the original operation was recorded.\n'
    return "$status"
  fi
  for entry in "${entries[@]}"; do
    [[ $entry =~ ^\.[a-f0-9]{32}\.tmp\.[A-Za-z0-9]{8}$ ]] && continue
    if [[ $entry =~ ^([a-f0-9]{32})\.v1$ ]]; then
      ids+=("${BASH_REMATCH[1]}")
    elif [[ $entry =~ ^([a-f0-9]{32})\.targets$ ]]; then
      id=${BASH_REMATCH[1]}
      [[ -e $directory/$id.v1 || -L $directory/$id.v1 ]] || { printf '%s  INCONSISTENT reason=INCONSISTENT_CHECKPOINTS\n' "$id"; status=1; }
    else
      printf 'INVALID_ENTRY  MALFORMED reason=MALFORMED_RECORD\n'
      status=1
    fi
  done
  if (( ${#ids[@]} == 0 )) && (( status == 0 )); then printf 'No transaction journals found.\n'; return 0; fi
  for id in "${ids[@]}"; do
    if config_transaction_inspect_one "$home" "$directory" "$id"; then :; else
      class=$?
      (( class == 3 )) && return 3
      status=1
    fi
  done
  printf 'Filesystem mutations are not checked; journal states do not prove target or manifest contents.\n'
  printf 'Target enumeration is incomplete by design: this report validates only records found; it cannot prove every target in the original operation was recorded.\n'
  return "$status"
}

config_main() {
  local action=${1:-list}
  local root="$PROJECT_ROOT"
  local home=${HOME:-}
  case $action in
    list) (( $# <= 1 )) || { config_error 'Usage: arclith.sh config list'; return 2; }; config_list "$root" ;;
    validate) (( $# == 1 )) || { config_error 'Usage: arclith.sh config validate'; return 2; }; config_validate_registry "$root" ;;
    doctor) (( $# == 1 )) || { config_error 'Usage: arclith.sh config doctor'; return 2; }; config_doctor "$root" ;;
    info) (( $# == 2 )) || { config_error 'Usage: arclith.sh config info <component>'; return 2; }; config_info "$root" "$2" ;;
    preview) (( $# == 2 )) || { config_error 'Usage: arclith.sh config preview <component>'; return 2; }; config_preview "$root" "$2" ;;
    apply)
      if (( $# == 2 )); then config_apply "$root" "$2" no
      elif (( $# == 3 )) && [[ $3 == --yes ]]; then config_apply "$root" "$2" yes
      else config_error 'Usage: arclith.sh config apply <component> [--yes]'; return 2; fi
      ;;
    apply-new)
      if (( $# == 2 )); then config_apply "$root" "$2" no new-only apply
      elif (( $# == 3 )) && [[ $3 == --dry-run ]]; then config_apply "$root" "$2" no new-only dry-run
      elif (( $# == 3 )) && [[ $3 == --yes ]]; then config_apply "$root" "$2" yes new-only apply
      else config_error 'Usage: arclith.sh config apply-new <component> [--dry-run|--yes]'; return 2; fi
      ;;
    backups)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config backups [component]'; return 2; }
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_backup_list "$root" "$home" "$2"
      else config_backup_list "$root" "$home"; fi
      ;;
    artifacts)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config artifacts [component]'; return 2; }
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_artifacts "$root" "$home" "$2"
      else config_artifacts "$root" "$home"; fi
      ;;
    transactions)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config transactions [transaction-id]'; return 2; }
      if (( $# == 2 )) && [[ ! $2 =~ ^[a-f0-9]{32}$ ]]; then
        config_error 'Transaction ID must be 32 lowercase hexadecimal characters'
        return 2
      fi
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory (reason=UNSAFE_STORAGE)'; return 3; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_transactions_inspect "$home" "$2"
      else config_transactions_inspect "$home"; fi
      ;;
    status)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config status [component]'; return 2; }
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_state_status "$root" "$home" "$2"
      else config_state_status "$root" "$home"; fi
      ;;
    updates)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config updates [component]'; return 2; }
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_updates "$root" "$home" "$2"
      else config_updates "$root" "$home"; fi
      ;;
    restore)
      if (( $# == 2 )); then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_restore_backup "$root" "$(cd -- "$home" && pwd -P)" "$2" no
      elif (( $# == 3 )) && [[ $3 == --yes ]]; then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_restore_backup "$root" "$(cd -- "$home" && pwd -P)" "$2" yes
      else config_error 'Usage: arclith.sh config restore <backup-id> [--yes]'; return 2; fi
      ;;
    uninstall)
      if (( $# == 2 )); then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_uninstall_component "$root" "$home" "$2" confirm
      elif (( $# == 3 )) && [[ $3 == --dry-run ]]; then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_uninstall_component "$root" "$home" "$2" preview
      elif (( $# == 3 )) && [[ $3 == --yes ]]; then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_uninstall_component "$root" "$home" "$2" yes
      else config_error 'Usage: arclith.sh config uninstall <component> [--dry-run|--yes]'; return 2; fi
      ;;
    prune)
      if (( $# == 2 )); then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_uninstall_component "$root" "$(cd -- "$home" && pwd -P)" "$2" confirm stale-only
      elif (( $# == 3 )) && [[ $3 == --dry-run ]]; then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_uninstall_component "$root" "$(cd -- "$home" && pwd -P)" "$2" preview stale-only
      elif (( $# == 3 )) && [[ $3 == --yes ]]; then
        [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
        config_uninstall_component "$root" "$(cd -- "$home" && pwd -P)" "$2" yes stale-only
      else config_error 'Usage: arclith.sh config prune <component> [--dry-run|--yes]'; return 2; fi
      ;;
    *) config_error "Unknown config action: $action"; printf 'Usage: arclith.sh config [list|validate|doctor|info <component>|preview <component>|apply <component> [--yes]|apply-new <component> [--dry-run|--yes]|status [component]|updates [component]|backups [component]|artifacts [component]|transactions [transaction-id]|restore <backup-id> [--yes]|uninstall <component> [--dry-run|--yes]|prune <component> [--dry-run|--yes]]\n' >&2; return 2 ;;
  esac
}
