#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-doctor-tests.XXXXXX")
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
  find "$fixture" "$home" -type f -print0 | sort -z | xargs -0 -r sha256sum
}
run_doctor() {
  HOME="$home" "$fixture/arclith.sh" config doctor 2>&1
}

for component in waybar rofi kitty; do
  mkdir -p "$fixture/core/configs/$component"
  printf 'fixture setting\n' > "$fixture/core/configs/$component/settings.conf"
done
before=$(snapshot)
if output=$(run_doctor); then :; else printf 'not ok - healthy fixture should pass\n%s\n' "$output" >&2; exit 1; fi
contains 'healthy configuration passes' 'Doctor result: PASS' "$output"
contains 'missing optional component sources are warnings' 'WARN optional component source: hyprland' "$output"
contains 'healthy configuration validates selected profile' 'PASS config reference: PROFILE=minimal' "$output"
after=$(snapshot)
assert 'doctor does not modify fixture files' test "$before" = "$after"
assert 'doctor does not create destination directories' test ! -e "$home/.config"

mv "$fixture/config/arclith.conf" "$test_root/arclith.conf.saved"
if output=$(run_doctor); then printf 'not ok - missing config should fail\n' >&2; exit 1; else status=$?; fi
assert 'missing config returns failure' test "$status" -eq 1
contains 'missing config is actionable' 'FAIL config file' "$output"
mv "$test_root/arclith.conf.saved" "$fixture/config/arclith.conf"

printf 'PROFILE minimal\n' > "$fixture/config/arclith.conf"
if output=$(run_doctor); then printf 'not ok - malformed config should fail\n' >&2; exit 1; else status=$?; fi
assert 'malformed syntax returns failure' test "$status" -eq 1
contains 'malformed syntax is reported' 'FAIL config syntax' "$output"
cp "$repo_root/config/arclith.conf" "$fixture/config/arclith.conf"

sed -i 's/^PROFILE=.*/PROFILE=not-a-profile/' "$fixture/config/arclith.conf"
if output=$(run_doctor); then printf 'not ok - invalid config reference should fail\n' >&2; exit 1; else status=$?; fi
assert 'invalid reference returns failure' test "$status" -eq 1
contains 'invalid profile reference is reported' 'FAIL config reference: PROFILE' "$output"
cp "$repo_root/config/arclith.conf" "$fixture/config/arclith.conf"

rm -rf "$fixture/core/configs/waybar"
if output=$(run_doctor); then status=0; else status=$?; fi
assert 'missing optional component source file does not fail diagnostics' test "$status" -eq 0
contains 'missing optional component source file is reported as warning' 'WARN optional component source: waybar is unavailable' "$output"
mkdir -p "$fixture/core/configs/waybar"
printf 'valid fixture\n' > "$fixture/core/configs/waybar/settings.conf"

mkdir -p "$test_root/outside"
rm -rf "$fixture/core/configs/kitty"
ln -s "$test_root/outside" "$fixture/core/configs/kitty"
if output=$(run_doctor); then printf 'not ok - unsafe source reference should fail\n' >&2; exit 1; else status=$?; fi
assert 'unsafe component source returns failure' test "$status" -eq 1
contains 'unsafe source is distinguished from unavailable optional source' 'FAIL component source: kitty is unsafe-symlink' "$output"
rm "$fixture/core/configs/kitty"
mkdir -p "$fixture/core/configs/kitty"
printf 'fixture setting\n' > "$fixture/core/configs/kitty/settings.conf"

printf 'blocks destination\n' > "$home/.config"
if output=$(run_doctor); then printf 'not ok - blocked destination should fail\n' >&2; exit 1; else status=$?; fi
assert 'blocked destination returns failure' test "$status" -eq 1
contains 'blocked destination permission/path issue is actionable' 'nearest existing parent is not writable/searchable' "$output"
assert 'doctor leaves blocked destination untouched' test "$(cat "$home/.config")" = 'blocks destination'

status=0
HOME="$home" "$fixture/arclith.sh" config doctor extra >/dev/null 2>&1 || status=$?
assert 'doctor usage errors return exit code 2' test "$status" -eq 2

printf 'All configuration doctor tests passed.\n'
