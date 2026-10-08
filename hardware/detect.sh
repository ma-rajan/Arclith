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

main() {
  printf 'ARCLITH Hardware Report (read-only)\n\n'
  print_field 'Operating system' "$(get_operating_system)"
  print_field 'Kernel' "$(uname -r 2>/dev/null || printf 'Unavailable')"
  print_field 'Architecture' "$(uname -m 2>/dev/null || printf 'Unavailable')"
  print_field 'Hostname' "$(hostname 2>/dev/null || printf 'Unavailable')"
  print_field 'CPU' "$(get_cpu)"
  print_field 'Memory' "$(get_memory)"
  print_field 'GPU' "$(get_gpu)"
  print_field 'Storage disks' "$(get_storage)"
  print_field 'Desktop/compositor' "$(get_desktop)"
  print_field 'Displays' "$(get_displays)"
  printf '\n'
  print_recommendations
}

source "$HARDWARE_DIR/recommend.sh"

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
