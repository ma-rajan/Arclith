#!/usr/bin/env bash
# Read-only compatibility guidance sourced by hardware/detect.sh.

PACMAN_PACKAGE_QUERY_STATUS=not_checked
declare -A INSTALLED_PACKAGE_SNAPSHOT=()

print_recommendation() {
  local status=$1 message=$2
  if (( ${JSON_RECOMMENDATIONS:-0} )); then
    RECOMMENDATION_STATUSES+=("$status")
    RECOMMENDATION_MESSAGES+=("$message")
    return
  fi
  printf '  [%-11s] %s\n' "$status" "$message"
}

read_os_metadata() {
  if [[ ! -e /etc/os-release ]]; then return 2; fi
  if [[ ! -r /etc/os-release ]]; then return 1; fi
  awk -F= '
    $1 == "PRETTY_NAME" { pretty_name=$0; sub(/^[^=]*=/, "", pretty_name); gsub(/^"|"$/, "", pretty_name) }
    $1 == "ID" { os_id=tolower($2); gsub(/"/, "", os_id) }
    $1 == "ID_LIKE" { os_like=tolower($2); gsub(/"/, "", os_like) }
    END { printf "%s\t%s\t%s", pretty_name, os_id, os_like }
  ' /etc/os-release 2>/dev/null
}

is_arch_based() {
  local os_id=${1:-Unavailable} os_like=${2:-Unavailable} os_values status
  if (( $# < 2 )); then
    if os_values=$(read_os_metadata); then
      IFS=$'\t' read -r _ os_id os_like <<< "$os_values"
    else
      status=$?
      (( status == 2 )) && return 2
      return 2
    fi
  fi
  if [[ $os_id == Unavailable && $os_like == Unavailable ]]; then return 2; fi
  [[ $os_id == arch || " $os_like " == *' arch '* ]]
}

package_or_command_status() {
  local command_name=$1 package_name=$2 description=$3

  if command_exists "$command_name"; then
    print_recommendation 'Detected' "$description"
  elif [[ $PACMAN_PACKAGE_QUERY_STATUS == available ]]; then
    if [[ -n ${INSTALLED_PACKAGE_SNAPSHOT[$package_name]+present} ]]; then
      print_recommendation 'Detected' "$description package is installed"
    else
      print_recommendation 'Optional' "$description is not detected"
    fi
  elif [[ $PACMAN_PACKAGE_QUERY_STATUS == failed ]]; then
    print_recommendation 'Unavailable' "$description package status could not be checked because the pacman query failed"
  else
    print_recommendation 'Unavailable' "Cannot check $description without pacman"
  fi
}

collect_installed_package_snapshot() {
  local package_list package status
  INSTALLED_PACKAGE_SNAPSHOT=()
  PACMAN_PACKAGE_QUERY_STATUS=missing
  if ! command_exists pacman; then return 0; fi

  if package_list=$(pacman -Qq 2>/dev/null); then
    PACMAN_PACKAGE_QUERY_STATUS=available
    while IFS= read -r package || [[ -n $package ]]; do
      [[ -n $package ]] && INSTALLED_PACKAGE_SNAPSHOT[$package]=1
    done <<< "$package_list"
  else
    status=$?
    PACMAN_PACKAGE_QUERY_STATUS=failed
    hardware_probe_error "pacman -Qq failed with status $status; package presence cannot be determined"
    HARDWARE_PROBE_FAILURES=$(( ${HARDWARE_PROBE_FAILURES:-0} + 1 ))
  fi
}

print_system_recommendations() {
  local architecture=$1 os_id=$2 os_like=$3 os_probe_failed=$4 os_status
  printf '[System]\n'
  if is_arch_based "$os_id" "$os_like"; then
    print_recommendation 'Detected' 'Arch Linux or an Arch-based environment'
  else
    os_status=$?
    if (( os_status == 2 )); then
      if [[ $os_probe_failed == true ]]; then
        print_recommendation 'Unavailable' 'Operating-system compatibility could not be determined because its probe failed'
      else
        print_recommendation 'Unavailable' 'Operating-system compatibility could not be determined'
      fi
    else
      print_recommendation 'Warning' 'A non-Arch environment was detected; ARCLITH targets Arch Linux'
    fi
  fi

  case "$architecture" in
    x86_64) print_recommendation 'Detected' 'x86_64 architecture' ;;
    ''|Unavailable) print_recommendation 'Unavailable' 'Architecture could not be determined' ;;
    *) print_recommendation 'Consider' 'Verify package and driver support for this architecture' ;;
  esac
}

print_wayland_recommendations() {
  local desktop=$1

  printf '\n[Wayland and Hyprland]\n'
  if [[ ${XDG_SESSION_TYPE:-} == wayland || -n ${WAYLAND_DISPLAY:-} ]]; then
    print_recommendation 'Detected' 'Wayland session indicators are present'
  else
    print_recommendation 'Not detected' 'No Wayland session indicators are present'
  fi

  if command_exists Hyprland; then
    print_recommendation 'Detected' 'Hyprland executable is available'
  elif [[ $PACMAN_PACKAGE_QUERY_STATUS == available ]]; then
    if [[ -n ${INSTALLED_PACKAGE_SNAPSHOT[hyprland]+present} ]]; then
      print_recommendation 'Detected' 'Hyprland package is installed'
    else
      print_recommendation 'Recommended' 'Hyprland is not detected for a Hyprland-focused setup'
    fi
  elif [[ $PACMAN_PACKAGE_QUERY_STATUS == failed ]]; then
    print_recommendation 'Unavailable' 'Hyprland package status could not be checked because the pacman query failed'
  else
    print_recommendation 'Unavailable' 'Hyprland package status cannot be checked without pacman'
  fi

  if [[ $desktop == Hyprland ]]; then
    print_recommendation 'Detected' 'Hyprland is the active compositor'
  elif [[ $desktop == Unavailable ]]; then
    print_recommendation 'Not detected' 'No active desktop or compositor was identified'
  else
    print_recommendation 'Detected' "Active desktop/compositor: $desktop"
  fi
}

print_gpu_recommendations() {
  local gpu=$1 normalized_gpu

  printf '\n[GPU]\n'
  if [[ $gpu == Unavailable ]]; then
    print_recommendation 'Unavailable' 'GPU information could not be detected'
    return
  fi

  normalized_gpu=${gpu,,}
  if [[ $normalized_gpu =~ (^|[^[:alnum:]])nvidia([^[:alnum:]]|$) ]]; then
    print_recommendation 'Warning' 'NVIDIA detected — verify driver and Wayland session configuration manually'
  fi
  if [[ $normalized_gpu =~ (^|[^[:alnum:]])amd([^[:alnum:]]|$) || $normalized_gpu == *'advanced micro devices'* || $normalized_gpu =~ (^|[^[:alnum:]])ati([^[:alnum:]]|$) ]]; then
    print_recommendation 'Consider' 'AMD detected — review Mesa and AMDGPU support for the selected setup'
  fi
  if [[ $normalized_gpu =~ (^|[^[:alnum:]])intel([^[:alnum:]]|$) ]]; then
    print_recommendation 'Consider' 'Intel detected — review Mesa support for the selected setup'
  fi
}

print_display_recommendations() {
  local displays=$1 display_count

  printf '\n[Display]\n'
  if [[ $displays == Unavailable ]]; then
    print_recommendation 'Unavailable' 'Display details are not available in this session'
    print_recommendation 'Consider' 'Add Hyprland monitor rules only after manually verifying outputs and resolutions'
    return
  fi

  display_count=$(printf '%s\n' "$displays" | awk 'NF { count++ } END { print count + 0 }')
  print_recommendation 'Detected' "$display_count display output(s): ${displays//$'\n'/, }"
  if (( display_count > 1 )); then
    print_recommendation 'Consider' 'Use explicit Hyprland monitor rules after validating layout and refresh rates'
  else
    print_recommendation 'Optional' 'A monitor rule may be added later if custom scaling or refresh rates are needed'
  fi
}

print_tool_recommendations() {
  printf '\n[Tools]\n'
  package_or_command_status git git 'git'
  package_or_command_status curl curl 'curl'
  package_or_command_status waybar waybar 'waybar'
  package_or_command_status rofi rofi 'rofi'
  package_or_command_status xdg-desktop-portal-hyprland xdg-desktop-portal-hyprland 'Hyprland desktop portal'
}

print_recommendations() {
  local architecture=$1 desktop=$2 gpu=$3 displays=$4 os_id=$5 os_like=$6 os_probe_failed=$7
  collect_installed_package_snapshot
  printf 'Compatibility Recommendations (read-only)\n'
  print_system_recommendations "$architecture" "$os_id" "$os_like" "$os_probe_failed"
  print_wayland_recommendations "$desktop"
  print_gpu_recommendations "$gpu"
  print_display_recommendations "$displays"
  print_tool_recommendations
}
