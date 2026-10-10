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

config_apply() {
  local root=$1 name=$2 confirm_all=$3 source source_dir target home status relative target_rel target_path parent
  local reply backup staged old_umask failed=0 rollback_failed=0 index target_changed parent_rel
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
      backup=$(mktemp "${target_path}.arclith-backup.XXXXXXXX") || { failed=1; break; }
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
    *) config_error "Unknown config action: $action"; printf 'Usage: arclith.sh config [list|validate|info <component>|preview <component>|apply <component> [--yes]]\n' >&2; return 2 ;;
  esac
}
