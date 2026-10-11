#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-runtime-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
ulimit -c 0 || true

fixture="$test_root/project"
home="$test_root/home"
mkdir -p "$fixture/kitty" "$fixture/waybar" "$fixture/rofi" "$home/.config"
cp "$repo_root/core/configs/kitty/kitty.conf" "$fixture/kitty/kitty.conf"
cp "$repo_root/core/configs/waybar/config.jsonc" "$fixture/waybar/config.jsonc"
cp "$repo_root/core/configs/rofi/config.rasi" "$fixture/rofi/config.rasi"

assert() {
  local description=$1; shift
  if "$@"; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}

# Kitty's installed CLI has no documented noninteractive config-check option.
# Check the shipped file for personal include dependencies without launching it.
if rg -n '^[[:space:]]*(include|globinclude|envinclude|geninclude)[[:space:]]+' "$fixture/kitty/kitty.conf"; then
  printf 'not ok - Kitty source unexpectedly references another config file\n' >&2
  exit 1
fi
assert 'Kitty source has no personal include dependency' test -s "$fixture/kitty/kitty.conf"
if command -v kitty >/dev/null 2>&1; then
  kitty_help=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" kitty --help 2>&1 || true)
  if [[ $kitty_help == *'--debug-config'* ]]; then
    printf 'unavailable - Kitty advertises --debug-config but no documented noninteractive parser was identified\n'
  else
    printf 'unavailable - installed Kitty CLI has no documented noninteractive config parser; Kitty was not launched\n'
  fi
else
  printf 'unavailable - Kitty executable is not installed; no native config check was run\n'
fi

# Waybar's JSONC source is valid strict JSON today. This checks syntax and its
# built-in-only module list without invoking Waybar or contacting a compositor.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$fixture/waybar/config.jsonc" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    config = json.load(source)
assert config.get("modules-left") == []
assert config.get("modules-center") == ["clock"]
assert config.get("modules-right") == []
assert isinstance(config.get("clock"), dict)
PY
  printf 'ok - Waybar static JSON syntax and built-in clock fixture validate\n'
  printf '{ invalid JSONC\n' > "$fixture/waybar/invalid.jsonc"
  if python3 -m json.tool "$fixture/waybar/invalid.jsonc" >/dev/null 2>&1; then
    printf 'not ok - malformed Waybar fixture was accepted by static parser\n' >&2
    exit 1
  fi
  printf 'ok - Waybar static parser rejects malformed fixture\n'
else
  printf 'unavailable - Python 3 is not installed; Waybar static JSON check was skipped\n'
fi
printf 'unavailable - Waybar has no documented parse-only CLI; Waybar was not launched\n'

# Rofi dump mode is a safe inspection path, but it is not treated as a syntax
# validator. The documented validator is probed with valid and invalid files.
if command -v rofi >/dev/null 2>&1; then
  rofi_help=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" rofi -help 2>&1 || true)
  if [[ $rofi_help == *'-dump-config'* ]]; then
    rofi_dump=$(HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      rofi -config "$fixture/rofi/config.rasi" -dump-config)
    assert 'Rofi dump mode reads the fixture without opening the launcher' \
      bash -c '[[ $1 == *"show-icons: false;"* ]]' _ "$rofi_dump"
  else
    printf 'unavailable - installed Rofi does not advertise -dump-config\n'
  fi

  if [[ $rofi_help == *'-rasi-validate'* ]]; then
    printf 'configuration { modes: "drun,run"; }\n' > "$fixture/rofi/valid.rasi"
    printf 'configuration { modes: "drun,run";\n' > "$fixture/rofi/invalid.rasi"
    valid_rc=0
    (cd "$test_root" && ulimit -c 0 && HOME="$home" XDG_CONFIG_HOME="$home/.config" \
      rofi -rasi-validate "$fixture/rofi/valid.rasi") > "$test_root/rofi-valid.out" 2>&1 || valid_rc=$?
    if (( valid_rc == 0 )); then
      invalid_rc=0
      (cd "$test_root" && ulimit -c 0 && HOME="$home" XDG_CONFIG_HOME="$home/.config" \
        rofi -rasi-validate "$fixture/rofi/invalid.rasi") > "$test_root/rofi-invalid.out" 2>&1 || invalid_rc=$?
      if (( invalid_rc == 0 )); then
        printf 'unavailable - Rofi validator accepted malformed fixture; no syntax success claimed\n'
      else
        printf 'ok - Rofi native validator accepts valid and rejects malformed fixtures\n'
      fi
    else
      printf 'unavailable - Rofi validator failed on valid fixture (exit %s); no syntax success claimed\n' "$valid_rc"
    fi
  else
    printf 'unavailable - installed Rofi does not advertise -rasi-validate\n'
  fi
else
  printf 'unavailable - Rofi executable is not installed; native config checks were skipped\n'
fi

printf 'Runtime validation checks completed; no desktop application was launched.\n'
