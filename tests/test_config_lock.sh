#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-lock-tests.XXXXXX")
holder_pid=
cleanup() {
  if [[ -n $holder_pid ]]; then
    kill -TERM "$holder_pid" 2>/dev/null || true
    wait "$holder_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source "$repo_root/core/config.sh"

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
contains() {
  local description=$1 expected=$2 output=$3
  if [[ $output == *"$expected"* ]]; then
    printf 'ok - %s\n' "$description"
  else
    printf 'not ok - %s (missing: %s)\n' "$description" "$expected" >&2
    exit 1
  fi
}
fails_with() {
  local description=$1 expected=$2 output_file=$3
  if config_lock_acquire "$4" >"$output_file" 2>&1; then
    printf 'not ok - %s\n' "$description" >&2
    exit 1
  fi
  contains "$description" "$expected" "$(<"$output_file")"
}

real_flock=$(command -v flock || true)
if [[ -z $real_flock ]]; then
  no_flock_home="$test_root/no-flock-home"
  mkdir -p "$no_flock_home"
  missing_status=0
  missing_output=$(config_lock_acquire "$no_flock_home" 2>&1) || missing_status=$?
  assert 'missing system flock fails closed' test "$missing_status" -eq 1
  contains 'missing system flock is explained' 'flock is unavailable' "$missing_output"
  printf 'unavailable - system flock absent; acquisition and contention checks skipped\n'
  printf 'Configuration lock helper missing-dependency test passed.\n'
  exit 0
fi

home="$test_root/home"
mkdir -p "$home/.local/state/arclith"
chmod 700 "$home/.local/state/arclith"
lock_file="$home/.local/state/arclith/operation.lock"

# A preexisting, unlocked file is metadata only; the kernel lock is acquired
# on the open descriptor and remains held across caller work.
printf '999999 stale metadata\n' > "$lock_file"
chmod 600 "$lock_file"
config_lock_acquire "$home"
assert 'successful acquisition stores an open descriptor' test "$CONFIG_LOCK_FD" -ge 10
assert 'lock file is owner-only' test "$(stat -c '%a' "$lock_file")" = 600
assert 'lock file is owned by the current user' test "$(stat -c '%u' "$lock_file")" = "$EUID"
assert 'stale lock-file contents are not treated as liveness or rewritten' test "$(cat "$lock_file")" = '999999 stale metadata'
assert 'caller operation can run while lock is held' test -n "$CONFIG_LOCK_FD"

contender_status=0
if ( source "$repo_root/core/config.sh"; config_lock_acquire "$home" ) >"$test_root/contender.out" 2>&1; then
  printf 'not ok - competing process acquired a held lock\n' >&2
  exit 1
else
  contender_status=$?
fi
assert 'competing process returns the distinct busy status' test "$contender_status" -eq "$CONFIG_LOCK_BUSY_STATUS"
contains 'contention diagnostic is explicit' 'Another Arclith configuration operation holds the lock' "$(<"$test_root/contender.out")"
subshell_release_status=0
if ( config_lock_release ) >"$test_root/subshell-release.out" 2>&1; then
  printf 'not ok - a different Bash process released the owning shell lock\n' >&2
  exit 1
else
  subshell_release_status=$?
fi
assert 'release from a different Bash process is refused' test "$subshell_release_status" -eq 1
contains 'cross-process release failure is explicit' 'must be released by the Bash process that acquired it' \
  "$(<"$test_root/subshell-release.out")"
config_lock_release
assert 'release clears the helper descriptor' test -z "$CONFIG_LOCK_FD"
config_lock_acquire "$home"
config_lock_release
printf 'ok - acquisition succeeds after normal release\n'

# A returned operation error does not itself release the caller-owned lock;
# the caller releases it in its cleanup path.
config_lock_acquire "$home"
operation_status=0
( exit 42 ) || operation_status=$?
assert 'simulated operation failure is observed' test "$operation_status" -eq 42
config_lock_release
config_lock_acquire "$home"
config_lock_release
printf 'ok - caller can release and reacquire after simulated operation failure\n'

# Normal child-shell exit closes the owning descriptor automatically.
exit_home="$test_root/exit-home"
mkdir -p "$exit_home"
(
  source "$repo_root/core/config.sh"
  config_lock_acquire "$exit_home"
)
assert 'missing state directory is created privately' test "$(stat -c '%a' "$exit_home/.local/state/arclith")" = 700
config_lock_acquire "$exit_home"
config_lock_release
printf 'ok - process exit releases the kernel-held lock\n'

# This test sends TERM to a process that is actively holding the descriptor.
# It is a real process-termination check, not a mocked function failure.
signal_home="$test_root/signal-home"
signal_marker="$test_root/holder.ready"
mkdir -p "$signal_home"
(
  source "$repo_root/core/config.sh"
  config_lock_acquire "$signal_home" || exit
  : > "$signal_marker"
  while :; do :; done
) >"$test_root/holder.out" 2>&1 &
holder_pid=$!
ready=no
for ((attempt=0; attempt<200; attempt++)); do
  if [[ -f $signal_marker ]]; then ready=yes; break; fi
  kill -0 "$holder_pid" 2>/dev/null || break
  sleep 0.01
done
assert 'signal-test holder acquired the lock within the bounded wait' test "$ready" = yes
kill -TERM "$holder_pid"
signal_status=0
wait "$holder_pid" || signal_status=$?
holder_pid=
assert 'SIGTERM terminated the lock-owning test process' test "$signal_status" -ne 0
config_lock_acquire "$signal_home"
config_lock_release
printf 'ok - OS releases the lock after process termination by SIGTERM\n'

# Invalid, symlinked, and overly permissive paths are refused.
fails_with 'missing home is rejected' 'existing absolute, non-symlink home directory' \
  "$test_root/missing-home.out" "$test_root/missing-home"
unsafe_home="$test_root/unsafe-home"
mkdir -p "$unsafe_home/.local/state"
outside="$test_root/outside"
printf 'outside sentinel\n' > "$outside"
ln -s "$outside" "$unsafe_home/.local/state/arclith"
fails_with 'symlinked state directory is rejected' 'Unsafe configuration lock state path' \
  "$test_root/state-symlink.out" "$unsafe_home"
assert 'state symlink destination is untouched' test "$(cat "$outside")" = 'outside sentinel'

unsafe_lock_home="$test_root/unsafe-lock-home"
mkdir -p "$unsafe_lock_home/.local/state/arclith"
chmod 700 "$unsafe_lock_home/.local/state/arclith"
ln -s "$outside" "$unsafe_lock_home/.local/state/arclith/operation.lock"
fails_with 'symlinked lock file is rejected' 'Unsafe configuration lock file' \
  "$test_root/lock-symlink.out" "$unsafe_lock_home"
assert 'lock symlink destination is untouched' test "$(cat "$outside")" = 'outside sentinel'

unsafe_mode_home="$test_root/unsafe-mode-home"
mkdir -p "$unsafe_mode_home/.local/state/arclith"
chmod 700 "$unsafe_mode_home/.local/state/arclith"
: > "$unsafe_mode_home/.local/state/arclith/operation.lock"
chmod 640 "$unsafe_mode_home/.local/state/arclith/operation.lock"
fails_with 'permissive lock-file mode is rejected' 'private, single-link regular file' \
  "$test_root/lock-mode.out" "$unsafe_mode_home"

hardlink_home="$test_root/hardlink-home"
mkdir -p "$hardlink_home/.local/state/arclith"
chmod 700 "$hardlink_home/.local/state/arclith"
: > "$hardlink_home/.local/state/arclith/operation.lock"
chmod 600 "$hardlink_home/.local/state/arclith/operation.lock"
ln "$hardlink_home/.local/state/arclith/operation.lock" "$test_root/lock-alias"
fails_with 'multiply linked lock file is rejected' 'private, single-link regular file' \
  "$test_root/lock-hardlink.out" "$hardlink_home"

permissive_home="$test_root/permissive-home"
mkdir -p "$permissive_home/.local/state/arclith"
chmod 755 "$permissive_home/.local/state/arclith"
fails_with 'permissive state directory is rejected' 'permissions must exclude group and other access' \
  "$test_root/permissive.out" "$permissive_home"

inaccessible_home="$test_root/inaccessible-home"
mkdir -p "$inaccessible_home/.local/state/arclith"
chmod 700 "$inaccessible_home/.local/state/arclith"
chmod 000 "$inaccessible_home/.local"
if [[ ! -x $inaccessible_home/.local ]]; then
  inaccessible_status=0
  inaccessible_output=$(config_lock_acquire "$inaccessible_home" 2>&1) || inaccessible_status=$?
  chmod 700 "$inaccessible_home/.local"
  assert 'untraversable state parent is rejected' test "$inaccessible_status" -eq 1
  contains 'untraversable parent failure is explicit' 'Configuration lock parent' "$inaccessible_output"
  printf 'ok - genuine parent traversal denial is fail-closed\n'
else
  printf 'unavailable - current process can traverse mode-000 parent (DAC override)\n'
  chmod 700 "$inaccessible_home/.local"
fi

# Use a private PATH containing the system helpers required by the function
# but no flock executable, without changing the host environment.
mock_bin="$test_root/mock-bin"
mkdir -p "$mock_bin"
ln -s "$(command -v stat)" "$mock_bin/stat"
ln -s "$(command -v mkdir)" "$mock_bin/mkdir"
missing_flock_home="$test_root/missing-flock-home"
mkdir -p "$missing_flock_home"
original_path=$PATH
missing_status=0
missing_output=$(PATH="$mock_bin" config_lock_acquire "$missing_flock_home" 2>&1) || missing_status=$?
PATH=$original_path
assert 'missing flock fails closed' test "$missing_status" -eq 1
contains 'missing flock has an actionable diagnostic' 'flock is unavailable' "$missing_output"
assert 'missing flock leaves no held descriptor' test -z "$CONFIG_LOCK_FD"
assert 'missing flock leaves only the expected private lock file' \
  test -f "$missing_flock_home/.local/state/arclith/operation.lock"
assert 'missing flock preserves lock-file mode 600' \
  test "$(stat -c '%a' "$missing_flock_home/.local/state/arclith/operation.lock")" = 600
assert 'missing flock does not create a deployment manifest' \
  test ! -e "$missing_flock_home/.local/state/arclith/deployments.v1"

if [[ -n $real_flock ]]; then
  # A controlled executable failure is distinct from the configured busy code.
  fail_bin="$test_root/fail-bin"
  mkdir -p "$fail_bin"
  ln -s "$(command -v stat)" "$fail_bin/stat"
  cat > "$fail_bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 76
EOF
  chmod 700 "$fail_bin/flock"
  failed_flock_home="$test_root/failed-flock-home"
  mkdir -p "$failed_flock_home"
  original_path=$PATH
  PATH="$fail_bin:$PATH"
  acquisition_status=0
  acquisition_output=$(config_lock_acquire "$failed_flock_home" 2>&1) || acquisition_status=$?
  PATH=$original_path
  assert 'unexpected flock failure is not treated as contention' test "$acquisition_status" -eq 1
  contains 'unexpected flock failure reports its status' 'flock status 76' "$acquisition_output"
  assert 'failed acquisition closes its descriptor' test -z "$CONFIG_LOCK_FD"
  config_lock_acquire "$failed_flock_home"
  config_lock_release

  cat > "$fail_bin/flock" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [[ $arg != -u ]] || exit 76
done
exec "$REAL_FLOCK" "$@"
EOF
  chmod 700 "$fail_bin/flock"
  export REAL_FLOCK=$real_flock
  PATH="$fail_bin:$PATH"
  config_lock_acquire "$failed_flock_home"
  release_status=0
  config_lock_release >"$test_root/unlock-failure.out" 2>&1 || release_status=$?
  PATH=$original_path
  release_output=$(<"$test_root/unlock-failure.out")
  assert 'explicit unlock failure is reported' test "$release_status" -eq 1
  contains 'unlock failure explains descriptor closure' 'closing its descriptor to release it' "$release_output"
  assert 'unlock failure still closes the descriptor' test -z "$CONFIG_LOCK_FD"
  config_lock_acquire "$failed_flock_home"
  config_lock_release
  printf 'ok - descriptor closure releases after explicit unlock failure\n'
else
  printf 'unavailable - system flock absent; real acquisition and contention checks skipped\n'
fi

printf 'Configuration lock helper tests passed; all state paths were isolated under %s.\n' "$test_root"
