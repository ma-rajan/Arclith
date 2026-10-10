#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-config-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
home="$test_root/home"
mkdir -p "$fixture" "$home"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$fixture/"

assert() {
  local description=$1; shift
  if "$@"; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}
contains() {
  local description=$1 expected=$2 output=$3
  if [[ $output == *"$expected"* ]]; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s (missing: %s)\n' "$description" "$expected" >&2; exit 1; fi
}
snapshot() {
  find "$fixture/core" "$fixture/config" "$home" -type f -print0 | sort -z | xargs -0 -r sha256sum
}

list_output=$(HOME="$home" "$fixture/arclith.sh" config list)
contains 'all six components are discovered' wallust "$list_output"
contains 'missing sources are labeled unavailable' unavailable "$list_output"
validate_output_file="$test_root/validate.out"
if HOME="$home" "$fixture/arclith.sh" config validate >"$validate_output_file" 2>&1; then
  printf 'not ok - missing source directories should fail validation\n' >&2; exit 1
fi
contains 'missing source directory is reported' 'source directory missing' "$(<"$validate_output_file")"
for component in hyprland waybar rofi kitty zsh wallust; do mkdir -p "$fixture/core/configs/$component"; done
printf 'monitor=,preferred,auto,1\n' > "$fixture/core/configs/hyprland/hyprland.conf"
printf 'export PATH=$HOME/bin:$PATH\n' > "$fixture/core/configs/zsh/.zshrc"
for component in waybar rofi kitty wallust; do printf 'fixture setting\n' > "$fixture/core/configs/$component/settings.conf"; done
assert 'all valid component sources pass validation' env HOME="$home" "$fixture/arclith.sh" config validate
info=$(HOME="$home" "$fixture/arclith.sh" config info hyprland)
contains 'valid metadata is displayed' 'Description: Hyprland compositor settings' "$info"
contains 'component source availability is displayed' 'Status: available' "$info"

if HOME="$home" "$fixture/arclith.sh" config info absent >"$test_root/invalid-name.out" 2>&1; then
  printf 'not ok - invalid component name should fail\n' >&2; exit 1
fi
contains 'invalid component name is reported' 'Unknown configuration component' "$(<"$test_root/invalid-name.out")"
for args in 'config info' 'config preview' 'config validate extra' 'config list extra'; do
  # Intentional word splitting constructs only fixed test arguments.
  if HOME="$home" "$fixture/arclith.sh" $args >"$test_root/args.out" 2>&1; then
    printf 'not ok - invalid CLI arguments accepted: %s\n' "$args" >&2; exit 1
  fi
  status=0
  HOME="$home" "$fixture/arclith.sh" $args >/dev/null 2>&1 || status=$?
  [[ $status -eq 2 ]] || { printf 'not ok - CLI usage error did not return 2: %s\n' "$args" >&2; exit 1; }
done
printf 'ok - invalid CLI arguments return usage errors\n'

cp "$fixture/config/components.conf" "$test_root/registry.good"
sed -i 's/^hyprland|[^|]*|[^|]*|[^|]*|true$/hyprland|Hyprland compositor settings|core\/configs\/hyprland|.config\/hypr/' "$fixture/config/components.conf"
if HOME="$home" "$fixture/arclith.sh" config list >"$test_root/missing-field.out" 2>&1; then
  printf 'not ok - missing metadata field should fail\n' >&2; exit 1
fi
contains 'missing metadata is rejected' 'exactly five pipe-separated fields' "$(<"$test_root/missing-field.out")"
cp "$test_root/registry.good" "$fixture/config/components.conf"

sed -i 's|core/configs/hyprland|../outside|' "$fixture/config/components.conf"
if HOME="$home" "$fixture/arclith.sh" config validate >"$test_root/escape.out" 2>&1; then
  printf 'not ok - source path escape should fail\n' >&2; exit 1
fi
contains 'source path escape is rejected' 'unsafe or unsupported source/target path' "$(<"$test_root/escape.out")"
cp "$test_root/registry.good" "$fixture/config/components.conf"

before=$(snapshot)
preview=$(HOME="$home" "$fixture/arclith.sh" config preview hyprland)
contains 'preview identifies a new target file' 'NEW' "$preview"
after=$(snapshot)
assert 'preview leaves source and home files unchanged' test "$before" = "$after"
assert 'preview creates no host config directory' test ! -e "$home/.config"

mkdir -p "$home/.config/hypr"
printf 'user setting\n' > "$home/.config/hypr/hyprland.conf"
before=$(snapshot)
conflict=$(HOME="$home" "$fixture/arclith.sh" config preview hyprland)
contains 'existing target is reported as a conflict' 'CONFLICT' "$conflict"
after=$(snapshot)
assert 'conflict preview does not overwrite the target' test "$before" = "$after"

mkdir -p "$test_root/external"
printf 'outside\n' > "$test_root/external/escape.conf"
rm -rf "$fixture/core/configs/hyprland"
ln -s "$test_root/external" "$fixture/core/configs/hyprland"
if HOME="$home" "$fixture/arclith.sh" config preview hyprland >"$test_root/source-link.out" 2>&1; then
  printf 'not ok - symlinked source directory should fail\n' >&2; exit 1
fi
contains 'symlinked source directory is rejected' 'unsafe-symlink' "$(<"$test_root/source-link.out")"
rm "$fixture/core/configs/hyprland"
mkdir -p "$fixture/core/configs/hyprland"
ln -s "$test_root/external/escape.conf" "$fixture/core/configs/hyprland/linked.conf"
if HOME="$home" "$fixture/arclith.sh" config preview hyprland >"$test_root/entry-link.out" 2>&1; then
  printf 'not ok - source entry symlink should fail\n' >&2; exit 1
fi
contains 'source entry symlink is rejected' 'unsupported source entry' "$(<"$test_root/entry-link.out")"

rm "$fixture/core/configs/hyprland/linked.conf"
printf 'monitor=,preferred,auto,1\n' > "$fixture/core/configs/hyprland/hyprland.conf"
rm -rf "$home/.config"
mkdir -p "$test_root/outside-target"
ln -s "$test_root/outside-target" "$home/.config"
if HOME="$home" "$fixture/arclith.sh" config preview hyprland >"$test_root/target-link.out" 2>&1; then
  printf 'not ok - target parent symlink should fail\n' >&2; exit 1
fi
contains 'target parent symlink is rejected' 'target parent contains a symlink' "$(<"$test_root/target-link.out")"
rm "$home/.config"
printf 'not a directory\n' > "$home/.config"
if HOME="$home" "$fixture/arclith.sh" config preview hyprland >"$test_root/target-file.out" 2>&1; then
  printf 'not ok - non-directory target parent should fail\n' >&2; exit 1
fi
contains 'non-directory target parent is rejected' 'target parent is not a directory' "$(<"$test_root/target-file.out")"

profile_list=$(HOME="$home" "$fixture/arclith.sh" profile list)
contains 'profile command remains functional' 'minimal' "$profile_list"
plan=$(HOME="$home" "$fixture/arclith.sh" profile show cyber)
contains 'package planner remains functional' 'Total packages: 5' "$plan"
hardware=$(HOME="$home" "$fixture/arclith.sh" hardware)
contains 'hardware detection remains functional' 'System' "$hardware"
contains 'hardware recommendations remain functional' 'Recommendations' "$hardware"

printf 'All configuration tests passed.\n'
