#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-profile-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
mkdir -p "$fixture"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" "$repo_root/hardware" \
  "$repo_root/packages" "$repo_root/profiles" "$fixture/"

assert() {
  local description=$1
  shift
  if "$@"; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s\n' "$description" >&2
    exit 1
  fi
}

assert_contains() {
  local description=$1 expected=$2 output=$3
  if [[ "$output" == *"$expected"* ]]; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s (missing: %s)\n' "$description" "$expected" >&2
    exit 1
  fi
}

readonly_snapshot() {
  find "$fixture/config" "$fixture/profiles" "$fixture/packages" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum
}

files_before=$(readonly_snapshot)
list_output=$("$fixture/arclith.sh" profile list)
for profile in minimal developer cyber full; do
  assert_contains "profile list discovers $profile" "$profile" "$list_output"
done

validate_output=$("$fixture/arclith.sh" profile validate)
assert_contains "all shipped profiles validate" 'full: valid' "$validate_output"
assert "valid named profile passes validation" "$fixture/arclith.sh" profile validate cyber

info_output=$("$fixture/arclith.sh" profile info cyber)
assert_contains "profile info shows description" 'Core utilities and cybersecurity tools' "$info_output"
assert_contains "profile info shows package references" 'cyber.txt' "$info_output"
assert_contains "profile info shows version" 'Version: 1.0.0' "$info_output"

default_output=$("$fixture/arclith.sh" profile default)
assert_contains "profile default reports configured selection" 'Default profile: minimal' "$default_output"
assert "profile default does not modify configuration" bash -c '[[ "$1" == "$2" ]]' _ "$files_before" "$(readonly_snapshot)"

cp "$fixture/config/arclith.conf" "$test_root/defaults.good"
mv "$fixture/config/arclith.conf" "$test_root/defaults.saved"
if "$fixture/arclith.sh" profile default >"$test_root/default-missing.out" 2>&1; then
  printf 'not ok - missing defaults file is rejected\n' >&2; exit 1
fi
assert_contains "missing defaults file is reported" 'defaults are missing, unreadable, or symlinked' "$(<"$test_root/default-missing.out")"
mv "$test_root/defaults.saved" "$fixture/config/arclith.conf"

printf 'PROFILE=missing\nINSTALL_AUR_HELPER=false\nBACKUP_EXISTING_CONFIG=true\n' > "$fixture/config/arclith.conf"
if "$fixture/arclith.sh" profile default >"$test_root/default-invalid.out" 2>&1; then
  printf 'not ok - invalid configured profile is rejected\n' >&2; exit 1
fi
assert_contains "invalid configured default is reported" 'Configured default profile is missing or invalid: missing' "$(<"$test_root/default-invalid.out")"
cp "$test_root/defaults.good" "$fixture/config/arclith.conf"

printf 'PROFILE minimal\n' > "$fixture/config/arclith.conf"
if "$fixture/arclith.sh" profile default >"$test_root/default-syntax.out" 2>&1; then
  printf 'not ok - malformed defaults are rejected\n' >&2; exit 1
fi
assert_contains "malformed defaults are reported" 'Malformed ARCLITH default' "$(<"$test_root/default-syntax.out")"
cp "$test_root/defaults.good" "$fixture/config/arclith.conf"

compare_output=$("$fixture/arclith.sh" profile compare minimal developer)
assert_contains "profile comparison names both profiles" 'Profile comparison: minimal vs developer' "$compare_output"
assert_contains "profile comparison reports shared packages" 'Shared (3):' "$compare_output"
assert_contains "profile comparison lists development-only packages" 'Only in developer (2):' "$compare_output"
assert_contains "profile comparison includes a development-only package" '  - neovim' "$compare_output"
same_compare_output=$("$fixture/arclith.sh" profile compare minimal minimal)
assert_contains "identical profiles have an empty difference" 'Only in minimal (0):' "$same_compare_output"
assert "profile comparison leaves profile and package files unchanged" bash -c '[[ "$1" == "$2" ]]' _ "$files_before" "$(readonly_snapshot)"
if "$fixture/arclith.sh" profile compare minimal absent >"$test_root/compare-invalid.out" 2>&1; then
  printf 'not ok - comparison with an invalid profile is rejected\n' >&2; exit 1
fi
assert_contains "invalid comparison profile is reported" 'Cannot compare profile "absent"' "$(<"$test_root/compare-invalid.out")"
assert "profile comparison usage errors return exit code 2" bash -c '"$1" profile compare minimal >/dev/null 2>&1; [[ $? -eq 2 ]]' _ "$fixture/arclith.sh"
assert "profile commands leave profile and package files unchanged" bash -c '[[ "$1" == "$2" ]]' _ "$files_before" "$(readonly_snapshot)"

mkdir -p "$fixture/profiles/broken"
if "$fixture/arclith.sh" profile validate broken >"$test_root/missing.out" 2>&1; then
  printf 'not ok - missing manifest is rejected\n' >&2; exit 1
fi
assert_contains "missing manifest is reported" 'profile.conf' "$(<"$test_root/missing.out")"

cat > "$fixture/profiles/broken/profile.conf" <<'EOF'
NAME=broken
DESCRIPTION=Broken fixture
VERSION=1.0.0
PACKAGE_LISTS=does-not-exist.txt
EOF
if "$fixture/arclith.sh" profile validate broken >"$test_root/reference.out" 2>&1; then
  printf 'not ok - invalid package reference is rejected\n' >&2; exit 1
fi
assert_contains "missing package reference is reported" 'missing or unreadable' "$(<"$test_root/reference.out")"

cat > "$fixture/profiles/broken/profile.conf" <<'EOF'
NAME=elsewhere
VERSION=bad
PACKAGE_LISTS=base.txt
EOF
if "$fixture/arclith.sh" profile validate broken >"$test_root/fields.out" 2>&1; then
  printf 'not ok - missing metadata is rejected\n' >&2; exit 1
fi
fields_output=$(<"$test_root/fields.out")
assert_contains "missing description is reported" 'missing DESCRIPTION' "$fields_output"
assert_contains "directory/name mismatch is reported" 'does not match directory' "$fields_output"
assert_contains "malformed version is reported" 'VERSION must appear once' "$fields_output"

cp "$repo_root/packages/base.txt" "$fixture/packages/duplicate.txt"
cat > "$fixture/profiles/broken/profile.conf" <<'EOF'
NAME=broken
DESCRIPTION=Duplicate fixture
VERSION=1.0.0
PACKAGE_LISTS=base.txt,duplicate.txt
EOF
if "$fixture/arclith.sh" profile validate broken >"$test_root/duplicate.out" 2>&1; then
  printf 'not ok - duplicate package entries are rejected\n' >&2; exit 1
fi
assert_contains "duplicate packages are reported" 'duplicate package' "$(<"$test_root/duplicate.out")"

assert "profile usage errors return exit code 2" bash -c '"$1" profile info >/dev/null 2>&1; [[ $? -eq 2 ]]' _ "$fixture/arclith.sh"
assert "unknown command returns exit code 2" bash -c '"$1" nonsense >/dev/null 2>&1; [[ $? -eq 2 ]]' _ "$fixture/arclith.sh"

hardware_output=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION \
  -u WAYLAND_DISPLAY -u DISPLAY "$fixture/arclith.sh" hardware)
assert_contains "existing hardware detection still runs" 'System' "$hardware_output"
assert_contains "hardware recommendations still run" 'Recommendations' "$hardware_output"

mv "$fixture/config/arclith.conf" "$test_root/defaults.link-saved"
printf 'PROFILE=minimal\nINSTALL_AUR_HELPER=false\nBACKUP_EXISTING_CONFIG=true\n' > "$test_root/defaults.external"
ln -s "$test_root/defaults.external" "$fixture/config/arclith.conf"
if "$fixture/arclith.sh" profile set-default developer --yes >"$test_root/default-symlink.out" 2>&1; then
  printf 'not ok - symlinked defaults cannot be changed\n' >&2; exit 1
fi
assert_contains "symlinked defaults are refused" 'missing, unreadable, or symlinked' "$(<"$test_root/default-symlink.out")"
assert "symlink target remains untouched" test "$(<"$test_root/defaults.external")" = $'PROFILE=minimal\nINSTALL_AUR_HELPER=false\nBACKUP_EXISTING_CONFIG=true'
rm "$fixture/config/arclith.conf"
mv "$test_root/defaults.link-saved" "$fixture/config/arclith.conf"

sed -i 's/^PROFILE=minimal$/PROFILE=minimal # keep this note/' "$fixture/config/arclith.conf"
defaults_before=$(<"$fixture/config/arclith.conf")
cp "$fixture/config/arclith.conf" "$test_root/defaults.before-set"
dry_run_output=$("$fixture/arclith.sh" profile set-default developer --dry-run)
assert_contains "default change dry run shows proposed selection" 'Default profile change: minimal -> developer' "$dry_run_output"
assert_contains "default change dry run does not write" 'No files were changed' "$dry_run_output"
assert "default change dry run preserves settings" test "$(<"$fixture/config/arclith.conf")" = "$defaults_before"
assert "default change dry run creates no recovery copy" bash -c '[[ -z $(find "$1/config" -name "arclith.conf.arclith-backup.*" -print -quit) ]]' _ "$fixture"

if printf 'n\n' | "$fixture/arclith.sh" profile set-default developer >"$test_root/default-declined.out" 2>&1; then
  printf 'not ok - declining default change should leave configuration unchanged\n' >&2; exit 1
fi
assert_contains "declined default change is reported" 'Default profile change cancelled' "$(<"$test_root/default-declined.out")"
assert "declined default change preserves settings" test "$(<"$fixture/config/arclith.conf")" = "$defaults_before"

if "$fixture/arclith.sh" profile set-default unknown --yes >"$test_root/default-set-invalid.out" 2>&1; then
  printf 'not ok - invalid profile cannot become default\n' >&2; exit 1
fi
assert_contains "invalid default selection is reported" 'Cannot set an unknown or invalid default profile' "$(<"$test_root/default-set-invalid.out")"

set_output=$("$fixture/arclith.sh" profile set-default developer --yes)
assert_contains "confirmed default change succeeds" 'Default profile updated to developer' "$set_output"
assert_contains "updated default is reported" 'Default profile: developer' "$("$fixture/arclith.sh" profile default)"
backup_path=$(find "$fixture/config" -name 'arclith.conf.arclith-backup.*' -type f -print -quit)
assert "confirmed default change creates a recovery copy" test -n "$backup_path"
assert "recovery copy preserves original defaults" cmp -s "$test_root/defaults.before-set" "$backup_path"
assert_contains "default change preserves unrelated settings" 'INSTALL_AUR_HELPER=false' "$(<"$fixture/config/arclith.conf")"
assert_contains "default change preserves the profile comment" 'PROFILE=developer # keep this note' "$(<"$fixture/config/arclith.conf")"

status=0
"$fixture/arclith.sh" profile set-default >/dev/null 2>&1 || status=$?
assert "default change usage errors return exit code 2" test "$status" -eq 2

mkdir -p "$test_root/configure-home"
status=0
configure_output=$(HOME="$test_root/configure-home" "$fixture/arclith.sh" configure 2>&1) || status=$?
if (( status != 0 )); then printf '%s\n' "$configure_output" >&2; fi
assert "configure planning succeeds without host mutation" test "$status" -eq 0
assert_contains "configure reports planning-only behavior" 'Planning only: no packages were installed' "$configure_output"

for planned_command in update uninstall; do
  status=0
  planned_output=$("$fixture/arclith.sh" "$planned_command" 2>&1) || status=$?
  assert "$planned_command placeholder returns nonzero" test "$status" -eq 2
  assert_contains "$planned_command placeholder explains it is not implemented" \
    "The '$planned_command' command is not implemented yet" "$planned_output"
done

status=0
help_output=$("$fixture/arclith.sh" help 2>&1) || status=$?
assert "help remains successful" test "$status" -eq 0
assert_contains "help still prints usage" 'Usage:' "$help_output"
status=0
profile_plan_output=$("$fixture/arclith.sh" profile show minimal 2>&1) || status=$?
assert "implemented profile command remains successful" test "$status" -eq 0
assert_contains "implemented profile command still shows its plan" 'Manifest status: valid' "$profile_plan_output"

printf 'All profile tests passed.\n'
