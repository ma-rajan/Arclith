#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-interruption-evidence.XXXXXX")
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"
real_mv=$(command -v mv)
active_app_pid=
active_mv_pid=
cleanup() {
  if [[ -n $active_app_pid ]]; then kill -KILL "$active_app_pid" 2>/dev/null || true; wait "$active_app_pid" 2>/dev/null || true; fi
  if [[ -n $active_mv_pid ]]; then kill -KILL "$active_mv_pid" 2>/dev/null || true; wait "$active_mv_pid" 2>/dev/null || true; fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$mock_bin/mv" <<'MOCK'
#!/usr/bin/env bash
destination=${!#}
source_path=${@: -2:1}
pause_here() {
  printf '%s %s\n' "$$" "$PPID" > "$READY_FIFO"
  IFS= read -r _ < "$HOLD_FIFO"
}
case ${INTERRUPT_POINT:-} in
  apply-after-rename)
    if [[ $destination == "$LIVE_TARGET" && $source_path == *.arclith-new.* ]]; then
      "$REAL_MV" "$@" || exit $?
      pause_here
    fi
    ;;
  after-rename)
    if [[ $destination == "$LIVE_TARGET" && $source_path == *.arclith-restore.* ]]; then
      "$REAL_MV" "$@" || exit $?
      pause_here
    fi
    ;;
  after-verification)
    if [[ $destination == */transactions/*.targets/000000.v2 ]] \
      && grep -q '^STATE|APPLIED$' "$source_path"; then
      pause_here
    fi
    ;;
  before-complete)
    if [[ $destination == */transactions/*.v1 && $destination != */transactions/*.targets/*.v1 ]] \
      && grep -q '^STATE|COMPLETE$' "$source_path"; then
      pause_here
    fi
    ;;
  rollback-after-rename)
    if [[ $destination == "$STATE_TARGET" && $source_path == *deployments.* && ! -e $STATE_FAILURE_MARKER ]]; then
      : > "$STATE_FAILURE_MARKER"
      exit 71
    fi
    if [[ $destination == "$LIVE_TARGET" && $source_path == *.arclith-rollback.* ]]; then
      "$REAL_MV" "$@" || exit $?
      pause_here
    fi
    ;;
esac
exec "$REAL_MV" "$@"
MOCK
chmod +x "$mock_bin/mv"

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

run_abrupt_stop() {
  local point=$1 ready_fifo="$test_root/$1.ready" hold_fifo="$test_root/$1.hold" ready_fd hold_fd line wrapper_pid app_pid
  mkfifo "$ready_fifo" "$hold_fifo"
  exec {ready_fd}<>"$ready_fifo"
  exec {hold_fd}<>"$hold_fifo"
  local -a command
  if [[ $point == apply-after-rename ]]; then command=(config apply-new kitty --yes)
  else command=(config restore "$source_backup_id" --yes); fi
  INTERRUPT_POINT="$point" READY_FIFO="$ready_fifo" HOLD_FIFO="$hold_fifo" LIVE_TARGET="$target" \
    STATE_TARGET="$home/.local/state/arclith/deployments.v1" STATE_FAILURE_MARKER="$test_root/$point.state-failed" \
    REAL_MV="$real_mv" PATH="$mock_bin:$PATH" HOME="$home" \
    "$repo_root/arclith.sh" "${command[@]}" >"$test_root/$point.out" 2>&1 &
  active_app_pid=$!
  if ! IFS=' ' read -r -t 15 wrapper_pid app_pid <&"$ready_fd"; then
    cat "$test_root/$point.out" >&2
    printf 'not ok - controlled interruption point was not reached: %s\n' "$point" >&2
    exit 1
  fi
  active_mv_pid=$wrapper_pid
  [[ $app_pid == "$active_app_pid" ]] || {
    printf 'not ok - controlled mv parent did not match the task-owned command (command=%s parent=%s)\n' \
      "$active_app_pid" "$app_pid" >&2
    exit 1
  }
  kill -KILL "$active_app_pid"
  kill -KILL "$active_mv_pid"
  wait "$active_app_pid" 2>/dev/null || true
  wait "$active_mv_pid" 2>/dev/null || true
  active_app_pid=
  active_mv_pid=
  exec {ready_fd}>&-
  exec {hold_fd}>&-
}

latest_transaction() {
  local path
  path=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' \
    -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  [[ -n $path ]] || return 1
  printf '%s' "${path##*/}" | sed 's/\.v1$//'
}

# Each snapshot is taken after process death and before the read-only inspector.
# The controlled wrapper reports readiness only at the requested operation boundary.
for point in after-rename after-verification before-complete; do
  home="$test_root/$point/home"
  target="$home/.config/kitty/kitty.conf"
  mkdir -p "$home/.config/kitty"
  printf 'pre-deployment user configuration\n' > "$target"
  HOME="$home" "$repo_root/arclith.sh" config apply kitty --yes >/dev/null
  source_backup_id=$(HOME="$home" "$repo_root/arclith.sh" config backups | awk '/available$/{print $1; exit}')
  [[ $source_backup_id =~ ^[A-Za-z0-9]{8}$ ]] || { printf 'not ok - fixture source backup is unavailable\n' >&2; exit 1; }
  source_backup="$target.arclith-backup.$source_backup_id"
  [[ -f $source_backup ]] || { printf 'not ok - fixture source backup file is missing\n' >&2; exit 1; }
  run_abrupt_stop "$point"
  transaction=$(latest_transaction)
  journal="$home/.local/state/arclith/transactions/$transaction.v1"
  target_record="$home/.local/state/arclith/transactions/$transaction.targets/000000.v2"
  cp -- "$journal" "$test_root/journal.before-inspection"
  cp -- "$target_record" "$test_root/target-record.before-inspection"
  cp -- "$target" "$test_root/target.before-inspection"
  cp -- "$source_backup" "$test_root/source-backup.before-inspection"
  source "$repo_root/core/config.sh"
  config_transaction_target_read "$home" "$transaction" 000000
  rollback_backup="$target.arclith-backup.$CONFIG_TXN_TARGET_ROLLBACK_BACKUP"
  cp -- "$rollback_backup" "$test_root/rollback-backup.before-inspection"
  case $point in
    after-rename) expected_target=MUTATION_INTENT; expected_tx=APPLYING ;;
    after-verification) expected_target=MUTATION_INTENT; expected_tx=APPLYING ;;
    before-complete) expected_target=APPLIED; expected_tx=COMMITTING ;;
  esac
  source "$repo_root/core/config.sh"
  config_transaction_journal_read "$home" "$transaction"
  assert "$point leaves a nonterminal transaction state" test "$CONFIG_TXN_JOURNAL_STATE" = "$expected_tx"
  config_transaction_target_read "$home" "$transaction" 000000
  assert "$point records the expected last target checkpoint" test "$CONFIG_TXN_TARGET_STATE" = "$expected_target"
  assert "$point leaves target bytes matching the selected restore backup" cmp -s "$target" "$source_backup"
  assert "$point retains the selected source backup" test -f "$source_backup"
  assert "$point retains the rollback recovery copy" test -f "$rollback_backup"
  detail=$(HOME="$home" "$repo_root/arclith.sh" config transactions "$transaction")
  HOME="$home" "$repo_root/arclith.sh" config artifacts > "$test_root/$point.artifacts.out"
  contains "$point inspection labels the transaction in progress" 'IN_PROGRESS' "$detail"
  contains "$point inspection identifies journal-only evidence" 'filesystem_check=NOT_PERFORMED target_and_manifest_outcomes=UNVERIFIED' "$detail"
  assert "$point inspection leaves journal bytes unchanged" cmp -s "$journal" "$test_root/journal.before-inspection"
  assert "$point inspection leaves target checkpoint bytes unchanged" cmp -s "$target_record" "$test_root/target-record.before-inspection"
  assert "$point inspection leaves the live target unchanged" cmp -s "$target" "$test_root/target.before-inspection"
  assert "$point inspection leaves both recovery copies unchanged" \
    cmp -s "$source_backup" "$test_root/source-backup.before-inspection" \
    && cmp -s "$rollback_backup" "$test_root/rollback-backup.before-inspection"
  if [[ $point == after-rename ]]; then
    # This command gets the lock normally, sees that the restored target no
    # longer matches managed state, and must preserve it rather than replace it.
    target_hash=$(sha256sum -- "$target")
    printf 'n\n' | HOME="$home" "$repo_root/arclith.sh" config apply kitty >"$test_root/reapply.out" 2>&1 || true
    assert 'subsequent apply preserves the target that differs from managed state' \
      test "$(sha256sum -- "$target")" = "$target_hash"
    contains 'subsequent apply requires explicit confirmation before replacement' 'Continue? [y/N]:' "$(<"$test_root/reapply.out")"
    assert 'subsequent apply preserves source and rollback recovery copies' \
      test -f "$source_backup" -a -f "$rollback_backup"
  fi
  rm -f -- "$test_root/journal.before-inspection" "$test_root/target-record.before-inspection" "$test_root/target.before-inspection" \
    "$test_root/source-backup.before-inspection" "$test_root/rollback-backup.before-inspection"
done

# Apply interruption leaves an originally absent target installed after its
# rename while the target checkpoint still records only MUTATION_INTENT.
home="$test_root/apply-after-rename/home"
target="$home/.config/kitty/kitty.conf"
mkdir -p "$home"
run_abrupt_stop apply-after-rename
transaction=$(latest_transaction)
journal="$home/.local/state/arclith/transactions/$transaction.v1"
target_record="$home/.local/state/arclith/transactions/$transaction.targets/000000.v1"
cp -- "$journal" "$test_root/apply-journal.before-inspection"
cp -- "$target_record" "$test_root/apply-target-record.before-inspection"
source "$repo_root/core/config.sh"
config_transaction_journal_read "$home" "$transaction"
assert 'abrupt apply leaves an incomplete transaction' test "$CONFIG_TXN_JOURNAL_STATE" = APPLYING
assert 'abrupt apply is distinguished from restore' test "$CONFIG_TXN_JOURNAL_OPERATION" = apply-new
config_transaction_target_read "$home" "$transaction" 000000
assert 'abrupt apply keeps the last checkpoint at MUTATION_INTENT' test "$CONFIG_TXN_TARGET_STATE" = MUTATION_INTENT
assert 'abrupt apply records that the target was originally absent' test "$CONFIG_TXN_TARGET_ORIGINAL" = no
assert 'abrupt apply has no original-target backup to preserve' test "$CONFIG_TXN_TARGET_BACKUP" = -
assert 'abrupt apply leaves the renamed target in place' cmp -s "$target" "$repo_root/core/configs/kitty/kitty.conf"
apply_detail=$(HOME="$home" "$repo_root/arclith.sh" config transactions "$transaction")
contains 'abrupt apply inspection remains in progress' 'IN_PROGRESS' "$apply_detail"
assert 'abrupt apply inspection leaves journal unchanged' cmp -s "$journal" "$test_root/apply-journal.before-inspection"
assert 'abrupt apply inspection leaves target checkpoint unchanged' \
  cmp -s "$target_record" "$test_root/apply-target-record.before-inspection"
rm -f -- "$test_root/apply-journal.before-inspection" "$test_root/apply-target-record.before-inspection"
apply_target_hash=$(sha256sum -- "$target")
HOME="$home" "$repo_root/arclith.sh" config apply-new kitty --yes > "$test_root/apply-after-rename.retry.out" 2>&1
assert 'subsequent apply-new preserves the untracked target from the interrupted apply' \
  test "$(sha256sum -- "$target")" = "$apply_target_hash"
contains 'subsequent apply-new reports an existing unmanaged conflict' 'UNMANAGED CONFLICT' \
  "$(<"$test_root/apply-after-rename.retry.out")"

# A restore whose manifest save fails enters rollback. Killing its own process
# after rollback rename but before ROLLED_BACK leaves the intent checkpoint and
# both the original source backup and rollback copy available for review.
home="$test_root/rollback-after-rename/home"
target="$home/.config/kitty/kitty.conf"
mkdir -p "$home/.config/kitty"
printf 'rollback fixture original\n' > "$target"
HOME="$home" "$repo_root/arclith.sh" config apply kitty --yes >/dev/null
source_backup_id=$(HOME="$home" "$repo_root/arclith.sh" config backups | awk '/available$/{print $1; exit}')
[[ $source_backup_id =~ ^[A-Za-z0-9]{8}$ ]] || { printf 'not ok - rollback source backup is unavailable\n' >&2; exit 1; }
source_backup="$target.arclith-backup.$source_backup_id"
run_abrupt_stop rollback-after-rename
transaction=$(latest_transaction)
journal="$home/.local/state/arclith/transactions/$transaction.v1"
target_record="$home/.local/state/arclith/transactions/$transaction.targets/000000.v2"
source "$repo_root/core/config.sh"
config_transaction_journal_read "$home" "$transaction"
assert 'abrupt rollback remains in ROLLING_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLING_BACK
config_transaction_target_read "$home" "$transaction" 000000
assert 'abrupt rollback retains the ROLLBACK_INTENT checkpoint' test "$CONFIG_TXN_TARGET_STATE" = ROLLBACK_INTENT
rollback_backup="$target.arclith-backup.$CONFIG_TXN_TARGET_ROLLBACK_BACKUP"
assert 'abrupt rollback preserves the selected source backup' test -f "$source_backup"
assert 'abrupt rollback preserves its separate rollback copy' test -f "$rollback_backup"
assert 'rollback rename restored the prior target bytes before death' \
  cmp -s "$target" "$repo_root/core/configs/kitty/kitty.conf"
cp -- "$journal" "$test_root/rollback-journal.before-inspection"
cp -- "$target_record" "$test_root/rollback-target-record.before-inspection"
cp -- "$target" "$test_root/rollback-target.before-inspection"
cp -- "$source_backup" "$test_root/rollback-source-backup.before-inspection"
cp -- "$rollback_backup" "$test_root/rollback-copy.before-inspection"
rollback_detail=$(HOME="$home" "$repo_root/arclith.sh" config transactions "$transaction")
HOME="$home" "$repo_root/arclith.sh" config artifacts > "$test_root/rollback-artifacts.out"
contains 'abrupt rollback inspection reports an in-progress transaction' 'IN_PROGRESS' "$rollback_detail"
contains 'abrupt rollback inspection does not claim filesystem verification' \
  'filesystem_check=NOT_PERFORMED target_and_manifest_outcomes=UNVERIFIED' "$rollback_detail"
assert 'abrupt rollback inspection leaves journal unchanged' \
  cmp -s "$journal" "$test_root/rollback-journal.before-inspection"
assert 'abrupt rollback inspection leaves checkpoint unchanged' \
  cmp -s "$target_record" "$test_root/rollback-target-record.before-inspection"
assert 'abrupt rollback inspection leaves target unchanged' \
  cmp -s "$target" "$test_root/rollback-target.before-inspection"
assert 'abrupt rollback inspection leaves both recovery copies unchanged' \
  cmp -s "$source_backup" "$test_root/rollback-source-backup.before-inspection" \
  && cmp -s "$rollback_backup" "$test_root/rollback-copy.before-inspection"

printf 'Configuration interruption evidence tests passed.\n'
