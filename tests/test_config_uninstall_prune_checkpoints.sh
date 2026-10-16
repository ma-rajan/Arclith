#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-remove-checkpoints.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source "$repo_root/core/config.sh"
real_cp=$(command -v cp)
real_mv=$(command -v mv)
real_rm=$(command -v rm)

assert() {
  local description=$1; shift
  if "$@"; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}
new_fixture() {
  local name=$1 source_dir
  FIXTURE="$test_root/$name/project"
  HOME_FIXTURE="$test_root/$name/home"
  source_dir="$FIXTURE/core/configs/kitty/checkpoint-fixture"
  mkdir -p "$FIXTURE" "$HOME_FIXTURE/.config/kitty" "$source_dir"
  cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
    "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$FIXTURE/"
  printf 'alpha managed\n' > "$source_dir/alpha.conf"
  printf 'beta managed\n' > "$source_dir/beta.conf"
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes >/dev/null
  ALPHA_TARGET="$HOME_FIXTURE/.config/kitty/checkpoint-fixture/alpha.conf"
  BETA_TARGET="$HOME_FIXTURE/.config/kitty/checkpoint-fixture/beta.conf"
  MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1"
}
latest_transaction() {
  local home=$1 operation=$2 path
  path=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' \
    | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  [[ -n $path ]] || return 1
  printf '%s' "${path##*/}" | sed 's/\.v1$//'
}
target_read() { config_transaction_target_read "$1" "$2" "$3"; }

# Uninstall checkpoints every inspectable target and retains a verified
# recovery artifact for each target actually removed.
new_fixture uninstall-multiple
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall.out"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'multi-target uninstall reaches COMPLETE' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
assert 'uninstall keeps its operation identity' test "$CONFIG_TXN_JOURNAL_OPERATION" = uninstall
assert 'uninstall removes multiple selected targets' bash -c '[[ ! -e $1 && ! -e $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
target_count=0
for record in "$HOME_FIXTURE/.local/state/arclith/transactions/$transaction.targets"/*.v1; do
  index=${record##*/}; index=${index%.v1}
  target_read "$HOME_FIXTURE" "$transaction" "$index"
  [[ $CONFIG_TXN_TARGET_STATE == APPLIED && $CONFIG_TXN_TARGET_BACKUP =~ ^[A-Za-z0-9]{8}$ ]] || exit 1
  ((target_count += 1))
done
assert 'uninstall records every deletion as APPLIED with a backup reference' test "$target_count" -eq 3
assert 'uninstall lock is released after success' config_lock_acquire "$HOME_FIXTURE"
config_lock_release

# Already absent is distinct from a confirmed deletion and still permits
# ownership cleanup through the final manifest transaction.
new_fixture uninstall-absent
rm -- "$ALPHA_TARGET"
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-absent.out"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
found_absent=0
for record in "$HOME_FIXTURE/.local/state/arclith/transactions/$transaction.targets"/*.v1; do
  index=${record##*/}; index=${index%.v1}
  target_read "$HOME_FIXTURE" "$transaction" "$index"
  if [[ $CONFIG_TXN_TARGET_PATH == .config/kitty/checkpoint-fixture/alpha.conf ]]; then
    [[ $CONFIG_TXN_TARGET_ORIGINAL == no && $CONFIG_TXN_TARGET_BACKUP == - && $CONFIG_TXN_TARGET_STATE == ALREADY_ABSENT ]] || exit 1
    found_absent=1
  fi
done
assert 'absent uninstall target is ALREADY_ABSENT without a backup' test "$found_absent" -eq 1
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'uninstall with an absent target still commits manifest cleanup' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE

# Prune removes an eligible stale target while retaining a locally modified
# conflict, completes its partial transaction, and preserves the old exit code.
new_fixture prune-conflict
STALE_TARGET="$HOME_FIXTURE/.config/kitty/checkpoint-fixture/alpha.conf"
MODIFIED_TARGET="$HOME_FIXTURE/.config/kitty/checkpoint-fixture/beta.conf"
GAMMA_SOURCE="$FIXTURE/core/configs/kitty/checkpoint-fixture/gamma.conf"
GAMMA_TARGET="$HOME_FIXTURE/.config/kitty/checkpoint-fixture/gamma.conf"
printf 'gamma managed\n' > "$GAMMA_SOURCE"
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes >/dev/null
rm -- "$FIXTURE/core/configs/kitty/checkpoint-fixture/alpha.conf" \
  "$FIXTURE/core/configs/kitty/checkpoint-fixture/beta.conf" "$GAMMA_SOURCE" "$GAMMA_TARGET"
printf 'local edit stays\n' > "$MODIFIED_TARGET"
status=0
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config prune kitty --yes > "$test_root/prune-conflict.out" 2>&1 || status=$?
assert 'prune preserves conflict nonzero exit status' test "$status" -eq 1
assert 'prune removes eligible stale target' test ! -e "$STALE_TARGET"
assert 'prune preserves locally modified target' test "$(<"$MODIFIED_TARGET")" = 'local edit stays'
transaction=$(latest_transaction "$HOME_FIXTURE" prune)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'partial prune transaction reaches COMPLETE' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
stale_state= modified_state= absent_state=
for record in "$HOME_FIXTURE/.local/state/arclith/transactions/$transaction.targets"/*.v1; do
  index=${record##*/}; index=${index%.v1}
  target_read "$HOME_FIXTURE" "$transaction" "$index"
  case $CONFIG_TXN_TARGET_PATH in
    .config/kitty/checkpoint-fixture/alpha.conf) stale_state=$CONFIG_TXN_TARGET_STATE ;;
    .config/kitty/checkpoint-fixture/beta.conf) modified_state=$CONFIG_TXN_TARGET_STATE ;;
    .config/kitty/checkpoint-fixture/gamma.conf) absent_state=$CONFIG_TXN_TARGET_STATE ;;
  esac
done
assert 'prune deletion is distinguished from preserved conflict' bash -c '[[ $1 == APPLIED && $2 == NOT_MUTATED ]]' _ "$stale_state" "$modified_state"
assert 'prune records a missing managed target as ALREADY_ABSENT' test "$absent_state" = ALREADY_ABSENT

# If a path appears after it was initially classified missing, the final
# absence check preserves it and retains the ownership entry as a conflict.
new_fixture appeared-after-check
appeared_source="$FIXTURE/core/configs/kitty/checkpoint-fixture/alpha.conf"
appeared_target="$HOME_FIXTURE/.config/kitty/checkpoint-fixture/alpha.conf"
beta_source="$FIXTURE/core/configs/kitty/checkpoint-fixture/beta.conf"
rm -- "$appeared_target" "$appeared_source" "$beta_source"
appeared_mock="$test_root/create-after-check"
mkdir -p "$appeared_mock"
cat > "$appeared_mock/cp" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
"$REAL_CP" "$@" || exit $?
if [[ $destination == *.arclith-backup.* && ! -e $APPEARED_MARKER ]]; then
  printf 'late external file\n' > "$APPEARED_TARGET"
  : > "$APPEARED_MARKER"
fi
EOF
chmod +x "$appeared_mock/cp"
status=0
PATH="$appeared_mock:$PATH" REAL_CP="$real_cp" APPEARED_TARGET="$appeared_target" \
  APPEARED_MARKER="$test_root/appeared-marker" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config prune kitty --yes > "$test_root/appeared-after-check.out" 2>&1 || status=$?
assert 'appeared target preserves prune conflict status' test "$status" -eq 1
assert 'target appearing after missing inspection is preserved' test "$(<"$appeared_target")" = 'late external file'
assert 'appeared path remains tracked in the manifest' bash -c 'grep -Fq "$1" "$2"' _ \
  '.config/kitty/checkpoint-fixture/alpha.conf' "$MANIFEST"
transaction=$(latest_transaction "$HOME_FIXTURE" prune)
appeared_state=
for record in "$HOME_FIXTURE/.local/state/arclith/transactions/$transaction.targets"/*.v1; do
  index=${record##*/}; index=${index%.v1}
  target_read "$HOME_FIXTURE" "$transaction" "$index"
  [[ $CONFIG_TXN_TARGET_PATH == .config/kitty/checkpoint-fixture/alpha.conf ]] && appeared_state=$CONFIG_TXN_TARGET_STATE
done
assert 'appeared path is recorded as NOT_MUTATED rather than ALREADY_ABSENT' test "$appeared_state" = NOT_MUTATED

# Dry-run and preview paths must not create persistent transaction records.
new_fixture dry-run
before_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
rm -- "$FIXTURE/core/configs/kitty/checkpoint-fixture/alpha.conf"
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config prune kitty --dry-run >/dev/null || true
after_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
assert 'prune dry-run creates no transaction journal' test "$before_count" -eq "$after_count"

new_fixture unsafe-target
outside="$test_root/unsafe-sentinel"
printf 'outside sentinel\n' > "$outside"
rm -- "$ALPHA_TARGET"
ln -s "$outside" "$ALPHA_TARGET"
before_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
status=0
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/unsafe-target.out" 2>&1 || status=$?
assert 'unsafe uninstall target returns failure' test "$status" -eq 1
assert 'unsafe uninstall target preserves outside sentinel' test "$(<"$outside")" = 'outside sentinel'
assert 'unsafe target refusal creates no uninstall transaction' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq "$before_count"

# Backup staging and content verification both fail before any deletion.
new_fixture backup-copy-failure
cp_mock="$test_root/fail-backup-copy"
mkdir -p "$cp_mock"
cat > "$cp_mock/cp" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == *.arclith-backup.* ]]; then exit 79; fi
exec "$REAL_CP" "$@"
EOF
chmod +x "$cp_mock/cp"
status=0
PATH="$cp_mock:$PATH" REAL_CP="$real_cp" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/backup-copy-failure.out" 2>&1 || status=$?
assert 'recovery backup copy failure returns failure' test "$status" -eq 1
assert 'recovery backup copy failure prevents deletion' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"

new_fixture backup-verify-failure
corrupt_cp="$test_root/corrupt-backup-copy"
mkdir -p "$corrupt_cp"
cat > "$corrupt_cp/cp" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
"$REAL_CP" "$@" || exit $?
if [[ $destination == *.arclith-backup.* ]]; then printf 'corrupt copy\n' > "$destination"; fi
EOF
chmod +x "$corrupt_cp/cp"
status=0
PATH="$corrupt_cp:$PATH" REAL_CP="$real_cp" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/backup-verify-failure.out" 2>&1 || status=$?
assert 'recovery backup verification failure returns failure' test "$status" -eq 1
assert 'recovery backup verification failure prevents deletion' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"

# A failed initial backup-registration save leaves targets intact and starts no
# deletion. The transaction is rolled back or uncertain, never complete.
new_fixture registration-failure
mock="$test_root/fail-manifest-registration"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MARKER ]]; then : > "$FAIL_MARKER"; exit 71; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$MANIFEST" FAIL_MARKER="$test_root/register-failed" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/register-failure.out" 2>&1 || status=$?
assert 'backup registration failure is reported' test "$status" -eq 1
assert 'backup registration failure prevents target deletion' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'backup registration failure is not reported complete' test "$CONFIG_TXN_JOURNAL_STATE" != COMPLETE

txn_mock="$test_root/fail-transaction-state"
mkdir -p "$txn_mock"
cat > "$txn_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.v1 && $destination != */transactions/*.targets/*.v1 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 76; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$txn_mock/mv"

new_fixture transaction-create-failure
status=0
PATH="$txn_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/create-count" FAIL_AT=1 \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/create-failure.out" 2>&1 || status=$?
assert 'transaction creation persistence failure returns failure' test "$status" -eq 1
assert 'transaction creation persistence failure prevents deletion' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
assert 'transaction creation persistence failure leaves no false journal' test \
  "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq 1

for boundary in prepared applying; do
  new_fixture "$boundary-state-failure"
  fail_at=2
  [[ $boundary != applying ]] || fail_at=3
  status=0
  PATH="$txn_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/$boundary-state-count" FAIL_AT="$fail_at" \
    HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/$boundary-state-failure.out" 2>&1 || status=$?
  assert "$boundary transaction persistence failure returns failure" test "$status" -eq 1
  assert "$boundary transaction persistence failure prevents deletion" bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
done

# A target checkpoint failure before deletion fails closed.
new_fixture intent-failure
mock="$test_root/fail-target-checkpoint"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.targets/000000.v1 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 72; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
# Record writes: PLANNED, backup-ID attachment, STAGED, MUTATION_INTENT.
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/intent-count" FAIL_AT=4 \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/intent-failure.out" 2>&1 || status=$?
assert 'mutation-intent checkpoint failure returns failure' test "$status" -eq 1
assert 'mutation-intent checkpoint failure prevents deletion' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
assert 'mutation-intent failure releases lock' config_lock_acquire "$HOME_FIXTURE"
config_lock_release

for boundary in planned backup-reference staged; do
  new_fixture "$boundary-failure"
  fail_at=1
  [[ $boundary != backup-reference ]] || fail_at=2
  [[ $boundary != staged ]] || fail_at=3
  status=0
  PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/$boundary-count" FAIL_AT="$fail_at" \
    HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/$boundary-failure.out" 2>&1 || status=$?
  assert "$boundary checkpoint failure returns failure" test "$status" -eq 1
  assert "$boundary checkpoint failure prevents deletion" bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
  assert "$boundary checkpoint failure releases lock" config_lock_acquire "$HOME_FIXTURE"
  config_lock_release
done

# Failure to persist APPLIED after deletion invokes rollback and does not leave
# a false COMPLETE record.
new_fixture applied-failure
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/applied-count" FAIL_AT=5 \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/applied-failure.out" 2>&1 || status=$?
assert 'APPLIED checkpoint failure is reported' test "$status" -eq 1
assert 'APPLIED checkpoint failure restores deleted target' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'successful uninstall rollback is ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

# Final manifest failure rolls back deleted targets; a failed target rollback
# leaves UNCERTAIN and keeps its recovery artifact.
new_fixture manifest-failure
mock_manifest="$test_root/fail-final-manifest"
mkdir -p "$mock_manifest"
cat > "$mock_manifest/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == 2 )); then exit 73; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock_manifest/mv"
status=0
PATH="$mock_manifest:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$MANIFEST" FAIL_COUNT="$test_root/manifest-count" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/manifest-failure.out" 2>&1 || status=$?
assert 'final manifest failure is reported' test "$status" -eq 1
assert 'final manifest failure restores deleted targets' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'successful rollback after manifest failure is ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

# Transaction-state writes are fault injected by the transaction record's
# atomic rename boundary: create, PREPARED, APPLYING, COMMITTING, COMPLETE.
new_fixture committing-failure
status=0
PATH="$txn_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/committing-count" FAIL_AT=4 \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/committing-failure.out" 2>&1 || status=$?
assert 'COMMITTING persistence failure returns failure' test "$status" -eq 1
assert 'COMMITTING persistence failure rolls targets back' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'COMMITTING persistence failure resolves as ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

new_fixture complete-failure
status=0
PATH="$txn_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/complete-count" FAIL_AT=5 \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/complete-failure.out" 2>&1 || status=$?
assert 'COMPLETE persistence failure returns failure' test "$status" -eq 1
assert 'COMPLETE persistence failure keeps completed deletion' bash -c '[[ ! -e $1 && ! -e $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'failed COMPLETE persistence leaves UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

# Failure to persist ROLLBACK_INTENT prevents the rollback mutation and keeps
# the existing recovery artifact available.
new_fixture rollback-intent-failure
rollback_intent_mock="$test_root/fail-rollback-intent"
mkdir -p "$rollback_intent_mock"
cat > "$rollback_intent_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" ]]; then
  count=0; [[ ! -f $FAIL_MANIFEST_COUNT ]] || read -r count < "$FAIL_MANIFEST_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_MANIFEST_COUNT"
  if (( count == 2 )); then exit 77; fi
fi
if [[ $destination == */transactions/*.targets/000000.v1 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == ${FAIL_TARGET_AT:-6} )); then exit 78; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$rollback_intent_mock/mv"
status=0
PATH="$rollback_intent_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/rollback-intent-count" \
  FAIL_MANIFEST="$MANIFEST" FAIL_MANIFEST_COUNT="$test_root/rollback-intent-manifest-count" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/rollback-intent-failure.out" 2>&1 || status=$?
assert 'ROLLBACK_INTENT persistence failure returns failure' test "$status" -eq 1
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
target_read "$HOME_FIXTURE" "$transaction" 000000
first_target="$HOME_FIXTURE/$CONFIG_TXN_TARGET_PATH"
assert 'ROLLBACK_INTENT persistence failure leaves target for diagnosis' test ! -e "$first_target"
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'ROLLBACK_INTENT persistence failure is UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

new_fixture rollback-result-failure
status=0
PATH="$rollback_intent_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/rollback-result-count" \
  FAIL_TARGET_AT=7 \
  FAIL_MANIFEST="$MANIFEST" FAIL_MANIFEST_COUNT="$test_root/rollback-result-manifest-count" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/rollback-result-failure.out" 2>&1 || status=$?
assert 'ROLLED_BACK persistence failure returns failure' test "$status" -eq 1
assert 'ROLLED_BACK persistence failure restores the target' test -f "$ALPHA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'failed rollback-result checkpoint leaves UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

new_fixture rollback-failure
mock_rollback="$test_root/fail-rollback-target"
mkdir -p "$mock_rollback"
cat > "$mock_rollback/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" ]]; then
  count=0; [[ ! -f $FAIL_MANIFEST_COUNT ]] || read -r count < "$FAIL_MANIFEST_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_MANIFEST_COUNT"
  if (( count == 2 )); then exit 74; fi
fi
if [[ $destination == "$FAIL_TARGET" ]]; then exit 75; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock_rollback/mv"
status=0
PATH="$mock_rollback:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$MANIFEST" \
  FAIL_MANIFEST_COUNT="$test_root/rollback-manifest-count" FAIL_TARGET="$ALPHA_TARGET" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/rollback-failure.out" 2>&1 || status=$?
assert 'failed rollback returns failure' test "$status" -eq 1
assert 'failed rollback preserves the unrestored target for diagnosis' test ! -e "$ALPHA_TARGET"
transaction=$(latest_transaction "$HOME_FIXTURE" uninstall)
config_transaction_journal_read "$HOME_FIXTURE" "$transaction"
assert 'failed rollback is UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
assert 'recovery backup remains after failed rollback' test -n "$(find "$HOME_FIXTURE" -name 'alpha.conf.arclith-backup.*' -type f -print -quit)"
assert 'lock can be reacquired after failed rollback' config_lock_acquire "$HOME_FIXTURE"
config_lock_release

# A cooperating process holding the same lock prevents uninstall from creating
# a journal or beginning its mutation.
new_fixture lock-contention
ready="$test_root/lock-ready"
gate="$test_root/lock-gate"
mkfifo "$gate"
flock -x "$HOME_FIXTURE/.local/state/arclith/operation.lock" bash -c 'touch "$1"; read -r _ < "$2"' _ "$ready" "$gate" &
holder_pid=$!
ready_status=0
for ((attempt=0; attempt<200; attempt++)); do [[ -e $ready ]] && { ready_status=1; break; }; sleep 0.01; done
assert 'uninstall lock holder reaches synchronized point' test "$ready_status" -eq 1
before_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
status=0
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config uninstall kitty --yes > "$test_root/lock-contention.out" 2>&1 || status=$?
assert 'uninstall lock contention returns busy status' test "$status" -eq 75
assert 'lock contention creates no uninstall journal' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq "$before_count"
printf 'release\n' > "$gate"
wait "$holder_pid"
assert 'lock contention preserves targets' bash -c '[[ -f $1 && -f $2 ]]' _ "$ALPHA_TARGET" "$BETA_TARGET"

printf 'Uninstall and prune checkpoint tests passed; all homes were isolated under %s.\n' "$test_root"
