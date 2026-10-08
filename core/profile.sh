#!/usr/bin/env bash
# Read-only profile discovery and validation helpers.

PROFILE_ERRORS=()
PROFILE_NAME=""
PROFILE_DESCRIPTION=""
PROFILE_VERSION=""
PROFILE_PACKAGES=""

profile_add_error() {
  PROFILE_ERRORS+=("$1")
}

profile_trim() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

profile_validate() {
  local name=$1
  local profile_dir="$PROJECT_ROOT/profiles/$name"
  local manifest="$profile_dir/profile.conf"
  local line key value line_number=0
  local packages_file package package_line package_number
  local -A fields=() seen_packages=() seen_references=()
  local reference
  PROFILE_ERRORS=()
  PROFILE_NAME=""
  PROFILE_DESCRIPTION=""
  PROFILE_VERSION=""
  PROFILE_PACKAGES=""

  if [[ ! "$name" =~ ^[a-z][a-z0-9_-]*$ ]]; then
    profile_add_error "Invalid profile name '$name'; use lowercase letters, digits, '_' or '-' and start with a letter."
    return 1
  fi
  if [[ ! -d "$profile_dir" ]]; then
    profile_add_error "Profile directory does not exist: profiles/$name"
    return 1
  fi
  if [[ ! -f "$manifest" || ! -r "$manifest" ]]; then
    profile_add_error "Manifest is missing or unreadable: profiles/$name/profile.conf"
    return 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    line=$(profile_trim "$line")
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" != *=* ]]; then
      profile_add_error "profiles/$name/profile.conf:$line_number: expected key=value."
      continue
    fi
    key=$(profile_trim "${line%%=*}")
    value=$(profile_trim "${line#*=}")
    if [[ ! "$key" =~ ^[a-z_]+$ ]]; then
      profile_add_error "profiles/$name/profile.conf:$line_number: invalid field name '$key'."
      continue
    fi
    case "$key" in
      name|description|version|packages) ;;
      *) profile_add_error "profiles/$name/profile.conf:$line_number: unknown field '$key'."; continue ;;
    esac
    if [[ -n "${fields[$key]+set}" ]]; then
      profile_add_error "profiles/$name/profile.conf:$line_number: duplicate field '$key'."
      continue
    fi
    fields[$key]=$value
  done < "$manifest"

  for key in name description version packages; do
    if [[ -z "${fields[$key]+set}" || -z "${fields[$key]}" ]]; then
      profile_add_error "profiles/$name/profile.conf: required field '$key' is missing or empty."
    fi
  done

  PROFILE_NAME=${fields[name]-}
  PROFILE_DESCRIPTION=${fields[description]-}
  PROFILE_VERSION=${fields[version]-}
  PROFILE_PACKAGES=${fields[packages]-}

  if [[ -n "$PROFILE_NAME" && "$PROFILE_NAME" != "$name" ]]; then
    profile_add_error "profiles/$name/profile.conf: name '$PROFILE_NAME' does not match directory '$name'."
  fi
  if [[ -n "$PROFILE_VERSION" && ! "$PROFILE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    profile_add_error "profiles/$name/profile.conf: version '$PROFILE_VERSION' must use numeric major.minor.patch format."
  fi

  if [[ -n "$PROFILE_PACKAGES" ]]; then
    local -a references
    IFS=',' read -r -a references <<< "$PROFILE_PACKAGES"
    for reference in "${references[@]}"; do
      reference=$(profile_trim "$reference")
      if [[ ! "$reference" =~ ^packages/[A-Za-z0-9._-]+\.txt$ ]]; then
        profile_add_error "profiles/$name/profile.conf: invalid package reference '$reference'; expected packages/<file>.txt."
        continue
      fi
      if [[ -n "${seen_references[$reference]+set}" ]]; then
        profile_add_error "profiles/$name/profile.conf: duplicate package reference '$reference'."
        continue
      fi
      seen_references[$reference]=1
      packages_file="$PROJECT_ROOT/$reference"
      if [[ ! -f "$packages_file" || ! -r "$packages_file" ]]; then
        profile_add_error "profiles/$name/profile.conf: referenced package file does not exist or is unreadable: $reference"
        continue
      fi
      package_number=0
      while IFS= read -r package_line || [[ -n "$package_line" ]]; do
        ((package_number += 1))
        package=$(profile_trim "${package_line%%#*}")
        [[ -z "$package" ]] && continue
        if [[ ! "$package" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
          profile_add_error "$reference:$package_number: invalid package entry '$package'."
          continue
        fi
        if [[ -n "${seen_packages[$package]+set}" ]]; then
          profile_add_error "$reference:$package_number: duplicate package '$package' (already listed in ${seen_packages[$package]})."
          continue
        fi
        seen_packages[$package]=$reference
      done < "$packages_file"
    done
  fi

  (( ${#PROFILE_ERRORS[@]} == 0 ))
}

profile_discover() {
  local dir name
  local found=0
  for dir in "$PROJECT_ROOT/profiles"/*; do
    [[ -d "$dir" ]] || continue
    name=${dir##*/}
    printf '%s\n' "$name"
    found=1
  done
  (( found == 1 ))
}

profile_list() {
  local name description status
  local -a names=()
  while IFS= read -r name; do names+=("$name"); done < <(profile_discover || true)
  if (( ${#names[@]} == 0 )); then
    printf 'No profiles found in %s.\n' "$PROJECT_ROOT/profiles" >&2
    return 1
  fi
  printf 'Available Profiles\n\n'
  for name in "${names[@]}"; do
    if profile_validate "$name"; then
      description=$PROFILE_DESCRIPTION
      status='valid'
    else
      description='Description unavailable'
      status='invalid'
    fi
    printf '  %-12s %s [%s]\n' "$name" "$description" "$status"
  done
}

profile_validate_command() {
  local name failed=0
  local -a names=()
  if (( $# > 1 )); then
    printf 'Usage: ./arclith.sh profile validate [name]\n' >&2
    return 2
  fi
  if (( $# == 1 )); then
    names=("$1")
  else
    while IFS= read -r name; do names+=("$name"); done < <(profile_discover || true)
  fi
  if (( ${#names[@]} == 0 )); then
    printf 'No profiles found in %s.\n' "$PROJECT_ROOT/profiles" >&2
    return 1
  fi
  for name in "${names[@]}"; do
    if profile_validate "$name"; then
      printf '  %s: valid\n' "$name"
    else
      failed=1
      printf '  %s: invalid\n' "$name"
      printf '    - %s\n' "${PROFILE_ERRORS[@]}"
    fi
  done
  return "$failed"
}

profile_info() {
  local name=$1
  if profile_validate "$name"; then
    printf 'Profile: %s\nDescription: %s\nVersion: %s\nPackage files: %s\nValidation: valid\n' \
      "$PROFILE_NAME" "$PROFILE_DESCRIPTION" "$PROFILE_VERSION" "$PROFILE_PACKAGES"
    return 0
  fi
  printf 'Profile: %s\nValidation: invalid\n' "$name"
  printf '  - %s\n' "${PROFILE_ERRORS[@]}" >&2
  return 1
}

profile_command() {
  local action=${1-}
  if (( $# > 0 )); then shift; fi
  case "$action" in
    list)
      (( $# == 0 )) || { printf 'Usage: ./arclith.sh profile list\n' >&2; return 2; }
      profile_list
      ;;
    validate)
      profile_validate_command "$@"
      ;;
    info)
      (( $# == 1 )) || { printf 'Usage: ./arclith.sh profile info <name>\n' >&2; return 2; }
      profile_info "$1"
      ;;
    *)
      printf 'Usage: ./arclith.sh profile {list|validate [name]|info <name>}\n' >&2
      return 2
      ;;
  esac
}
