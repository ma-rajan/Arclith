#!/usr/bin/env bash
set -euo pipefail

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

os_name() {
  local os_release="/etc/os-release"
  local line=""
  local pretty_name=""
  local name=""
  local value=""

  if [[ ! -r "$os_release" ]]; then
    printf 'Unavailable'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      PRETTY_NAME=*)
        pretty_name=${line#PRETTY_NAME=}
        ;;
      NAME=*)
        name=${line#NAME=}
        ;;
    esac
  done < "$os_release"

  value=${pretty_name:-$name}
  if [[ -z "$value" ]]; then
    printf 'Unavailable'
    return 0
  fi

  if [[ ${value:0:1} == '"' && ${value: -1} == '"' ]]; then
    value=${value:1:${#value}-2}
  fi

  printf '%s' "$value"
}

uname_value() {
  local option=$1
  local value=""

  if command_exists uname && value=$(uname "$option" 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'Unavailable'
  fi
}

hostname_value() {
  local value=""

  if command_exists hostname && value=$(hostname 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'Unavailable'
  fi
}

print_system_information() {
  printf 'System\n'
  printf '  OS           %s\n' "$(os_name)"
  printf '  Kernel       %s\n' "$(uname_value -r)"
  printf '  Architecture %s\n' "$(uname_value -m)"
  printf '  Hostname     %s\n' "$(hostname_value)"
}

trim_value() {
  local value=$1

  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s' "$value"
}

cpu_model() {
  local cpuinfo="/proc/cpuinfo"
  local line=""
  local model=""
  local fallback=""
  local value=""

  if [[ ! -r "$cpuinfo" ]]; then
    printf 'Unavailable'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      model\ name*:*|Model\ name*:*)
        value=$(trim_value "${line#*:}")
        if [[ -n "$value" ]]; then
          model=$value
          break
        fi
        ;;
      Hardware*:*|Processor*:*)
        if [[ -z "$fallback" ]]; then
          fallback=$(trim_value "${line#*:}")
        fi
        ;;
    esac
  done < "$cpuinfo"

  value=${model:-$fallback}
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    printf 'Unavailable'
  fi
}

logical_cpu_count() {
  local cpuinfo="/proc/cpuinfo"
  local line=""
  local count=0

  if [[ ! -r "$cpuinfo" ]]; then
    printf 'Unavailable'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^processor[[:space:]]*: ]]; then
      ((count += 1))
    fi
  done < "$cpuinfo"

  if (( count > 0 )); then
    printf '%s' "$count"
  else
    printf 'Unavailable'
  fi
}

print_cpu_information() {
  printf '\nCPU\n'
  printf '  Model        %s\n' "$(cpu_model)"
  printf '  Logical CPUs %s\n' "$(logical_cpu_count)"
}

meminfo_kib() {
  local meminfo="/proc/meminfo"
  local field=$1
  local line=""
  local value=""

  if [[ ! -r "$meminfo" ]]; then
    printf 'Unavailable'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$field":* ]]; then
      value=$(trim_value "${line#*:}")
      value=${value%%[!0-9]*}

      if [[ "$value" =~ ^[0-9]+$ ]]; then
        printf '%s' "$value"
      else
        printf 'Unavailable'
      fi
      return 0
    fi
  done < "$meminfo"

  printf 'Unavailable'
}

format_memory_kib() {
  local kib=$1
  local mib_whole=0
  local mib_tenth=0

  if [[ ! "$kib" =~ ^[0-9]+$ ]]; then
    printf 'Unavailable'
    return 0
  fi

  mib_whole=$((kib / 1024))
  mib_tenth=$(((kib % 1024) * 10 / 1024))
  printf '%d.%d MiB' "$mib_whole" "$mib_tenth"
}

print_memory_information() {
  printf '\nMemory\n'
  printf '  Total        %s\n' "$(format_memory_kib "$(meminfo_kib MemTotal)")"
  printf '  Available    %s\n' "$(format_memory_kib "$(meminfo_kib MemAvailable)")"
}

root_df_value() {
  local column=$1
  local output=""
  local line=""
  local line_number=0
  local source=""
  local size=""
  local used=""
  local available=""
  local capacity=""
  local target=""
  local value=""

  if ! command_exists df || ! output=$(LC_ALL=C df -P -k / 2>/dev/null); then
    printf 'Unavailable'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((line_number += 1))
    if (( line_number == 1 )); then
      continue
    fi

    IFS=$' \t' read -r source size used available capacity target <<< "$line"
    if [[ "$target" != "/" ]]; then
      continue
    fi

    case "$column" in
      source) value=$source ;;
      size) value=$size ;;
      used) value=$used ;;
      available) value=$available ;;
      *) printf 'Unavailable'; return 0 ;;
    esac

    if [[ -n "$value" ]]; then
      printf '%s' "$value"
    else
      printf 'Unavailable'
    fi
    return 0
  done <<< "$output"

  printf 'Unavailable'
}

root_filesystem() {
  local value=""

  if command_exists findmnt && value=$(findmnt -n -o SOURCE --target / 2>/dev/null) && [[ -n "$value" ]]; then
    printf '%s' "$value"
  else
    root_df_value source
  fi
}

format_storage_kib() {
  local kib=$1
  local whole=0
  local tenth=0

  if [[ ! "$kib" =~ ^[0-9]+$ ]]; then
    printf 'Unavailable'
    return 0
  fi

  if (( kib >= 1048576 )); then
    whole=$((kib / 1048576))
    tenth=$(((kib % 1048576) * 10 / 1048576))
    printf '%d.%d GiB' "$whole" "$tenth"
  else
    whole=$((kib / 1024))
    tenth=$(((kib % 1024) * 10 / 1024))
    printf '%d.%d MiB' "$whole" "$tenth"
  fi
}

print_storage_information() {
  printf '\nStorage\n'
  printf '  Root         %s\n' "$(root_filesystem)"
  printf '  Size         %s\n' "$(format_storage_kib "$(root_df_value size)")"
  printf '  Used         %s\n' "$(format_storage_kib "$(root_df_value used)")"
  printf '  Available    %s\n' "$(format_storage_kib "$(root_df_value available)")"
}

network_interface_state() {
  local interface_path=$1
  local operstate_file="$interface_path/operstate"
  local state=""

  if [[ ! -r "$operstate_file" ]] || ! IFS= read -r state < "$operstate_file" || [[ -z "$state" ]]; then
    printf 'Unavailable'
    return 0
  fi

  printf '%s' "${state^^}"
}

print_network_information() {
  local network_directory="/sys/class/net"
  local interface_path=""
  local interface_name=""
  local interface_count=0

  printf '\nNetwork\n'
  if [[ ! -d "$network_directory" ]]; then
    printf '  Unavailable\n'
    return 0
  fi

  for interface_path in "$network_directory"/*; do
    [[ -e "$interface_path" ]] || continue

    if (( interface_count > 0 )); then
      printf '\n'
    fi

    interface_name=${interface_path##*/}
    printf '  Interface    %s\n' "$interface_name"
    printf '  State        %s\n' "$(network_interface_state "$interface_path")"
    ((interface_count += 1))
  done

  if (( interface_count == 0 )); then
    printf '  Unavailable\n'
  fi
}

xrandr_resolution() {
  local connector=$1
  local output=""
  local line=""

  if ! command_exists xrandr || ! output=$(xrandr --query 2>/dev/null); then
    printf 'Unavailable'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "$connector"\ connected* ]] && [[ "$line" =~ [[:space:]]([0-9]+x[0-9]+)(\+[0-9-]+){2} ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done <<< "$output"

  printf 'Unavailable'
}

print_display_information() {
  local drm_directory="/sys/class/drm"
  local connector_path=""
  local connector_entry=""
  local connector_name=""
  local connector_count=0

  printf '\nDisplay\n'
  if [[ ! -d "$drm_directory" ]]; then
    printf '  Unavailable\n'
    return 0
  fi

  for connector_path in "$drm_directory"/*; do
    [[ -e "$connector_path" ]] || continue
    connector_entry=${connector_path##*/}
    [[ "$connector_entry" == card*-* && -r "$connector_path/status" ]] || continue

    if (( connector_count > 0 )); then
      printf '\n'
    fi

    connector_name=${connector_entry#*-}
    printf '  %s\n' "$connector_name"
    printf '    Resolution  %s\n' "$(xrandr_resolution "$connector_name")"
    ((connector_count += 1))
  done

  if (( connector_count == 0 )); then
    printf '  Unavailable\n'
  fi
}

device_type() {
  local chassis_type_file="/sys/class/dmi/id/chassis_type"
  local chassis_type=""

  if command_exists systemd-detect-virt && systemd-detect-virt --quiet >/dev/null 2>&1; then
    printf 'Virtual Machine'
    return 0
  fi

  if [[ ! -r "$chassis_type_file" ]] || ! IFS= read -r chassis_type < "$chassis_type_file"; then
    printf 'Unknown'
    return 0
  fi

  case "$chassis_type" in
    8|9|10|14|31|32)
      printf 'Laptop'
      ;;
    3|4|5|6|7|15|16|35)
      printf 'Desktop'
      ;;
    *)
      printf 'Unknown'
      ;;
  esac
}

print_device_information() {
  printf '\nDevice\n'
  printf '  Type         %s\n' "$(device_type)"
}

graphics_description() {
  local line=$1
  local description=""

  description=${line#*: }
  if [[ "$description" =~ ^(.*)[[:space:]]\[[[:xdigit:]]{4}:[[:xdigit:]]{4}\][[:space:]]*(\(rev[[:space:]]+[^[:space:]]+\))?$ ]]; then
    description=${BASH_REMATCH[1]}
  fi
  description=$(trim_value "$description")

  if [[ -n "$description" ]]; then
    printf '%s' "$description"
  else
    printf 'Unavailable'
  fi
}

detect_graphics() {
  local devices=""
  local line=""
  local description=""
  local gpu_count=0

  printf '\nGraphics\n'
  printf '  GPU\n'
  if ! command_exists lspci || ! devices=$(lspci -nn 2>/dev/null); then
    printf '    Unavailable\n'
    return 0
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ (VGA[[:space:]]compatible[[:space:]]controller|3D[[:space:]]controller|Display[[:space:]]controller) ]] || continue

    if (( gpu_count > 0 )); then
      printf '\n'
    fi

    description=$(graphics_description "$line")
    printf '    %s\n' "$description"
    ((gpu_count += 1))
  done <<< "$devices"

  if (( gpu_count == 0 )); then
    printf '    Unavailable\n'
  fi
}

print_system_information
print_cpu_information
print_memory_information
print_storage_information
print_network_information
print_display_information
print_device_information
detect_graphics
