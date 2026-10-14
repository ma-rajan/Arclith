#!/usr/bin/env bash
set -Eeuo pipefail

# Design-level check only: exercise Linux flock semantics in a temporary
# directory. Arclith does not yet acquire this lock in production.
if ! command -v flock >/dev/null 2>&1; then
  printf 'unavailable - flock is not installed; production transaction locking is not implemented\n'
  exit 0
fi

test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-lock-design.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
lock_file="$test_root/operation.lock"
umask 077
: > "$lock_file"

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

# An existing lock-file inode without a kernel lock is stale metadata only.
assert 'an unlocked existing lock file does not block acquisition' flock -n -x "$lock_file" true

exec {lock_fd}>"$lock_file"
flock -x "$lock_fd"
if flock -n -x "$lock_file" true; then
  printf 'not ok - competing process acquired a held exclusive lock\n' >&2
  exit 1
else
  printf 'ok - competing process is rejected while the exclusive lock is held\n'
fi

flock -u "$lock_fd"
exec {lock_fd}>&-
assert 'lock becomes available after release' flock -n -x "$lock_file" true

printf 'Design primitive checks passed; Arclith production paths are not locked by this test.\n'
