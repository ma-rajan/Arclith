#!/usr/bin/env bash
# Configuration discovery, validation, preview, and guarded deployment.
# Registry entries are parsed as data; source files are never executed.

CONFIG_COMPONENT_NAMES=()
declare -A CONFIG_DESCRIPTIONS=()
declare -A CONFIG_SOURCES=()
declare -A CONFIG_TARGETS=()
declare -A CONFIG_ENABLED=()

config_error() { printf '[ERROR] %s\n' "$*" >&2; }

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
  local root=$1 name status failed=0
  config_load_registry "$root" || return 1
  for name in "${CONFIG_COMPONENT_NAMES[@]}"; do
    status=$(config_source_status "$root" "$name")
    case $status in
      available) printf '%s: valid (source available)\n' "$name" ;;
      unavailable) printf '%s: unavailable (source directory missing or unreadable: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      unsafe-symlink) printf '%s: invalid (source path contains a symlink: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      unsafe-entry) printf '%s: invalid (source contains an unsupported filesystem entry: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      unreadable) printf '%s: invalid (source contains unreadable paths: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
      empty-source) printf '%s: unavailable (source directory contains no configuration files: %s)\n' "$name" "${CONFIG_SOURCES[$name]}"; failed=1 ;;
    esac
  done
  (( failed == 0 ))
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
  local root=$1 name=$2 source source_dir relative target home target_rel target_parent status found=0 invalid=0
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
  [[ -e $registry ]] || return 0
  if [[ -L $registry || ! -f $registry || ! -r $registry || $(stat -c '%u' -- "$registry") != "$EUID" ]]; then
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

config_state_set_managed() {
  local name=$1 target=$2 digest=$3 i
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

config_state_add_backup() {
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

config_state_status() {
  local root=$1 home=$2 filter=${3:-} i path status digest shown=0 parent relative
  config_load_registry "$root" || return 1
  [[ -z $filter ]] || config_component_exists "$filter" || { config_error "Unknown configuration component: $filter"; return 2; }
  config_state_load "$home" || return 1
  printf 'Arclith deployment state (manifest validated):\n'
  for i in "${!CONFIG_STATE_MANAGED_TARGETS[@]}"; do
    [[ -z $filter || ${CONFIG_STATE_MANAGED_COMPONENTS[i]} == "$filter" ]] || continue
    relative=${CONFIG_STATE_MANAGED_TARGETS[i]}
    path="$home/$relative"
    parent=${relative%/*}
    [[ $parent == "$relative" ]] && parent=
    if config_path_has_symlink "$home" "${CONFIG_STATE_MANAGED_TARGETS[i]}" \
      || { [[ -n $parent ]] && config_path_has_non_directory_ancestor "$home" "$parent"; } \
      || [[ -L $path || ( -e $path && ! -f $path ) ]]; then
      status=unsafe
    elif [[ ! -f $path ]]; then
      status=missing
    else
      digest=$(config_file_hash "$path")
      if [[ $digest == "${CONFIG_STATE_MANAGED_HASHES[i]}" ]]; then status=unchanged; else status=modified; fi
    fi
    printf '%s  %s  %s\n' "${CONFIG_STATE_MANAGED_COMPONENTS[i]}" "${CONFIG_STATE_MANAGED_TARGETS[i]}" "$status"
    ((shown += 1))
  done
  (( shown > 0 )) || printf 'No managed configuration files.\n'
}

config_restore_backup() {
  local root=$1 home=$2 selected_id=$3 confirm_all=$4 i selected=-1 backup status target relative parent
  local reply staged current_backup current_id current_hash restored_hash installed_id failed=0 existed=no collision attempt i
  local original_mode original_group
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
    [[ -n $current_backup ]] || { config_error 'Could not allocate a unique backup identifier'; return 1; }
    if ! cp -p -- "$target" "$current_backup" || ! chmod 600 -- "$current_backup"; then
      rm -f -- "$current_backup"
      config_error "Could not preserve current target: $target"
      return 1
    fi
    current_hash=$(config_file_hash "$current_backup")
  else
    printf '  current target: absent (restore will create it)\n'
    current_backup=
    current_id=
    current_hash=
    original_mode=
    original_group=
  fi

  staged=$(mktemp "${target}.arclith-restore.XXXXXXXX") || { [[ -z $current_backup ]] || rm -f -- "$current_backup"; return 1; }
  if ! cp -- "$backup" "$staged" \
    || ! chmod "${CONFIG_STATE_BACKUP_MODES[selected]}" -- "$staged" \
    || ! chgrp "${CONFIG_STATE_BACKUP_GROUPS[selected]}" -- "$staged"; then
    rm -f -- "$staged"
    [[ -z $current_backup ]] || rm -f -- "$current_backup"
    config_error 'Could not stage the selected backup'
    return 1
  fi
  if [[ -e $target ]] && ! cmp -s -- "$target" "$current_backup"; then
    rm -f -- "$staged" "$current_backup"
    config_error 'Target changed during restore; refusing to replace it'
    return 1
  elif [[ $existed == no && -e $target ]]; then
    rm -f -- "$staged"
    config_error 'Target appeared during restore; refusing to replace it'
    return 1
  fi
  if [[ -L $backup || ! -f $backup || $(config_file_hash "$backup") != "${CONFIG_STATE_BACKUP_HASHES[selected]}" ]] \
    || { [[ -n $parent ]] && config_path_has_symlink "$home" "$parent"; } \
    || [[ -L $target || ( $existed == no && -e $target ) || ( $existed == yes && ! -f $target ) ]] \
    || { [[ $existed == yes ]] && ! cmp -s -- "$target" "$current_backup"; }; then
    rm -f -- "$staged"
    [[ -z $current_backup ]] || rm -f -- "$current_backup"
    config_error 'Backup or restore target changed during restore; refusing to continue'
    return 1
  fi

  if mv -T -- "$staged" "$target"; then
    installed_id=$(stat -c '%d:%i' -- "$target")
    printf 'Restored: %s\n' "$relative"
  else
    if [[ ! -e $staged && -f $target && ! -L $target ]]; then installed_id=$(stat -c '%d:%i' -- "$target"); else installed_id=; fi
    config_error "Restore failed: $target"
    failed=1
  fi
  if (( ! failed )); then
    restored_hash=$(config_file_hash "$target")
    config_state_set_managed "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$restored_hash"
    if [[ $existed == yes ]]; then
      config_state_add_backup "$current_id" "${CONFIG_STATE_BACKUP_COMPONENTS[selected]}" "$relative" "$current_hash" "$original_mode" "$original_group"
    fi
    if ! config_state_save "$home"; then
      config_error 'Restore completed but state could not be saved; attempting rollback'
      failed=1
    fi
  fi
  if (( failed )); then
    if [[ -n $installed_id && -f $target && ! -L $target && $(stat -c '%d:%i' -- "$target") == "$installed_id" ]]; then
      if [[ $existed == yes ]]; then
        staged=$(mktemp "${target}.arclith-rollback.XXXXXXXX") || return 1
        if cp -p -- "$current_backup" "$staged" && chmod "$original_mode" -- "$staged" && chgrp "$original_group" -- "$staged" && mv -T -- "$staged" "$target"; then
          printf 'Rollback restored the prior target.\n'
        else
          rm -f -- "$staged"
          config_error "Rollback failed; prior target backup remains at $current_backup"
          return 1
        fi
      elif ! rm -f -- "$target"; then
        config_error "Rollback failed; restored file remains at $target"
        return 1
      fi
    fi
    return 1
  fi
  [[ -z $current_backup ]] || printf 'Current target backup: %s\n' "$current_backup"
  printf 'Success: backup %s restored.\n' "$selected_id"
}

config_apply() {
  local root=$1 name=$2 confirm_all=$3 source source_dir target home status relative target_rel target_path parent
  local reply backup staged old_umask failed=0 rollback_failed=0 index target_changed parent_rel backup_id collision attempt i
  local -a files=() sources=() targets=() existed=() backups=() staged_files=() committed=() original_modes=() original_groups=() installed_ids=()
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

  if (( conflicts > 0 )) && [[ $confirm_all != yes ]]; then
    printf 'This will replace %d existing file(s). Recoverable backups will be created beside them. Continue? [y/N]: ' "$conflicts" >&2
    if ! IFS= read -r reply || [[ ! $reply =~ ^([yY]|[yY][eE][sS])$ ]]; then
      printf 'Skipped: no files were changed.\n'
      return 1
    fi
  fi

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
    fi
    staged=$(mktemp "${target_path}.arclith-new.XXXXXXXX") || { failed=1; break; }
    staged_files[index]=$staged
    if ! cp -- "${sources[index]}" "$staged" || ! chmod 600 -- "$staged"; then
      config_error "Could not stage source file: ${sources[index]}"
      failed=1
      break
    fi
  done
  if (( failed )); then
    for staged in "${staged_files[@]}"; do [[ -z $staged ]] || rm -f -- "$staged"; done
    printf 'Failed: no target files were replaced. Any created backups were preserved.\n'
    return 1
  fi

  # Recheck immediately before each atomic rename, and roll back committed files
  # if any later rename or check fails.
  for index in "${!targets[@]}"; do
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
    if mv -T -- "${staged_files[index]}" "$target_path"; then
      committed+=("$index")
      installed_ids+=("$(stat -c '%d:%i' -- "$target_path")")
      staged_files[index]=
      printf 'Applied: %s\n' "$relative"
    else
      # A wrapper or filesystem can report failure after completing a rename.
      if [[ ! -e ${staged_files[index]} && -f $target_path && ! -L $target_path ]]; then
        committed+=("$index")
        installed_ids+=("$(stat -c '%d:%i' -- "$target_path")")
      fi
      config_error "Failed to install: $target_path"
      failed=1
      break
    fi
  done

  if (( ! failed )); then
    for index in "${!targets[@]}"; do
      relative=${targets[index]#"$home"/}
      config_state_set_managed "$name" "$relative" "$(config_file_hash "${targets[index]}")" || { failed=1; break; }
      if [[ -n ${backups[index]} ]]; then
        backup_id=${backups[index]##*.arclith-backup.}
        config_state_add_backup "$backup_id" "$name" "$relative" "$(config_file_hash "${backups[index]}")" "${original_modes[index]}" "${original_groups[index]}"
      fi
    done
  fi
  if (( ! failed )) && ! config_state_save "$home"; then
    config_error 'Deployment succeeded but state could not be saved; rolling the deployed files back'
    failed=1
  fi

  if (( failed )); then
    for staged in "${staged_files[@]}"; do [[ -z $staged ]] || rm -f -- "$staged"; done
    for (( index=${#committed[@]}-1; index>=0; index-- )); do
      local committed_index=${committed[index]}
      target_path=${targets[committed_index]}
      if [[ -L $target_path || ! -f $target_path || $(stat -c '%d:%i' -- "$target_path") != "${installed_ids[index]}" ]]; then
        config_error "Rollback skipped because the target changed after deployment: $target_path"
        rollback_failed=1
        continue
      fi
      if [[ ${existed[committed_index]} == yes ]]; then
        staged=$(mktemp "${target_path}.arclith-restore.XXXXXXXX") || { rollback_failed=1; continue; }
        if cp -p -- "${backups[committed_index]}" "$staged" && chmod "${original_modes[committed_index]}" -- "$staged" && chgrp "${original_groups[committed_index]}" -- "$staged" && mv -T -- "$staged" "$target_path"; then
          printf 'Restored: %s\n' "${target_path#"$home"/}"
        else
          rm -f -- "$staged"
          config_error "Rollback failed; recoverable backup remains at ${backups[committed_index]}"
          rollback_failed=1
        fi
      elif [[ -f $target_path && ! -L $target_path ]]; then
        if rm -f -- "$target_path"; then printf 'Rolled back new file: %s\n' "${target_path#"$home"/}"; else rollback_failed=1; fi
      fi
    done
    (( rollback_failed == 0 )) || config_error 'One or more rollback operations failed; inspect the reported backups'
    printf 'Failed: deployment rolled back where possible. Backups are retained.\n'
    return 1
  fi

  for index in "${!backups[@]}"; do
    [[ -z ${backups[index]} ]] || printf 'Backup: %s\n' "${backups[index]}"
  done
  printf 'Success: configuration component %s applied.\n' "$name"
}

config_main() {
  local action=${1:-list}
  local root="$PROJECT_ROOT"
  local home=${HOME:-}
  case $action in
    list) (( $# <= 1 )) || { config_error 'Usage: arclith.sh config list'; return 2; }; config_list "$root" ;;
    validate) (( $# == 1 )) || { config_error 'Usage: arclith.sh config validate'; return 2; }; config_validate_registry "$root" ;;
    info) (( $# == 2 )) || { config_error 'Usage: arclith.sh config info <component>'; return 2; }; config_info "$root" "$2" ;;
    preview) (( $# == 2 )) || { config_error 'Usage: arclith.sh config preview <component>'; return 2; }; config_preview "$root" "$2" ;;
    apply)
      if (( $# == 2 )); then config_apply "$root" "$2" no
      elif (( $# == 3 )) && [[ $3 == --yes ]]; then config_apply "$root" "$2" yes
      else config_error 'Usage: arclith.sh config apply <component> [--yes]'; return 2; fi
      ;;
    backups)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config backups [component]'; return 2; }
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_backup_list "$root" "$home" "$2"
      else config_backup_list "$root" "$home"; fi
      ;;
    status)
      (( $# <= 2 )) || { config_error 'Usage: arclith.sh config status [component]'; return 2; }
      [[ $home == /* && ! -L $home && -d $home ]] || { config_error 'HOME must be an existing absolute, non-symlink directory'; return 1; }
      home=$(cd -- "$home" && pwd -P)
      if [[ -n ${2:-} ]]; then config_state_status "$root" "$home" "$2"
      else config_state_status "$root" "$home"; fi
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
    *) config_error "Unknown config action: $action"; printf 'Usage: arclith.sh config [list|validate|info <component>|preview <component>|apply <component> [--yes]|status [component]|backups [component]|restore <backup-id> [--yes]]\n' >&2; return 2 ;;
  esac
}
