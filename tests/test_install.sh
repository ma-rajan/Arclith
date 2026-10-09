#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-install-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
mock_bin="$test_root/mock-bin"
no_pacman_bin="$test_root/no-pacman-bin"
mkdir -p "$fixture" "$mock_bin" "$no_pacman_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/hardware" "$repo_root/install" \
  "$repo_root/packages" "$repo_root/profiles" "$fixture/"

real_awk=$(command -v awk)
ln -s "$(command -v bash)" "$mock_bin/bash"
ln -s "$(command -v dirname)" "$mock_bin/dirname"
ln -s "$(command -v bash)" "$no_pacman_bin/bash"
ln -s "$(command -v dirname)" "$no_pacman_bin/dirname"
ln -s "$(command -v cat)" "$no_pacman_bin/cat"

cat > "$mock_bin/awk" <<'EOF'
#!/usr/bin/env bash
last_argument=${!#}
if [[ "$last_argument" == /etc/os-release ]]; then
  case "$1" in
    *ID_LIKE*) printf '%s\n' "${MOCK_OS_LIKE:-}" ;;
    *) printf '%s\n' "${MOCK_OS_ID:-arch}" ;;
  esac
else
  exec "$REAL_AWK" "$@"
fi
EOF

cat > "$mock_bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf '<%s>' "$@" >> "$PACMAN_LOG"
printf '\n' >> "$PACMAN_LOG"
case "${1-}" in
  -Qq)
    cat "$INSTALLED_PACKAGES"
    ;;
  -S)
    if [[ ${MOCK_PACMAN_INSTALL_FAIL:-0} == 1 ]]; then
      printf 'mock pacman installation failure\n' >&2
      exit 42
    fi
    ;;
  *)
    printf 'unexpected pacman arguments\n' >&2
    exit 64
    ;;
esac
EOF

cat > "$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

chmod +x "$mock_bin/awk" "$mock_bin/pacman" "$mock_bin/sudo"
export REAL_AWK="$real_awk"
export PATH="$mock_bin:$PATH"
export PACMAN_LOG="$test_root/pacman.log"
export INSTALLED_PACKAGES="$test_root/installed.txt"
: > "$PACMAN_LOG"
printf 'git\nnmap\n' > "$INSTALLED_PACKAGES"

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

assert_no_install_invocation() {
  if ! grep -Fq '<-S>' "$PACMAN_LOG"; then
    printf 'ok - no pacman install invocation occurred\n'
  else
    printf 'not ok - pacman install invocation occurred unexpectedly\n' >&2
    exit 1
  fi
}

if "$fixture/arclith.sh" install unknown --dry-run >"$test_root/unknown.out" 2>&1; then
  printf 'not ok - unknown profile must fail\n' >&2; exit 1
fi
assert_contains "unknown profile is rejected" 'Unknown profile: unknown' "$(<"$test_root/unknown.out")"
assert "unknown profile uses usage/selection exit code 2" bash -c '"$1" install unknown --dry-run >/dev/null 2>&1; [[ $? -eq 2 ]]' _ "$fixture/arclith.sh"
[[ ! -s "$PACMAN_LOG" ]] || { printf 'not ok - unknown profile queried pacman\n' >&2; exit 1; }

mkdir -p "$fixture/profiles/invalid"
printf 'NAME=invalid\nPACKAGE_LISTS=missing.txt\n' > "$fixture/profiles/invalid/profile.conf"
if "$fixture/arclith.sh" install invalid --yes >"$test_root/invalid.out" 2>&1; then
  printf 'not ok - invalid profile must fail\n' >&2; exit 1
fi
assert_contains "invalid profile is rejected" 'Profile' "$(<"$test_root/invalid.out")"
assert_no_install_invocation
[[ ! -s "$PACMAN_LOG" ]] || { printf 'not ok - invalid profile invoked pacman\n' >&2; exit 1; }

: > "$PACMAN_LOG"
dry_run_output=$("$fixture/arclith.sh" install cyber --dry-run)
assert_contains "dry run marks the profile valid" 'Status: valid' "$dry_run_output"
assert_contains "installed packages are identified" 'nmap' "$dry_run_output"
assert_contains "installed packages are identified" 'git' "$dry_run_output"
assert_contains "missing packages are identified" 'wireshark-qt' "$dry_run_output"
assert_contains "missing packages are identified" 'base-devel' "$dry_run_output"
assert_contains "dry run completes without changes" 'No changes were made' "$dry_run_output"
assert_no_install_invocation

package_plan_output=$("$fixture/arclith.sh" profile show cyber)
assert_contains "existing package planning still works" 'Total packages: 5' "$package_plan_output"

: > "$PACMAN_LOG"
if "$fixture/arclith.sh" install cyber </dev/null >"$test_root/default.out" 2>&1; then
  printf 'not ok - no confirmation must cancel installation\n' >&2; exit 1
fi
assert_contains "default confirmation is no" 'Installation cancelled' "$(<"$test_root/default.out")"
assert_no_install_invocation

: > "$PACMAN_LOG"
if printf 'n\n' | "$fixture/arclith.sh" install cyber >"$test_root/no.out" 2>&1; then
  printf 'not ok - negative confirmation must cancel installation\n' >&2; exit 1
fi
assert_contains "negative confirmation is honored" 'Installation cancelled' "$(<"$test_root/no.out")"
assert_no_install_invocation

: > "$PACMAN_LOG"
if ! printf 'y\n' | "$fixture/arclith.sh" install cyber >"$test_root/yes.out" 2>&1; then
  printf 'not ok - affirmative confirmation should install with mocked pacman\n' >&2
  cat "$test_root/yes.out" >&2
  exit 1
fi
assert_contains "affirmative confirmation proceeds" 'installation completed' "$(<"$test_root/yes.out")"
if ! grep -Fxq '<-S><--needed><--><base-devel><curl><wireshark-qt>' "$PACMAN_LOG"; then
  printf 'not ok - missing package arguments were not passed as separate arguments\n' >&2
  cat "$PACMAN_LOG" >&2
  exit 1
fi
printf 'ok - affirmative confirmation invokes pacman with package arguments\n'

: > "$PACMAN_LOG"
if MOCK_PACMAN_INSTALL_FAIL=1 "$fixture/arclith.sh" install cyber --yes >"$test_root/failure.out" 2>&1; then
  printf 'not ok - pacman failure must fail the install command\n' >&2; exit 1
fi
assert_contains "pacman failure is reported" 'Package installation failed' "$(<"$test_root/failure.out")"

printf 'tool+name\nsafe.name\n' > "$fixture/packages/arguments.txt"
mkdir -p "$fixture/profiles/safeargs"
cat > "$fixture/profiles/safeargs/profile.conf" <<'EOF'
NAME=safeargs
DESCRIPTION=Argument safety fixture
VERSION=1.0.0
PACKAGE_LISTS=arguments.txt
EOF
: > "$PACMAN_LOG"
"$fixture/arclith.sh" install safeargs --yes >"$test_root/arguments.out" 2>&1
if ! grep -Fxq '<-S><--needed><--><tool+name><safe.name>' "$PACMAN_LOG"; then
  printf 'not ok - package names were not passed as literal argv values\n' >&2
  cat "$PACMAN_LOG" >&2
  exit 1
fi
printf 'ok - package names are passed as literal argv values\n'

mkdir -p "$fixture/profiles/unsafe"
printf 'NAME=unsafe\nDESCRIPTION=Unsafe fixture\nVERSION=1.0.0\nPACKAGE_LISTS=unsafe.txt\n' > "$fixture/profiles/unsafe/profile.conf"
printf 'harmless;touch /tmp/arclith-should-not-exist\n' > "$fixture/packages/unsafe.txt"
: > "$PACMAN_LOG"
if "$fixture/arclith.sh" install unsafe --yes >"$test_root/unsafe.out" 2>&1; then
  printf 'not ok - malformed package entry must be rejected\n' >&2; exit 1
fi
assert_no_install_invocation

mkdir -p "$test_root/external-packages" "$fixture/profiles/linked"
printf 'outside-package\n' > "$test_root/external-packages/list.txt"
ln -s "$test_root/external-packages" "$fixture/packages/external-link"
cat > "$fixture/profiles/linked/profile.conf" <<'EOF'
NAME=linked
DESCRIPTION=Symlink fixture
VERSION=1.0.0
PACKAGE_LISTS=external-link/list.txt
EOF
: > "$PACMAN_LOG"
if "$fixture/arclith.sh" install linked --yes >"$test_root/linked.out" 2>&1; then
  printf 'not ok - package-list symlink must be rejected\n' >&2; exit 1
fi
assert_contains "package-list symlink is rejected" 'symbolic link' "$(<"$test_root/linked.out")"
[[ ! -s "$PACMAN_LOG" ]] || { printf 'not ok - symlinked profile invoked pacman\n' >&2; exit 1; }

if PATH="$no_pacman_bin" "$fixture/arclith.sh" install cyber --dry-run >"$test_root/no-pacman.out" 2>&1; then
  printf 'not ok - missing pacman must fail\n' >&2; exit 1
fi
assert_contains "pacman unavailable is reported" 'pacman is unavailable' "$(<"$test_root/no-pacman.out")"

: > "$PACMAN_LOG"
if MOCK_OS_ID=debian "$fixture/arclith.sh" install cyber --dry-run >"$test_root/non-arch.out" 2>&1; then
  printf 'not ok - non-Arch system must be rejected\n' >&2; exit 1
fi
assert_contains "non-Arch system is rejected" 'not identified as Arch Linux' "$(<"$test_root/non-arch.out")"
[[ ! -s "$PACMAN_LOG" ]] || { printf 'not ok - non-Arch system queried pacman\n' >&2; exit 1; }

if "$fixture/arclith.sh" install >"$test_root/usage.out" 2>&1; then
  printf 'not ok - missing profile must return usage error\n' >&2; exit 1
fi
assert "missing profile returns exit code 2" bash -c '"$1" install >/dev/null 2>&1; [[ $? -eq 2 ]]' _ "$fixture/arclith.sh"
if "$fixture/arclith.sh" install cyber --bogus >"$test_root/option.out" 2>&1; then
  printf 'not ok - unsupported option must return usage error\n' >&2; exit 1
fi
assert_contains "unsupported option is rejected" 'Unsupported install option' "$(<"$test_root/option.out")"

printf 'All installation tests passed.\n'
