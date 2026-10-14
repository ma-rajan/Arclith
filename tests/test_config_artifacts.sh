#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-artifact-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
home="$test_root/home"
mkdir -p "$fixture" "$home/.config/kitty"
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
  local base=$1
  (cd -- "$base" && find . -mindepth 1 -printf '%y|%m|%u|%g|%p|%l\n' | LC_ALL=C sort)
  (cd -- "$base" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

target="$home/.config/kitty/kitty.conf"
printf 'pre-deployment user settings\n' > "$target"
HOME="$home" "$fixture/arclith.sh" config apply kitty --yes > "$test_root/apply.out"
tracked_backup=$(find "$home/.config/kitty" -maxdepth 1 -type f -name 'kitty.conf.arclith-backup.*' -print -quit)
backup_id=${tracked_backup##*.arclith-backup.}
assert 'fixture has a recorded backup' test -n "$tracked_backup"

printf 'synthetic stage\n' > "$target.arclith-new.ABC12345"
printf 'synthetic restore stage\n' > "$target.arclith-restore.BCD23456"
printf 'synthetic rollback stage\n' > "$target.arclith-rollback.CDE34567"
printf 'malformed suffix\n' > "$target.arclith-new.bad-name"
printf 'unrelated user note\n' > "$home/.config/kitty/notes.txt"
printf 'outside sentinel\n' > "$test_root/outside"
ln -s "$test_root/outside" "$target.arclith-new.DEF45678"
state_dir="$home/.local/state/arclith"
printf 'unread state temp content\n' > "$state_dir/.deployments.ABC45678"
ln -s "$test_root/outside" "$state_dir/.deployments-old.DEF56789"

before=$(snapshot "$home")
first_output=$(HOME="$home" "$fixture/arclith.sh" config artifacts)
after_first=$(snapshot "$home")
second_output=$(HOME="$home" "$fixture/arclith.sh" config artifacts)
after_second=$(snapshot "$home")
contains 'inventory validates a tracked backup' "TRACKED valid BACKUP  $backup_id  kitty  .config/kitty/kitty.conf" "$first_output"
contains 'inventory does not claim transaction liveness' 'no operation journal or live-operation marker' "$first_output"
contains 'inventory reports an untracked stage as uncertain' 'UNTRACKED UNCERTAIN CANDIDATE  new' "$first_output"
contains 'inventory reports restore staging candidates' 'UNTRACKED UNCERTAIN CANDIDATE  restore' "$first_output"
contains 'inventory reports rollback staging candidates' 'UNTRACKED UNCERTAIN CANDIDATE  rollback' "$first_output"
contains 'inventory reports malformed known artifact names' 'UNTRACKED MALFORMED-NAME CANDIDATE  new' "$first_output"
contains 'inventory does not follow artifact symlinks' 'UNTRACKED UNSAFE SYMLINK CANDIDATE  new' "$first_output"
contains 'inventory reports possible state recovery files without opening them' 'UNTRACKED UNCERTAIN STATE CANDIDATE' "$first_output"
contains 'inventory reports state symlinks without following them' 'UNTRACKED UNSAFE STATE SYMLINK' "$first_output"
assert 'inventory ignores unrelated files' bash -c '[[ "$1" != *notes.txt* ]]' _ "$first_output"
assert 'inventory does not change files or persistent state' test "$before" = "$after_first"
assert 'repeated inventory output is stable' test "$first_output" = "$second_output"
assert 'repeated inventory remains read-only' test "$before" = "$after_second"
assert 'inventory leaves symlink destination unchanged' test "$(cat "$test_root/outside")" = 'outside sentinel'

rm -f -- "$tracked_backup"
missing_output=$(HOME="$home" "$fixture/arclith.sh" config artifacts)
contains 'inventory distinguishes a missing tracked backup' "TRACKED missing BACKUP  $backup_id" "$missing_output"

state_file="$state_dir/deployments.v1"
state_good="$test_root/state.good"
cp -- "$state_file" "$state_good"
printf 'unsupported\n' > "$state_file"
chmod 600 "$state_file"
malformed_before=$(snapshot "$home")
if HOME="$home" "$fixture/arclith.sh" config artifacts > "$test_root/malformed.out" 2>&1; then
  printf 'not ok - malformed state should make inventory fail closed\n' >&2; exit 1
fi
contains 'inventory rejects malformed deployment state' 'Unsupported deployment state manifest version' "$(<"$test_root/malformed.out")"
assert 'inventory does not repair malformed deployment state' test "$malformed_before" = "$(snapshot "$home")"
cp -- "$state_good" "$state_file"
chmod 600 "$state_file"

if chmod 000 "$state_dir" && [[ ! -x $state_dir ]]; then
  state_dir_mode=$(stat -c '%a' "$state_dir")
  if HOME="$home" "$fixture/arclith.sh" config artifacts > "$test_root/inaccessible-state.out" 2>&1; then
    printf 'not ok - inaccessible state should make inventory fail closed\n' >&2; chmod 700 "$state_dir"; exit 1
  fi
  contains 'inventory refuses inaccessible deployment state' 'Cannot inspect deployment state' "$(<"$test_root/inaccessible-state.out")"
  assert 'inventory leaves inaccessible state permissions unchanged' test "$(stat -c '%a' "$state_dir")" = "$state_dir_mode"
  chmod 700 "$state_dir"
else
  chmod 700 "$state_dir"
  printf 'unavailable - permission denial on deployment state is not reliable for this test process\n'
fi

blocked_home="$test_root/blocked-home"
mkdir -p "$blocked_home"
HOME="$blocked_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
blocked_parent="$blocked_home/.config/kitty"
printf 'candidate\n' > "$blocked_parent/kitty.conf.arclith-new.FGH67890"
if chmod 000 "$blocked_parent" && [[ ! -x $blocked_parent ]]; then
  if HOME="$blocked_home" "$fixture/arclith.sh" config artifacts > "$test_root/blocked.out" 2>&1; then
    printf 'not ok - inaccessible inventory path should return failure\n' >&2; chmod 700 "$blocked_parent"; exit 1
  fi
  contains 'inventory reports inaccessible scan scope' 'SCAN INCOMPLETE inaccessible target directory' "$(<"$test_root/blocked.out")"
  chmod 700 "$blocked_parent"
else
  chmod 700 "$blocked_parent"
  printf 'unavailable - permission denial is not reliable for this test process\n'
fi

printf 'All configuration artifact inventory tests passed.\n'
