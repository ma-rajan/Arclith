#!/usr/bin/env bash
# Read-only compatibility guidance sourced by hardware/detect.sh.

print_recommendation() {
  local status=$1 message=$2
  if (( ${JSON_RECOMMENDATIONS:-0} )); then
    RECOMMENDATION_STATUSES+=("$status")
    RECOMMENDATION_MESSAGES+=("$message")
    return
  fi
  printf '  [%-11s] %s\n' "$status" "$message"
}

is_arch_based() {
  local os_id='' os_like='' os_values

  if [[ ! -r /etc/os-release ]]; then
    return 1
  fi

  if ! os_values=$(awk -F= '
    $1 == "ID" { gsub(/"/, "", $2); id=tolower($2) }
    $1 == "ID_LIKE" { gsub(/"/, "", $2); like=tolower($2) }
    END { printf "%s|%s", id, like }
  ' /etc/os-release 2>/dev/null); then
    hardware_probe_error 'could not inspect /etc/os-release for Arch compatibility with awk'
    HARDWARE_PROBE_FAILURES=$((HARDWARE_PROBE_FAILURES + 1))
    return 2
  fi
  IFS='|' read -r os_id os_like <<< "$os_values"
  [[ $os_id == arch || " $os_like " == *' arch '* ]]
}

package_or_command_status() {
  local command_name=$1 package_name=$2 description=$3

  if command_exists "$command_name"; then
    print_recommendation 'Detected' "$description"
  elif command_exists pacman; then
    if pacman -Qq "$package_name" >/dev/null 2>&1; then
      print_recommendation 'Detected' "$description package is installed"
    else
      print_recommendation 'Optional' "$description is not detected"
    fi
  else
    print_recommendation 'Unavailable' "Cannot check $description without pacman"
  fi
}

print_system_recommendations() {
  local architecture=$1 os_status
  printf '[System]\n'
  if is_arch_based; then
    print_recommendation 'Detected' 'Arch Linux or an Arch-based environment'
  else
    os_status=$?
    if (( os_status == 2 )); then
      print_recommendation 'Unavailable' 'Operating-system compatibility could not be determined because its probe failed'
    elif [[ -r /etc/os-release ]]; then
      print_recommendation 'Warning' 'A non-Arch environment was detected; ARCLITH targets Arch Linux'
    else
      print_recommendation 'Unavailable' 'Operating-system compatibility could not be determined'
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
  elif command_exists pacman && pacman -Qq hyprland >/dev/null 2>&1; then
    print_recommendation 'Detected' 'Hyprland package is installed'
  elif command_exists pacman; then
    print_recommendation 'Recommended' 'Hyprland is not detected for a Hyprland-focused setup'
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
  local architecture=$1 desktop=$2 gpu=$3 displays=$4
  printf 'Compatibility Recommendations (read-only)\n'
  print_system_recommendations "$architecture"
  print_wayland_recommendations "$desktop"
  print_gpu_recommendations "$gpu"
  print_display_recommendations "$displays"
  print_tool_recommendations
}
