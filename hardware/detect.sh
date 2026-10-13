#!/usr/bin/env bash
# Read-only system and hardware report. This module must never change the host.
set -Eeuo pipefail
IFS=$'\n\t'

readonly HARDWARE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

print_field() {
  local label="$1:" value="${2:-Unavailable}" line first_line=1

  while IFS= read -r line || [[ -n $line ]]; do
    if (( first_line )); then
      printf '%-24s %s\n' "$label" "$line"
      first_line=0
    else
      printf '%-24s %s\n' '' "$line"
    fi
  done <<< "$value"
}

value_or_unavailable() {
  local value=${1:-}
  printf '%s\n' "${value:-Unavailable}"
}

json_string() {
  local value=$1 char code index
  printf '"'
  for (( index=0; index<${#value}; index++ )); do
    char=${value:index:1}
    case $char in
      '"') printf '\\"' ;;
      '\\') printf '\\\\' ;;
      $'\b') printf '\\b' ;;
      $'\f') printf '\\f' ;;
      $'\n') printf '\\n' ;;
      $'\r') printf '\\r' ;;
      $'\t') printf '\\t' ;;
      *)
        printf -v code '%d' "'$char"
        if (( code < 32 )); then printf '\\u%04x' "$code"; else printf '%s' "$char"; fi
        ;;
    esac
  done
  printf '"'
}

json_value() {
  if [[ -z $1 || $1 == Unavailable ]]; then printf 'null'; else json_string "$1"; fi
}

RECOMMENDATION_STATUSES=()
RECOMMENDATION_MESSAGES=()
JSON_RECOMMENDATIONS=0
declare -A HARDWARE_SNAPSHOT=()
HARDWARE_PROBE_FAILURES=0
DETECTED_OS_PRETTY_NAME=Unavailable
DETECTED_OS_ID=Unavailable
DETECTED_OS_LIKE=Unavailable

hardware_probe_error() {
  printf '[WARN] Hardware probe failed: %s\n' "$*" >&2
}

get_operating_system() {
  local os_values status
  DETECTED_OS_PRETTY_NAME=Unavailable
  DETECTED_OS_ID=Unavailable
  DETECTED_OS_LIKE=Unavailable
  if os_values=$(read_os_metadata); then
    IFS=$'\t' read -r DETECTED_OS_PRETTY_NAME DETECTED_OS_ID DETECTED_OS_LIKE <<< "$os_values"
    DETECTED_OS_PRETTY_NAME=${DETECTED_OS_PRETTY_NAME:-Unavailable}
    DETECTED_OS_ID=${DETECTED_OS_ID:-Unavailable}
    DETECTED_OS_LIKE=${DETECTED_OS_LIKE:-Unavailable}
    return 0
  else
    status=$?
    if (( status == 2 )); then return 0; fi
    if [[ ! -r /etc/os-release ]]; then
      hardware_probe_error 'cannot read /etc/os-release (permission denied or inaccessible)'
    else
      hardware_probe_error 'could not parse /etc/os-release with awk'
    fi
    return 1
  fi
}

get_cpu() {
  local cpu status
  if [[ ! -r /proc/cpuinfo ]]; then
    if [[ -e /proc/cpuinfo ]]; then
      hardware_probe_error 'cannot read /proc/cpuinfo (permission denied or inaccessible)'
      return 1
    fi
    cpu=''
  elif ! cpu=$(awk -F': *' '/model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null); then
    hardware_probe_error 'could not read CPU information from /proc/cpuinfo with awk'
    return 1
  fi
  if [[ -z $cpu ]] && command_exists lscpu; then
    if ! cpu=$(lscpu 2>/dev/null | awk -F': *' '/Model name/ { print $2; exit }'); then
      hardware_probe_error 'lscpu failed while reading CPU information'
      return 1
    fi
  fi
  value_or_unavailable "$cpu"
}

get_memory() {
  local memory_kib
  if [[ ! -r /proc/meminfo ]]; then
    if [[ -e /proc/meminfo ]]; then
      hardware_probe_error 'cannot read /proc/meminfo (permission denied or inaccessible)'
      return 1
    fi
    printf 'Unavailable\n'
    return
  fi
  if ! memory_kib=$(awk '/MemTotal/ { print $2; exit }' /proc/meminfo 2>/dev/null); then
    hardware_probe_error 'could not read memory information from /proc/meminfo with awk'
    return 1
  fi
  if [[ $memory_kib =~ ^[0-9]+$ ]]; then
    if ! awk -v kib="$memory_kib" 'BEGIN { printf "%.1f GiB\n", kib / 1024 / 1024 }'; then
      hardware_probe_error 'could not format memory information with awk'
      return 1
    fi
  else
    printf 'Unavailable\n'
  fi
}

get_gpu() {
  local gpu raw status
  if ! command_exists lspci; then
    printf 'Unavailable\n'
    return
  fi

  if raw=$(lspci -nn 2>/dev/null); then
    if ! gpu=$(printf '%s\n' "$raw" | awk '/VGA compatible controller|3D controller|Display controller/ { sub(/^[^:]+: /, ""); print }'); then
      hardware_probe_error 'could not parse lspci output with awk'
      return 1
    fi
  else
    status=$?
    hardware_probe_error "lspci exited with status $status; check utility access or permissions; GPU results were discarded"
    return 1
  fi
  value_or_unavailable "$gpu"
}

get_storage() {
  local storage raw status
  if ! command_exists lsblk; then
    printf 'Unavailable\n'
    return
  fi
  if raw=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null); then
    if ! storage=$(printf '%s\n' "$raw" | awk '$NF == "disk" && $1 !~ /^zram/ { $NF=""; sub(/[[:space:]]+$/, ""); print }'); then
      hardware_probe_error 'could not parse lsblk output with awk'
      return 1
    fi
  else
    status=$?
    hardware_probe_error "lsblk exited with status $status; check utility access or permissions; storage results were discarded"
    return 1
  fi
  value_or_unavailable "${storage:-}"
}

get_uname_value() {
  local option=$1 label=$2 value status
  if ! command_exists uname; then
    printf 'Unavailable\n'
    return
  fi
  if value=$(uname "$option" 2>/dev/null); then
    value_or_unavailable "$value"
  else
    status=$?
    hardware_probe_error "uname $option failed with status $status while reading $label"
    return 1
  fi
}

get_hostname() {
  local value status
  if ! command_exists hostname; then
    printf 'Unavailable\n'
    return
  fi
  if value=$(hostname 2>/dev/null); then
    value_or_unavailable "$value"
  else
    status=$?
    hardware_probe_error "hostname failed with status $status"
    return 1
  fi
}

get_desktop() {
  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
    printf 'Hyprland\n'
  elif [[ -n ${XDG_CURRENT_DESKTOP:-} ]]; then
    printf '%s\n' "$XDG_CURRENT_DESKTOP"
  elif [[ -n ${DESKTOP_SESSION:-} ]]; then
    printf '%s\n' "$DESKTOP_SESSION"
  else
    printf 'Unavailable\n'
  fi
}

get_displays() {
  local displays raw status
  local -a command=()
  if ! command_exists timeout; then
    printf 'Unavailable\n'
    return
  fi

  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command_exists hyprctl; then
    command=(hyprctl monitors)
  elif [[ -n ${WAYLAND_DISPLAY:-} ]] && command_exists wlr-randr; then
    command=(wlr-randr)
  elif [[ -n ${DISPLAY:-} ]] && command_exists xrandr; then
    command=(xrandr --query)
  else
    printf 'Unavailable\n'
    return
  fi
  if raw=$(timeout 2 "${command[@]}" 2>/dev/null); then
    case ${command[0]} in
      hyprctl)
        if ! displays=$(printf '%s\n' "$raw" | awk '/^Monitor / { print $2 }'); then
          hardware_probe_error 'could not parse hyprctl output with awk'
          return 1
        fi
        ;;
      wlr-randr)
        if ! displays=$(printf '%s\n' "$raw" | awk '/^[^[:space:]]/ { print $1 }'); then
          hardware_probe_error 'could not parse wlr-randr output with awk'
          return 1
        fi
        ;;
      xrandr)
        if ! displays=$(printf '%s\n' "$raw" | awk '/ connected/ { print $1 }'); then
          hardware_probe_error 'could not parse xrandr output with awk'
          return 1
        fi
        ;;
    esac
  else
    status=$?
    if (( status == 124 || status == 137 )); then
      hardware_probe_error "${command[0]} display probe timed out after 2 seconds; partial results were discarded"
    else
      hardware_probe_error "${command[0]} display probe failed with status $status; check the utility and session permissions; partial results were discarded"
    fi
    return 1
  fi
  value_or_unavailable "${displays:-}"
}

collect_snapshot_value() {
  local key=$1 value=''
  local status=0
  case $key in
    operating_system)
      if get_operating_system; then
        HARDWARE_SNAPSHOT[operating_system]=$DETECTED_OS_PRETTY_NAME
        HARDWARE_SNAPSHOT[os_id]=$DETECTED_OS_ID
        HARDWARE_SNAPSHOT[os_like]=$DETECTED_OS_LIKE
        HARDWARE_SNAPSHOT[os_probe_failed]=false
      else
        HARDWARE_SNAPSHOT[operating_system]=Unavailable
        HARDWARE_SNAPSHOT[os_id]=Unavailable
        HARDWARE_SNAPSHOT[os_like]=Unavailable
        HARDWARE_SNAPSHOT[os_probe_failed]=true
        HARDWARE_PROBE_FAILURES=$((HARDWARE_PROBE_FAILURES + 1))
      fi
      return
      ;;
    kernel) value=$(get_uname_value -r kernel) || status=$? ;;
    architecture) value=$(get_uname_value -m architecture) || status=$? ;;
    hostname) value=$(get_hostname) || status=$? ;;
    cpu) value=$(get_cpu) || status=$? ;;
    memory) value=$(get_memory) || status=$? ;;
    gpu) value=$(get_gpu) || status=$? ;;
    storage) value=$(get_storage) || status=$? ;;
    displays) value=$(get_displays) || status=$? ;;
    *) return 2 ;;
  esac
  if (( status == 0 )); then
    HARDWARE_SNAPSHOT[$key]=${value:-Unavailable}
  else
    HARDWARE_SNAPSHOT[$key]=Unavailable
    HARDWARE_PROBE_FAILURES=$((HARDWARE_PROBE_FAILURES + 1))
  fi
}

collect_hardware_snapshot() {
  local key
  HARDWARE_SNAPSHOT=()
  HARDWARE_PROBE_FAILURES=0
  for key in operating_system kernel architecture hostname cpu memory gpu storage displays; do
    collect_snapshot_value "$key"
  done
  HARDWARE_SNAPSHOT[desktop]=$(get_desktop)
}

print_json_report() {
  local index

  JSON_RECOMMENDATIONS=1
  print_recommendations \
    "${HARDWARE_SNAPSHOT[architecture]}" \
    "${HARDWARE_SNAPSHOT[desktop]}" \
    "${HARDWARE_SNAPSHOT[gpu]}" \
    "${HARDWARE_SNAPSHOT[displays]}" \
    "${HARDWARE_SNAPSHOT[os_id]}" \
    "${HARDWARE_SNAPSHOT[os_like]}" \
    "${HARDWARE_SNAPSHOT[os_probe_failed]}" >/dev/null
  JSON_RECOMMENDATIONS=0

  printf '{\n  "system": {\n'
  printf '    "operating_system": '; json_value "${HARDWARE_SNAPSHOT[operating_system]}"; printf ',\n'
  printf '    "kernel": '; json_value "${HARDWARE_SNAPSHOT[kernel]}"; printf ',\n'
  printf '    "architecture": '; json_value "${HARDWARE_SNAPSHOT[architecture]}"; printf ',\n'
  printf '    "hostname": '; json_value "${HARDWARE_SNAPSHOT[hostname]}"; printf '\n  },\n  "hardware": {\n'
  printf '    "cpu": '; json_value "${HARDWARE_SNAPSHOT[cpu]}"; printf ',\n'
  printf '    "memory": '; json_value "${HARDWARE_SNAPSHOT[memory]}"; printf ',\n'
  printf '    "gpu": '; json_value "${HARDWARE_SNAPSHOT[gpu]}"; printf ',\n'
  printf '    "storage_disks": '; json_value "${HARDWARE_SNAPSHOT[storage]}"; printf ',\n'
  printf '    "desktop_compositor": '; json_value "${HARDWARE_SNAPSHOT[desktop]}"; printf ',\n'
  printf '    "displays": '; json_value "${HARDWARE_SNAPSHOT[displays]}"; printf '\n  },\n  "recommendations": ['
  for (( index=0; index<${#RECOMMENDATION_STATUSES[@]}; index++ )); do
    (( index == 0 )) || printf ','
    printf '\n    {"status": '
    json_string "${RECOMMENDATION_STATUSES[index]}"
    printf ', "message": '
    json_string "${RECOMMENDATION_MESSAGES[index]}"
    printf '}'
  done
  if (( ${#RECOMMENDATION_STATUSES[@]} )); then printf '\n  '; fi
  printf ']\n}\n'
}

main() {
  if (( $# == 1 )) && [[ $1 == --json ]]; then
    collect_hardware_snapshot
    print_json_report
    return "$(( HARDWARE_PROBE_FAILURES > 0 ))"
  elif (( $# > 0 )); then
    printf 'Usage: %s [--json]\n' "${0##*/}" >&2
    printf '[ERROR] Unsupported hardware option: %s\n' "$1" >&2
    return 2
  fi
  collect_hardware_snapshot
  printf 'ARCLITH Hardware Report (read-only)\n\n'
  print_field 'Operating system' "${HARDWARE_SNAPSHOT[operating_system]}"
  print_field 'Kernel' "${HARDWARE_SNAPSHOT[kernel]}"
  print_field 'Architecture' "${HARDWARE_SNAPSHOT[architecture]}"
  print_field 'Hostname' "${HARDWARE_SNAPSHOT[hostname]}"
  print_field 'CPU' "${HARDWARE_SNAPSHOT[cpu]}"
  print_field 'Memory' "${HARDWARE_SNAPSHOT[memory]}"
  print_field 'GPU' "${HARDWARE_SNAPSHOT[gpu]}"
  print_field 'Storage disks' "${HARDWARE_SNAPSHOT[storage]}"
  print_field 'Desktop/compositor' "${HARDWARE_SNAPSHOT[desktop]}"
  print_field 'Displays' "${HARDWARE_SNAPSHOT[displays]}"
  printf '\n'
  print_recommendations \
    "${HARDWARE_SNAPSHOT[architecture]}" \
    "${HARDWARE_SNAPSHOT[desktop]}" \
    "${HARDWARE_SNAPSHOT[gpu]}" \
    "${HARDWARE_SNAPSHOT[displays]}" \
    "${HARDWARE_SNAPSHOT[os_id]}" \
    "${HARDWARE_SNAPSHOT[os_like]}" \
    "${HARDWARE_SNAPSHOT[os_probe_failed]}"
  return "$(( HARDWARE_PROBE_FAILURES > 0 ))"
}

source "$HARDWARE_DIR/recommend.sh"

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
