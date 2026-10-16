#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-transactions-inspect.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
source "$repo_root/core/config.sh"

assert() { local description=$1; shift; if "$@"; then printf 'ok - %s\n' "$description"; else printf 'not ok - %s\n' "$description" >&2; exit 1; fi; }
fails_status() { local expected=$1 description=$2; shift 2; local status=0; "$@" >/dev/null 2>&1 || status=$?; assert "$description" test "$status" -eq "$expected"; }
new_home() { TEST_HOME="$test_root/$1"; mkdir -p "$TEST_HOME"; }
make_tx() {
  local operation=$1 state=$2
  config_lock_acquire "$TEST_HOME"
  config_transaction_journal_create "$TEST_HOME" "$operation" kitty
  TX_ID=$CONFIG_TXN_JOURNAL_ID
  if [[ $state != PREPARING ]]; then
    config_transaction_journal_transition "$TEST_HOME" "$TX_ID" PREPARED
    config_transaction_journal_transition "$TEST_HOME" "$TX_ID" APPLYING
  fi
}
finish_tx() { config_lock_release; }
snapshot() {
  local base=$1
  (cd "$base" && find . -printf '%y|%p|%s|%T@|%m\n' | LC_ALL=C sort)
  (cd "$base" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

# An absent state path is a clean empty inventory and is not created.
new_home empty
empty_output=$(HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions)
assert 'missing journal directory lists as empty' bash -c '[[ $1 == *"No transaction journals found."* ]]' _ "$empty_output"
assert 'empty inspection creates no state or lock file' bash -c '[[ ! -e $1/.local/state && ! -e $1/.local/state/arclith/operation.lock ]]' _ "$TEST_HOME"

# Completed v1, in-progress v1, uncertain v1 and completed v2 records.
new_home multi
make_tx apply PREPARING
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 apply kitty .config/kitty/example.conf no - PLANNED
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 apply kitty .config/kitty/example.conf no - STAGED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" PREPARED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" APPLYING
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 apply kitty .config/kitty/example.conf no - MUTATION_INTENT
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 apply kitty .config/kitty/example.conf no - APPLIED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" COMMITTING
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" COMPLETE
complete_id=$TX_ID
finish_tx

make_tx restore PREPARING
config_transaction_target_checkpoint_v2 "$TEST_HOME" "$TX_ID" 000000 restore kitty .config/kitty/example.conf no Ab12Cd34 - PLANNED
in_progress_id=$TX_ID
finish_tx

make_tx uninstall PREPARING
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" UNCERTAIN
uncertain_id=$TX_ID
finish_tx

make_tx uninstall PREPARING
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 uninstall kitty .config/kitty/example.conf no - PLANNED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" PREPARED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" APPLYING
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 uninstall kitty .config/kitty/example.conf no - ALREADY_ABSENT
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" ROLLING_BACK
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" ROLLED_BACK
rolled_back_id=$TX_ID
finish_tx

make_tx restore PREPARING
config_transaction_target_checkpoint_v2 "$TEST_HOME" "$TX_ID" 000000 restore kitty .config/kitty/example.conf yes Ab12Cd34 - PLANNED
config_transaction_target_checkpoint_v2 "$TEST_HOME" "$TX_ID" 000000 restore kitty .config/kitty/example.conf yes Ab12Cd34 Cd34Ef56 PLANNED
config_transaction_target_checkpoint_v2 "$TEST_HOME" "$TX_ID" 000000 restore kitty .config/kitty/example.conf yes Ab12Cd34 Cd34Ef56 STAGED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" PREPARED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" APPLYING
config_transaction_target_checkpoint_v2 "$TEST_HOME" "$TX_ID" 000000 restore kitty .config/kitty/example.conf yes Ab12Cd34 Cd34Ef56 MUTATION_INTENT
config_transaction_target_checkpoint_v2 "$TEST_HOME" "$TX_ID" 000000 restore kitty .config/kitty/example.conf yes Ab12Cd34 Cd34Ef56 APPLIED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" COMMITTING
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" COMPLETE
v2_id=$TX_ID
finish_tx

before=$(snapshot "$TEST_HOME")
listing=$(HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions)
assert 'listing identifies completed transaction' bash -c '[[ $1 == *"$2  COMPLETE"* ]]' _ "$listing" "$complete_id"
assert 'listing identifies valid in-progress transaction' bash -c '[[ $1 == *"$2  IN_PROGRESS"* ]]' _ "$listing" "$in_progress_id"
assert 'listing identifies valid uncertain transaction' bash -c '[[ $1 == *"$2  UNCERTAIN"* ]]' _ "$listing" "$uncertain_id"
assert 'rolled-back uninstall retains an already-absent no-op outcome' bash -c '[[ $1 == *"$2  COMPLETE"* ]]' _ "$listing" "$rolled_back_id"
assert 'listing validates version 2 transaction' bash -c '[[ $1 == *"$2  COMPLETE"* ]]' _ "$listing" "$v2_id"
detail=$(HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions "$v2_id")
assert 'individual inspection prints target state without path or backup IDs' bash -c '[[ $1 == *"target[000000] state=APPLIED original=yes schema=v2"* && $1 != *".config/kitty"* && $1 != *"Ab12Cd34"* ]]' _ "$detail"
assert 'individual inspection labels journal-only evidence and valid records' bash -c '[[ $1 == *"evidence_source=JOURNAL_ONLY journal_validation=VALID transaction_schema=v1"* ]]' _ "$detail"
assert 'individual inspection reports transaction and target timestamps' bash -c '[[ $1 == *"transaction_created_utc="* && $1 == *"transaction_updated_utc="* && $1 == *"updated_utc="* ]]' _ "$detail"
assert 'individual inspection states filesystem checks were not performed' bash -c '[[ $1 == *"filesystem_check=NOT_PERFORMED target_and_manifest_outcomes=UNVERIFIED"* ]]' _ "$detail"
assert 'individual inspection discloses lock-free snapshot limitation' bash -c '[[ $1 == *"snapshot_consistency=UNVERIFIED_LOCK_FREE"* ]]' _ "$detail"
assert 'individual inspection provides safe manual review guidance' bash -c '[[ $1 == *"Preserve files; do not rerun based only on this report."* ]]' _ "$detail"
assert 'individual inspection warns that original target enumeration is incomplete' bash -c '[[ $1 == *"Target enumeration is incomplete by design: this report validates only records found; it cannot prove every target in the original operation was recorded."* ]]' _ "$detail"
v1_detail=$(HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions "$complete_id")
assert 'version 1 target details remain readable and paths stay hidden' bash -c '[[ $1 == *"target[000000] state=APPLIED original=no schema=v1"* && $1 != *".config/kitty"* && $1 != *"Ab12Cd34"* ]]' _ "$v1_detail"
assert 'inspection leaves journal bytes, metadata, and mtimes unchanged' test "$before" = "$(snapshot "$TEST_HOME")"
temporary="$TEST_HOME/.local/state/arclith/transactions/.$complete_id.tmp.ABC12345"
printf 'partial writer temporary\n' > "$temporary"
chmod 600 "$temporary"
temp_listing=$(HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions)
assert 'recognized in-flight temporary is not treated as a malformed transaction' bash -c '[[ $1 == *"$2  COMPLETE"* && $1 != *MALFORMED* ]]' _ "$temp_listing" "$complete_id"
fails_status 2 'invalid transaction ID has the documented argument status' env HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions ../outside
fails_status 1 'missing transaction ID has the validation-finding status' env HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions 00000000000000000000000000000000

# Unsupported and malformed transaction records are findings, not commands.
bad_home="$test_root/bad"
mkdir -p "$bad_home/.local/state/arclith/transactions"
chmod 700 "$bad_home/.local/state/arclith"
chmod 700 "$bad_home/.local/state/arclith/transactions"
bad_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
printf 'ARCLITH_TXN|99\n' > "$bad_home/.local/state/arclith/transactions/$bad_id.v1"
chmod 600 "$bad_home/.local/state/arclith/transactions/$bad_id.v1"
fails_status 1 'unsupported schema is reported as a validation finding' env HOME="$bad_home" "$repo_root/arclith.sh" config transactions
unsupported_output=$(HOME="$bad_home" "$repo_root/arclith.sh" config transactions 2>/dev/null || true)
assert 'unsupported schema has stable reason code without exposing record contents' bash -c '[[ $1 == *"reason=UNSUPPORTED_SCHEMA"* && $1 != *ARCLITH_TXN* ]]' _ "$unsupported_output"
assert 'listing emits exact incomplete-enumeration warning' bash -c '[[ $1 == *"Target enumeration is incomplete by design: this report validates only records found; it cannot prove every target in the original operation was recorded."* ]]' _ "$unsupported_output"

good_tx="$test_root/multi/.local/state/arclith/transactions/$complete_id.v1"
bad_tx="$bad_home/.local/state/arclith/transactions/$complete_id.v1"
cp -- "$good_tx" "$bad_tx"
chmod 600 "$bad_tx"
good_copy="$test_root/good-transaction"
cp -- "$bad_tx" "$good_copy"
for mutation in missing timestamp state id; do
  cp -- "$good_copy" "$bad_tx"
  case $mutation in
    missing) sed -i '$d' "$bad_tx" ;;
    timestamp) sed -i 's/^UPDATED_UTC|.*/UPDATED_UTC|not-a-timestamp/' "$bad_tx" ;;
    state) sed -i 's/^STATE|COMPLETE$/STATE|FINISHED/' "$bad_tx" ;;
    id) sed -i "s/^ID|$complete_id$/ID|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/" "$bad_tx" ;;
  esac
  chmod 600 "$bad_tx"
  fails_status 1 "$mutation transaction field is rejected" env HOME="$bad_home" "$repo_root/arclith.sh" config transactions "$complete_id"
  mutation_output=$(HOME="$bad_home" "$repo_root/arclith.sh" config transactions "$complete_id" 2>/dev/null || true)
  case $mutation in
    timestamp) expected_reason=INVALID_TIMESTAMP ;;
    id) expected_reason=INVALID_IDENTIFIER ;;
    *) expected_reason=MALFORMED_RECORD ;;
  esac
  assert "$mutation transaction finding has reason code $expected_reason" bash -c '[[ $1 == *"reason=$2"* ]]' _ "$mutation_output" "$expected_reason"
done
printf 'unrelated filename entry\n' > "$bad_home/.local/state/arclith/transactions/not-an-id.v1"
chmod 600 "$bad_home/.local/state/arclith/transactions/not-an-id.v1"
fails_status 1 'invalid transaction filename is reported as malformed' env HOME="$bad_home" "$repo_root/arclith.sh" config transactions

# Structurally valid target under the wrong transaction-level state is inconsistent.
bad_home="$test_root/inconsistent"
mkdir -p "$bad_home"
TEST_HOME=$bad_home
make_tx apply PREPARING
config_transaction_target_checkpoint "$TEST_HOME" "$TX_ID" 000000 apply kitty .config/kitty/example.conf no - PLANNED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" PREPARED
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" APPLYING
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" COMMITTING
config_transaction_journal_transition "$TEST_HOME" "$TX_ID" COMPLETE
inconsistent_id=$TX_ID
finish_tx
fails_status 1 'illegal transaction/target state combination is inconsistent' env HOME="$bad_home" "$repo_root/arclith.sh" config transactions "$inconsistent_id"
inconsistent_detail=$(HOME="$bad_home" "$repo_root/arclith.sh" config transactions "$inconsistent_id" 2>/dev/null || true)
assert 'inconsistent record is explicitly classified' bash -c '[[ $1 == *INCONSISTENT* && $1 == *"journal_validation=FINDINGS"* ]]' _ "$inconsistent_detail"
assert 'incompatible transaction and target states have a stable code' bash -c '[[ $1 == *"reason=INCOMPATIBLE_STATES"* ]]' _ "$inconsistent_detail"

# Target parse findings carry stable codes while paths and backup references remain hidden.
target_bad_home="$test_root/target-findings"
mkdir -p "$target_bad_home"
cp -- "$good_tx" "$target_bad_home/.local/state/arclith/transactions/$complete_id.v1" 2>/dev/null || {
  mkdir -p "$target_bad_home/.local/state/arclith/transactions"
  chmod 700 "$target_bad_home/.local/state/arclith" "$target_bad_home/.local/state/arclith/transactions"
  cp -- "$good_tx" "$target_bad_home/.local/state/arclith/transactions/$complete_id.v1"
}
cp -R "$test_root/multi/.local/state/arclith/transactions/$complete_id.targets" "$target_bad_home/.local/state/arclith/transactions/"
target_record="$target_bad_home/.local/state/arclith/transactions/$complete_id.targets/000000.v1"
cp -- "$target_record" "$test_root/target-record-original"
for mutation in path state identity; do
  cp -- "$test_root/target-record-original" "$target_record"
  case $mutation in
    path) sed -i 's#^TARGET|.*$#TARGET|../outside#' "$target_record"; expected_reason=INVALID_TARGET_PATH ;;
    state) sed -i 's/^STATE|APPLIED$/STATE|FINISHED/' "$target_record"; expected_reason=INVALID_TARGET_STATE ;;
    identity) sed -i 's/^TRANSACTION|.*/TRANSACTION|bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb/' "$target_record"; expected_reason=IDENTITY_MISMATCH ;;
  esac
  chmod 600 "$target_record"
  target_output=$(HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions "$complete_id" 2>/dev/null || true)
  assert "$mutation target finding reports $expected_reason without private values" bash -c '[[ $1 == *"reason=$2"* && $1 != *"../outside"* && $1 != *"Ab12Cd34"* ]]' _ "$target_output" "$expected_reason"
done

# Duplicate version files are inconsistent checkpoint references, not parser failures.
cp -- "$test_root/target-record-original" "$target_bad_home/.local/state/arclith/transactions/$complete_id.targets/000000.v2"
chmod 600 "$target_bad_home/.local/state/arclith/transactions/$complete_id.targets/000000.v2"
duplicate_output=$(HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions "$complete_id" 2>/dev/null || true)
assert 'duplicate target checkpoint versions report INCONSISTENT_CHECKPOINTS' bash -c '[[ $1 == *"reason=INCONSISTENT_CHECKPOINTS"* ]]' _ "$duplicate_output"
missing_output=$(HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions ffffffffffffffffffffffffffffffff 2>/dev/null || true)
assert 'missing transaction reports RECORD_NOT_FOUND' bash -c '[[ $1 == *"reason=RECORD_NOT_FOUND"* ]]' _ "$missing_output"
ln -s -- "$test_root/nonexistent-journal" "$target_bad_home/.local/state/arclith/transactions/cccccccccccccccccccccccccccccccc.v1"
fails_status 3 'dangling journal record is an operational access error' env HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions cccccccccccccccccccccccccccccccc
access_output=$(HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions cccccccccccccccccccccccccccccccc 2>/dev/null || true)
assert 'unavailable journal record reports RECORD_INACCESSIBLE' bash -c '[[ $1 == *"reason=RECORD_INACCESSIBLE"* ]]' _ "$access_output"
ln -s -- "$good_tx" "$target_bad_home/.local/state/arclith/transactions/dddddddddddddddddddddddddddddddd.v1"
fails_status 3 'symlinked journal record is an unsafe storage error' env HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions dddddddddddddddddddddddddddddddd
unsafe_record_output=$(HOME="$target_bad_home" "$repo_root/arclith.sh" config transactions dddddddddddddddddddddddddddddddd 2>/dev/null || true)
assert 'unsafe journal record reports UNSAFE_STORAGE' bash -c '[[ $1 == *"reason=UNSAFE_STORAGE"* ]]' _ "$unsafe_record_output"

path_home="$test_root/untrusted-path"
mkdir -p "$path_home/.local/state/arclith/transactions"
chmod 700 "$path_home/.local/state/arclith" "$path_home/.local/state/arclith/transactions"
cp -- "$good_tx" "$path_home/.local/state/arclith/transactions/$complete_id.v1"
cp -R "$test_root/multi/.local/state/arclith/transactions/$complete_id.targets" \
  "$path_home/.local/state/arclith/transactions/"
path_record="$path_home/.local/state/arclith/transactions/$complete_id.targets/000000.v1"
sed -i 's#^TARGET|.*$#TARGET|../outside#' "$path_record"
chmod 600 "$path_record"
printf 'outside sentinel\n' > "$test_root/outside"
fails_status 1 'unsafe target path remains inert and is reported inconsistent' env HOME="$path_home" "$repo_root/arclith.sh" config transactions "$complete_id"
assert 'inspection does not follow the unsafe target path' test "$(<"$test_root/outside")" = 'outside sentinel'
assert 'inspection does not create a lock file in a copied fixture home' test ! -e "$path_home/.local/state/arclith/operation.lock"

# Unsafe storage layout is operational failure and remains untouched.
unsafe_home="$test_root/unsafe"
mkdir -p "$unsafe_home/.local/state/arclith"
ln -s "$test_root" "$unsafe_home/.local/state/arclith/transactions"
fails_status 3 'symlinked journal directory is an operational error' env HOME="$unsafe_home" "$repo_root/arclith.sh" config transactions

chmod 000 "$TEST_HOME/.local/state/arclith/transactions"
fails_status 3 'inaccessible journal directory is an operational error' env HOME="$TEST_HOME" "$repo_root/arclith.sh" config transactions
chmod 700 "$TEST_HOME/.local/state/arclith/transactions"

printf 'Transaction inspection tests passed.\n'
