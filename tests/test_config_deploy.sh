#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-deploy-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
home="$test_root/home"
mock_bin="$test_root/mock-bin"
mkdir -p "$fixture" "$home" "$mock_bin"
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

source_file="$fixture/core/configs/kitty/kitty.conf"
target="$home/.config/kitty/kitty.conf"
mkdir -p "$(dirname -- "$target")"
printf 'unrelated user data\n' > "$home/.config/kitty/keep.txt"
before_preview=$(find "$fixture/core/configs" "$home" -type f -print0 | sort -z | xargs -0 sha256sum)
preview=$(HOME="$home" "$fixture/arclith.sh" config preview kitty)
contains 'preview describes the new Kitty target' NEW "$preview"
after_preview=$(find "$fixture/core/configs" "$home" -type f -print0 | sort -z | xargs -0 sha256sum)
assert 'preview remains read-only' test "$before_preview" = "$after_preview"

apply_output=$(HOME="$home" "$fixture/arclith.sh" config apply kitty --yes)
contains 'new config file is applied' 'Success: configuration component kitty applied' "$apply_output"
assert 'installed file matches bundled source' cmp -s "$source_file" "$target"
assert 'new config file has restrictive permissions' test "$(stat -c '%a' "$target")" = 600
assert 'unrelated file is preserved' test "$(cat "$home/.config/kitty/keep.txt")" = 'unrelated user data'

printf 'user kitty settings\n' > "$target"
chmod 640 "$target"
if HOME="$home" "$fixture/arclith.sh" config apply kitty </dev/null >"$test_root/refused.out" 2>&1; then
  printf 'not ok - overwrite without confirmation should fail\n' >&2; exit 1
fi
contains 'overwrite refusal is reported' 'Skipped: no files were changed' "$(<"$test_root/refused.out")"
assert 'refused overwrite preserves target' test "$(cat "$target")" = 'user kitty settings'
assert 'refused overwrite creates no backup' bash -c '[[ -z $(find "$1" -name "*.arclith-backup.*" -print -quit) ]]' _ "$home"

printf 'y\n' | HOME="$home" "$fixture/arclith.sh" config apply kitty >"$test_root/confirmed.out" 2>&1
backup=$(find "$home" -name 'kitty.conf.arclith-backup.*' -type f -print -quit)
assert 'confirmed overwrite creates a backup' test -n "$backup"
assert 'backup preserves previous content' test "$(cat "$backup")" = 'user kitty settings'
assert 'backup permissions are restrictive' test "$(stat -c '%a' "$backup")" = 600
assert 'confirmed overwrite installs source' cmp -s "$source_file" "$target"
assert 'confirmed overwrite still preserves unrelated file' test "$(cat "$home/.config/kitty/keep.txt")" = 'unrelated user data'

# Simulate a rename that completes but reports failure; the engine must restore
# the prior file from its backup.
printf 'rollback sentinel\n' > "$target"
chmod 640 "$target"
real_mv=$(command -v mv)
cat > "$mock_bin/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MV_TARGET" && ! -e $FAIL_MV_MARKER ]]; then
  "$REAL_MV" "$@"
  : > "$FAIL_MV_MARKER"
  exit 1
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock_bin/mv"
if PATH="$mock_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_TARGET="$target" FAIL_MV_MARKER="$test_root/mv-failed-once" \
  HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/rollback.out" 2>&1; then
  printf 'not ok - simulated deployment failure should fail\n' >&2; exit 1
fi
contains 'rollback is reported' 'Restored: .config/kitty/kitty.conf' "$(<"$test_root/rollback.out")"
assert 'rollback restores original target content' test "$(cat "$target")" = 'rollback sentinel'
assert 'rollback restores original target mode' test "$(stat -c '%a' "$target")" = 640
assert 'rollback retains a recoverable backup' test -n "$(find "$home" -name 'kitty.conf.arclith-backup.*' -type f -print -quit)"

rm -rf "$fixture/core/configs/kitty"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/missing.out" 2>&1; then
  printf 'not ok - missing source should fail\n' >&2; exit 1
fi
contains 'missing source is rejected' 'source status is unavailable' "$(<"$test_root/missing.out")"

mkdir -p "$fixture/core/configs/kitty"
printf 'unsafe source\n' > "$test_root/outside.conf"
ln -s "$test_root/outside.conf" "$fixture/core/configs/kitty/kitty.conf"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/source-link.out" 2>&1; then
  printf 'not ok - symlinked source should fail\n' >&2; exit 1
fi
contains 'symlinked source is rejected' 'source status is unsafe-entry' "$(<"$test_root/source-link.out")"

rm "$fixture/core/configs/kitty/kitty.conf"
: > "$fixture/core/configs/kitty/kitty.conf"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/empty.out" 2>&1; then
  printf 'not ok - empty source should fail\n' >&2; exit 1
fi
contains 'empty source file is rejected' 'must be non-empty text' "$(<"$test_root/empty.out")"

printf 'invalid\0binary\n' > "$fixture/core/configs/kitty/kitty.conf"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/binary.out" 2>&1; then
  printf 'not ok - binary source should fail\n' >&2; exit 1
fi
contains 'binary source file is rejected' 'must be non-empty text' "$(<"$test_root/binary.out")"

printf 'safe source\n' > "$fixture/core/configs/kitty/kitty.conf"
rm -rf "$home/.config/kitty"
mkdir -p "$target"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/target-directory.out" 2>&1; then
  printf 'not ok - directory at file target should fail\n' >&2; exit 1
fi
contains 'directory at file target is rejected' 'not a regular file' "$(<"$test_root/target-directory.out")"
rm -rf "$home/.config/kitty"
ln -s "$test_root" "$home/.config/kitty"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/target-link.out" 2>&1; then
  printf 'not ok - symlink target parent should fail\n' >&2; exit 1
fi
contains 'symlinked target parent is rejected' 'Unsafe target parent contains a symlink' "$(<"$test_root/target-link.out")"

printf 'All configuration deployment tests passed.\n'
