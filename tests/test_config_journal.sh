#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-journal-tests.XXXXXX")
cleanup() {
  if [[ -n ${CONFIG_LOCK_FD:-} ]]; then config_lock_release >/dev/null 2>&1 || true; fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source "$repo_root/core/config.sh"

assert() {
  local description=$1
  shift
  if "$@"; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}
fails() {
  local description=$1 status=0
  shift
  "$@" >"$test_root/failure.out" 2>&1 || status=$?
  if (( status == 0 )); then
    printf 'not ok - %s (unexpected success)\n' "$description" >&2
    exit 1
  fi
  printf 'ok - %s (status %s)\n' "$description" "$status"
}

home="$test_root/home"
mkdir -p "$home"
config_lock_acquire "$home"
assert 'journal creation succeeds under the per-home lock' config_transaction_journal_create "$home" apply kitty
id=$CONFIG_TXN_JOURNAL_ID
assert 'generated transaction ID is 32 lowercase hexadecimal characters' bash -c '[[ "$1" =~ ^[a-f0-9]{32}$ ]]' _ "$id"
journal_dir="$home/.local/state/arclith/transactions"
journal="$journal_dir/$id.v1"
assert 'journal directory has owner-only mode' test "$(stat -c '%a' "$journal_dir")" = 700
assert 'journal file has owner-only mode' test "$(stat -c '%a' "$journal")" = 600
assert 'new journal has PREPARING state' test "$CONFIG_TXN_JOURNAL_STATE" = PREPARING
assert 'new journal records the operation' test "$CONFIG_TXN_JOURNAL_OPERATION" = apply
assert 'new journal records the component' test "$CONFIG_TXN_JOURNAL_COMPONENT" = kitty

config_transaction_journal_read "$home" "$id"
assert 'existing journal is read and validated' test "$CONFIG_TXN_JOURNAL_ID" = "$id"
assert 'journal schema version is explicit' bash -c '[[ "$(head -n 1 "$1")" == "ARCLITH_TXN|1" ]]' _ "$journal"

config_lock_release
fails 'journal write without the matching lock is rejected' config_transaction_journal_transition "$home" "$id" PREPARED
before=$(sha256sum "$journal")
assert 'rejected unlocked transition preserves the record' test "$(sha256sum "$journal")" = "$before"
config_lock_acquire "$home"

# The parent holds the lock while a competing process attempts to enter the
# same per-home write boundary. It must fail before touching the journal.
busy_status=0
if ( source "$repo_root/core/config.sh"; config_lock_acquire "$home" ) >"$test_root/busy.out" 2>&1; then
  printf 'not ok - competing journal writer acquired the held lock\n' >&2
  exit 1
else
  busy_status=$?
fi
assert 'competing journal writer is rejected by the shared lock' test "$busy_status" -eq "$CONFIG_LOCK_BUSY_STATUS"
assert 'competing journal writer leaves the journal unchanged' test "$(sha256sum "$journal")" = "$before"

inode_before=$(stat -c '%i' "$journal")
config_transaction_journal_transition "$home" "$id" PREPARED
assert 'valid PREPARING to PREPARED transition succeeds' test "$CONFIG_TXN_JOURNAL_STATE" = PREPARED
inode_after=$(stat -c '%i' "$journal")
assert 'state update atomically replaces the journal inode' test "$inode_before" != "$inode_after"
config_transaction_journal_transition "$home" "$id" APPLYING
config_transaction_journal_transition "$home" "$id" COMMITTING
config_transaction_journal_transition "$home" "$id" COMPLETE
assert 'normal lifecycle reaches COMPLETE' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
fails 'terminal state cannot transition further' config_transaction_journal_transition "$home" "$id" APPLYING
fails 'unknown state is rejected' config_transaction_journal_transition "$home" "$id" BOGUS
fails 'invalid operation is rejected' config_transaction_journal_create "$home" eval kitty
fails 'invalid component is rejected' config_transaction_journal_create "$home" apply '../kitty'
fails 'invalid transaction ID is rejected before path construction' config_transaction_journal_read "$home" '../outside'

# Take a known-good copy for parser and failed-write cases.
valid_copy="$test_root/valid-record"
cp -- "$journal" "$valid_copy"
chmod 600 -- "$valid_copy"
restore_valid_record() { cp -- "$valid_copy" "$journal"; chmod 600 -- "$journal"; }

sed '1s/ARCLITH_TXN|1/ARCLITH_TXN|99/' "$valid_copy" > "$journal"
chmod 600 -- "$journal"
fails 'unsupported schema version is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

head -n 6 "$valid_copy" > "$journal"
chmod 600 -- "$journal"
fails 'truncated journal record is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

sed 's/^STATE|COMPLETE$/STATE|COMPLETE|/' "$valid_copy" > "$journal"
chmod 600 -- "$journal"
fails 'extra field delimiter is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

printf 'ARCLITH_TXN|1\0\n' > "$journal"
chmod 600 -- "$journal"
fails 'binary journal data is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

sed 's/^STATE|COMPLETE$/STATE|UNKNOWN/' "$valid_copy" > "$journal"
chmod 600 -- "$journal"
fails 'unknown stored lifecycle state is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

sed 's/^CREATED_UTC|.*/CREATED_UTC|2025-02-30T00:00:00Z/' "$valid_copy" > "$journal"
chmod 600 -- "$journal"
fails 'invalid calendar timestamp is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

chmod 644 "$journal"
fails 'permissive journal file mode is rejected' config_transaction_journal_read "$home" "$id"
chmod 600 "$journal"
chmod 755 "$journal_dir"
fails 'permissive journal directory mode is rejected' config_transaction_journal_read "$home" "$id"
chmod 700 "$journal_dir"

sentinel="$test_root/outside"
printf 'outside sentinel\n' > "$sentinel"
ln -s "$sentinel" "$journal_dir/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.v1"
fails 'symlinked journal file is rejected' config_transaction_journal_read "$home" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert 'symlink destination remains unchanged' test "$(<"$sentinel")" = 'outside sentinel'
assert 'invalid identifier did not reach outside path' test "$(<"$sentinel")" = 'outside sentinel'

# A partial serialization failure must leave the prior journal byte-for-byte
# intact and remove only the temporary file owned by this write attempt.
before=$(sha256sum "$journal")
saved_serializer=$(declare -f config_transaction_journal_serialize)
config_transaction_journal_serialize() { printf 'partial record\n'; return 1; }
fails 'partial journal serialization is reported' config_transaction_journal_transition "$home" "$id" APPLYING
eval "$saved_serializer"
assert 'partial write preserves the prior valid record' test "$(sha256sum "$journal")" = "$before"
assert 'partial write leaves the in-memory state at the persisted value' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
assert 'partial write removes its temporary file' bash -c '[[ -z $(find "$1" -maxdepth 1 -type f -name ".*.tmp.*" -print -quit) ]]' _ "$journal_dir"

# Temporary-file creation failure also leaves the prior record untouched.
mock_bin="$test_root/no-mktemp"
mkdir -p "$mock_bin"
cat > "$mock_bin/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 43
EOF
chmod +x "$mock_bin/mktemp"
original_path=$PATH
PATH="$mock_bin:$PATH"
fails 'temporary-file creation failure is reported' config_transaction_journal_transition "$home" "$id" APPLYING
PATH=$original_path
assert 'temporary-file creation failure preserves the prior record' test "$(sha256sum "$journal")" = "$before"

mock_bin="$test_root/no-chmod"
mkdir -p "$mock_bin"
cat > "$mock_bin/chmod" <<'EOF'
#!/usr/bin/env bash
exit 44
EOF
chmod +x "$mock_bin/chmod"
original_path=$PATH
PATH="$mock_bin:$PATH"
fails 'temporary-file permission failure is reported' config_transaction_journal_transition "$home" "$id" APPLYING
PATH=$original_path
assert 'temporary-file permission failure preserves the prior record' test "$(sha256sum "$journal")" = "$before"

# Fail the atomic rename deterministically; the previous record must survive.
mock_bin="$test_root/no-mv"
mkdir -p "$mock_bin"
cat > "$mock_bin/mv" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
chmod +x "$mock_bin/mv"
original_path=$PATH
PATH="$mock_bin:$PATH"
fails 'failed journal rename is reported' config_transaction_journal_transition "$home" "$id" APPLYING
PATH=$original_path
assert 'failed rename preserves the prior valid record' test "$(sha256sum "$journal")" = "$before"
assert 'failed rename leaves the in-memory state at the persisted value' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
assert 'failed rename removes its temporary file' bash -c '[[ -z $(find "$1" -maxdepth 1 -type f -name ".*.tmp.*" -print -quit) ]]' _ "$journal_dir"

sed 's/^OPERATION|apply$/OPERATION|unknown/' "$valid_copy" > "$journal"
chmod 600 -- "$journal"
fails 'unknown stored operation is rejected' config_transaction_journal_read "$home" "$id"
restore_valid_record

# A separate transaction can be updated through the rollback branch; all
# updates preserve the generated identifier and original creation time.
created_utc=$CONFIG_TXN_JOURNAL_CREATED_UTC
assert 'second journal creation succeeds' config_transaction_journal_create "$home" restore kitty
rollback_id=$CONFIG_TXN_JOURNAL_ID
assert 'sequential transaction receives a distinct identifier' test "$rollback_id" != "$id"
config_transaction_journal_transition "$home" "$rollback_id" ROLLING_BACK
config_transaction_journal_transition "$home" "$rollback_id" ROLLED_BACK
assert 'rollback branch reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
config_transaction_journal_read "$home" "$id"
assert 'sequential updates retain transaction ID' test "$CONFIG_TXN_JOURNAL_ID" = "$id"
assert 'sequential updates retain creation timestamp' test "$CONFIG_TXN_JOURNAL_CREATED_UTC" = "$created_utc"

assert 'target-checkpoint transaction can be created' config_transaction_journal_create "$home" apply kitty
target_txn=$CONFIG_TXN_JOURNAL_ID
fails 'target path traversal is rejected' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty ../outside no - PLANNED
fails 'unsafe backup reference is rejected' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes ../../outside PLANNED
assert 'planned target checkpoint is written' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes - PLANNED
target_dir="$journal_dir/$target_txn.targets"
target_record="$target_dir/000000.v1"
assert 'target-checkpoint directory has owner-only mode' test "$(stat -c '%a' "$target_dir")" = 700
assert 'target-checkpoint file has owner-only mode' test "$(stat -c '%a' "$target_record")" = 600
assert 'target checkpoint validates and reads back' config_transaction_target_read "$home" "$target_txn" 000000
assert 'version 1 target has no source-backup reference' test "$CONFIG_TXN_TARGET_SOURCE_BACKUP" = -
assert 'version 1 backup keeps rollback-copy meaning' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" = -
assert 'target path is stored relative to the home root' test "$CONFIG_TXN_TARGET_PATH" = .config/kitty/kitty.conf
assert 'original target presence is recorded' test "$CONFIG_TXN_TARGET_ORIGINAL" = yes
fails 'planned target cannot skip directly to applied' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes - APPLIED
assert 'backup ID can be attached before staging' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes Ab12Cd34 PLANNED
assert 'backup reference is recorded as an opaque validated ID' test "$CONFIG_TXN_TARGET_BACKUP" = Ab12Cd34
assert 'version 1 backup remains the rollback reference' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" = Ab12Cd34
assert 'version 1 record does not infer a restore source' test "$CONFIG_TXN_TARGET_SOURCE_BACKUP" = -
assert 'target can reach STAGED' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes Ab12Cd34 STAGED
assert 'transaction can enter PREPARED' config_transaction_journal_transition "$home" "$target_txn" PREPARED
assert 'transaction can enter APPLYING' config_transaction_journal_transition "$home" "$target_txn" APPLYING
assert 'target mutation intent is checkpointed' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes Ab12Cd34 MUTATION_INTENT
assert 'target application is checkpointed' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes Ab12Cd34 APPLIED
fails 'applied target cannot return to staged' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes Ab12Cd34 STAGED
assert 'transaction can enter COMMITTING' config_transaction_journal_transition "$home" "$target_txn" COMMITTING
assert 'transaction can complete after target checkpoints' config_transaction_journal_transition "$home" "$target_txn" COMPLETE
fails 'terminal transaction cannot accept more target writes' config_transaction_target_checkpoint "$home" "$target_txn" 000000 apply kitty .config/kitty/kitty.conf yes Ab12Cd34 UNCERTAIN

target_valid_copy="$test_root/valid-target-record"
cp -- "$target_record" "$target_valid_copy"
sed '1s/ARCLITH_TARGET|1/ARCLITH_TARGET|99/' "$target_valid_copy" > "$target_record"
chmod 600 -- "$target_record"
fails 'unsupported target-checkpoint version is rejected' config_transaction_target_read "$home" "$target_txn" 000000
cp -- "$target_valid_copy" "$target_record"
chmod 600 -- "$target_record"
sed 's#^TARGET|.config/kitty/kitty.conf$#TARGET|../outside#' "$target_valid_copy" > "$target_record"
chmod 600 -- "$target_record"
fails 'unsafe stored target path is rejected' config_transaction_target_read "$home" "$target_txn" 000000
cp -- "$target_valid_copy" "$target_record"
chmod 600 -- "$target_record"

assert 'restore transaction can be created' config_transaction_journal_create "$home" restore kitty
restore_txn=$CONFIG_TXN_JOURNAL_ID
fails 'absent restore target cannot name rollback backup' config_transaction_target_checkpoint_v2 "$home" "$restore_txn" 000001 restore kitty .config/kitty/kitty.conf no Ab12Cd34 Cd34Ef56 PLANNED
assert 'version 2 restore checkpoint begins planned' config_transaction_target_checkpoint_v2 "$home" "$restore_txn" 000000 restore kitty .config/kitty/kitty.conf yes Ab12Cd34 - PLANNED
restore_record="$journal_dir/$restore_txn.targets/000000.v2"
assert 'version 2 restore checkpoint round-trips' config_transaction_target_read "$home" "$restore_txn" 000000
assert 'version 2 source reference remains distinct' test "$CONFIG_TXN_TARGET_SOURCE_BACKUP" = Ab12Cd34
assert 'version 2 rollback reference starts absent' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" = -
assert 'version 2 rollback reference can be attached while planned' config_transaction_target_checkpoint_v2 "$home" "$restore_txn" 000000 restore kitty .config/kitty/kitty.conf yes Ab12Cd34 Cd34Ef56 PLANNED
assert 'version 2 keeps separate source and rollback IDs' config_transaction_target_read "$home" "$restore_txn" 000000
assert 'version 2 source ID is unchanged' test "$CONFIG_TXN_TARGET_SOURCE_BACKUP" = Ab12Cd34
assert 'version 2 rollback ID is separate' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" = Cd34Ef56
assert 'restore checkpoint becomes staged' config_transaction_target_checkpoint_v2 "$home" "$restore_txn" 000000 restore kitty .config/kitty/kitty.conf yes Ab12Cd34 Cd34Ef56 STAGED
assert 'restore transaction prepares' config_transaction_journal_transition "$home" "$restore_txn" PREPARED
assert 'restore transaction applies' config_transaction_journal_transition "$home" "$restore_txn" APPLYING
assert 'restore mutation intent is valid' config_transaction_target_checkpoint_v2 "$home" "$restore_txn" 000000 restore kitty .config/kitty/kitty.conf yes Ab12Cd34 Cd34Ef56 MUTATION_INTENT
assert 'restore application is valid' config_transaction_target_checkpoint_v2 "$home" "$restore_txn" 000000 restore kitty .config/kitty/kitty.conf yes Ab12Cd34 Cd34Ef56 APPLIED
assert 'restore record round-trips after transition' config_transaction_target_read "$home" "$restore_txn" 000000
assert 'new record retains source-backup reference' test "$CONFIG_TXN_TARGET_SOURCE_BACKUP" = Ab12Cd34
assert 'new record retains rollback-backup reference' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" = Cd34Ef56
cp -- "$restore_record" "$target_valid_copy"
sed '1s/ARCLITH_TARGET|2/ARCLITH_TARGET|99/' "$target_valid_copy" > "$restore_record"
chmod 600 -- "$restore_record"
fails 'unsupported version 2 extension is rejected' config_transaction_target_read "$home" "$restore_txn" 000000
cp -- "$target_valid_copy" "$restore_record"
chmod 600 -- "$restore_record"
sed 's/^SOURCE_BACKUP|.*/SOURCE_BACKUP|..\/outside/' "$target_valid_copy" > "$restore_record"
chmod 600 -- "$restore_record"
fails 'unsafe source-backup reference is rejected' config_transaction_target_read "$home" "$restore_txn" 000000
cp -- "$target_valid_copy" "$restore_record"
chmod 600 -- "$restore_record"
sed '$d' "$target_valid_copy" > "$restore_record"
chmod 600 -- "$restore_record"
fails 'truncated version 2 target checkpoint is rejected' config_transaction_target_read "$home" "$restore_txn" 000000
cp -- "$target_valid_copy" "$restore_record"
chmod 600 -- "$restore_record"
assert 'version 2 record remains readable after content restoration' config_transaction_target_read "$home" "$restore_txn" 000000
config_lock_release

outside_dir="$test_root/outside-directory"
mkdir -p "$outside_dir"
printf 'outside directory sentinel\n' > "$outside_dir/sentinel"
mv -- "$journal_dir" "$test_root/transactions.saved"
ln -s "$outside_dir" "$journal_dir"
fails 'symlinked journal directory is rejected' config_transaction_journal_read "$home" "$id"
assert 'journal directory symlink target remains unchanged' \
  test "$(<"$outside_dir/sentinel")" = 'outside directory sentinel'
rm -- "$journal_dir"
mv -- "$test_root/transactions.saved" "$journal_dir"

printf 'Transaction journal foundation tests passed; all journal paths were isolated under %s.\n' "$test_root"
