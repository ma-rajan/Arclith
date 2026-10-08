#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-profile-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
mkdir -p "$fixture"
cp -R "$repo_root/arclith.sh" "$repo_root/hardware" \
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
  find "$fixture/profiles" "$fixture/packages" -type f -print0 \
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

hardware_output=$("$fixture/arclith.sh" hardware)
assert_contains "existing hardware detection still runs" 'System' "$hardware_output"
assert_contains "hardware recommendations still run" 'Recommendations' "$hardware_output"

printf 'All profile tests passed.\n'
