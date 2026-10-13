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

get_operating_system() {
  if [[ -r /etc/os-release ]]; then
    local pretty_name
    pretty_name=$(awk -F= '$1 == "PRETTY_NAME" { sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit }' /etc/os-release)
    value_or_unavailable "$pretty_name"
  else
    printf 'Unavailable\n'
  fi
}

get_cpu() {
  local cpu
  cpu=$(awk -F': *' '/model name/ { print $2; exit }' /proc/cpuinfo 2>/dev/null || true)
  if [[ -z $cpu ]] && command_exists lscpu; then
    cpu=$(lscpu 2>/dev/null | awk -F': *' '/Model name/ { print $2; exit }' || true)
  fi
  value_or_unavailable "$cpu"
}

get_memory() {
  local memory_kib
  memory_kib=$(awk '/MemTotal/ { print $2; exit }' /proc/meminfo 2>/dev/null || true)
  if [[ $memory_kib =~ ^[0-9]+$ ]]; then
    awk -v kib="$memory_kib" 'BEGIN { printf "%.1f GiB\n", kib / 1024 / 1024 }'
  else
    printf 'Unavailable\n'
  fi
}

get_gpu() {
  local gpu
  if ! command_exists lspci; then
    printf 'Unavailable\n'
    return
  fi

  gpu=$(lspci -nn 2>/dev/null | awk '/VGA compatible controller|3D controller|Display controller/ { sub(/^[^:]+: /, ""); print }' || true)
  value_or_unavailable "$gpu"
}

get_storage() {
  local storage
  if command_exists lsblk; then
    storage=$(lsblk -d -n -o NAME,SIZE,MODEL,TYPE 2>/dev/null | awk '$NF == "disk" && $1 !~ /^zram/ { $NF=""; sub(/[[:space:]]+$/, ""); print }' || true)
  fi
  value_or_unavailable "${storage:-}"
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
  local displays
  if ! command_exists timeout; then
    printf 'Unavailable\n'
    return
  fi

  if [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]] && command_exists hyprctl; then
    displays=$(timeout 2 hyprctl monitors 2>/dev/null | awk '/^Monitor / { print $2 }' || true)
  elif [[ -n ${WAYLAND_DISPLAY:-} ]] && command_exists wlr-randr; then
    displays=$(timeout 2 wlr-randr 2>/dev/null | awk '/^[^[:space:]]/ { print $1 }' || true)
  elif [[ -n ${DISPLAY:-} ]] && command_exists xrandr; then
    displays=$(timeout 2 xrandr --query 2>/dev/null | awk '/ connected/ { print $1 }' || true)
  fi
  value_or_unavailable "${displays:-}"
}

collect_hardware_snapshot() {
  HARDWARE_SNAPSHOT=()
  HARDWARE_SNAPSHOT[operating_system]=$(get_operating_system)
  HARDWARE_SNAPSHOT[kernel]=$(uname -r 2>/dev/null || printf 'Unavailable')
  HARDWARE_SNAPSHOT[architecture]=$(uname -m 2>/dev/null || printf 'Unavailable')
  HARDWARE_SNAPSHOT[hostname]=$(hostname 2>/dev/null || printf 'Unavailable')
  HARDWARE_SNAPSHOT[cpu]=$(get_cpu)
  HARDWARE_SNAPSHOT[memory]=$(get_memory)
  HARDWARE_SNAPSHOT[gpu]=$(get_gpu)
  HARDWARE_SNAPSHOT[storage]=$(get_storage)
  HARDWARE_SNAPSHOT[desktop]=$(get_desktop)
  HARDWARE_SNAPSHOT[displays]=$(get_displays)
}

print_json_report() {
  local index

  JSON_RECOMMENDATIONS=1
  print_recommendations \
    "${HARDWARE_SNAPSHOT[architecture]}" \
    "${HARDWARE_SNAPSHOT[desktop]}" \
    "${HARDWARE_SNAPSHOT[gpu]}" \
    "${HARDWARE_SNAPSHOT[displays]}" >/dev/null
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
    return
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
    "${HARDWARE_SNAPSHOT[displays]}"
}

source "$HARDWARE_DIR/recommend.sh"

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
