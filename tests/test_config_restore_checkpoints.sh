#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-restore-checkpoints.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source "$repo_root/core/config.sh"
real_mv=$(command -v mv)
real_cp=$(command -v cp)
real_rm=$(command -v rm)

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
new_fixture() {
  local name=$1
  FIXTURE="$test_root/$name/project"
  HOME_FIXTURE="$test_root/$name/home"
  mkdir -p "$FIXTURE" "$HOME_FIXTURE/.config/kitty"
  cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
    "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$FIXTURE/"
  printf 'prior user configuration\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes >/dev/null
  BACKUP_ID=$(HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config backups \
    | awk '/available$/{print $1; exit}')
  [[ $BACKUP_ID =~ ^[A-Za-z0-9]{8}$ ]]
}
latest_transaction() {
  local home=$1 path
  path=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' \
    | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  [[ -n $path ]] || return 1
  printf '%s' "${path##*/}" | sed 's/\.v1$//'
}
read_transaction() { config_transaction_journal_read "$1" "$2"; }
read_target() { config_transaction_target_read "$1" "$2" 000000; }
run_restore() {
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config restore "$BACKUP_ID" --yes
}

# Existing target: source and rollback references remain distinct, then the
# transaction completes after the manifest update.
new_fixture success-present
printf 'modified current target\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
run_restore > "$test_root/success-present.out"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'present-target restore reaches COMPLETE' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
assert 'restore transaction is labeled restore' test "$CONFIG_TXN_JOURNAL_OPERATION" = restore
read_target "$HOME_FIXTURE" "$transaction"
assert 'present-target restore reaches APPLIED' test "$CONFIG_TXN_TARGET_STATE" = APPLIED
assert 'restore source reference is the selected backup' test "$CONFIG_TXN_TARGET_SOURCE_BACKUP" = "$BACKUP_ID"
assert 'restore rollback reference is a different backup' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" != - && test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" != "$BACKUP_ID"
assert 'present-target restore installs selected backup' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'prior user configuration'

# Originally absent target is restored and removed again if a later manifest
# boundary fails.
new_fixture success-absent
rm -- "$HOME_FIXTURE/.config/kitty/kitty.conf"
run_restore > "$test_root/success-absent.out"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_target "$HOME_FIXTURE" "$transaction"
assert 'absent-target restore records original absence' test "$CONFIG_TXN_TARGET_ORIGINAL" = no
assert 'absent-target restore has no rollback artifact' test "$CONFIG_TXN_TARGET_ROLLBACK_BACKUP" = -
assert 'absent-target restore reaches APPLIED' test "$CONFIG_TXN_TARGET_STATE" = APPLIED
assert 'absent-target restore creates target' test -f "$HOME_FIXTURE/.config/kitty/kitty.conf"

# Invalid ID, unsafe target, and declined confirmation do not create journals.
new_fixture validation
journal_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
status=0
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config restore ../outside --yes >"$test_root/invalid-id.out" 2>&1 || status=$?
assert 'invalid backup ID is rejected' test "$status" -eq 2
printf 'n\n' | HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config restore "$BACKUP_ID" >"$test_root/declined.out" 2>&1 || true
assert 'invalid and declined restore create no transaction' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq "$journal_count"
assert 'declined restore leaves target intact' cmp -s "$HOME_FIXTURE/.config/kitty/kitty.conf" "$FIXTURE/core/configs/kitty/kitty.conf"

new_fixture unsafe-target
outside="$test_root/outside-target"
printf 'outside sentinel\n' > "$outside"
rm -rf -- "$HOME_FIXTURE/.config/kitty"
ln -s "$test_root" "$HOME_FIXTURE/.config/kitty"
status=0
run_restore >"$test_root/unsafe-target.out" 2>&1 || status=$?
assert 'unsafe restore target parent is rejected' test "$status" -eq 1
assert 'unsafe target rejection creates no restore transaction' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq 1
assert 'unsafe target rejection preserves outside sentinel' test "$(<"$outside")" = 'outside sentinel'

# A transaction record or PLANNED checkpoint persistence failure stops before
# target changes. The transaction remains uncertain if its target plan could
# not be durably established.
new_fixture transaction-create-failure
printf 'journal create sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
mock="$test_root/fail-transaction-create"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.v1 && $destination != */transactions/*.targets/*.v1 \
  && ( -z ${FAIL_MARKER:-} || ! -e $FAIL_MARKER ) ]]; then
  if [[ ${FAIL_AFTER:-0} == 1 ]]; then "$REAL_MV" "$@" || exit $?; : > "$FAIL_MARKER"; fi
  exit 60
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" run_restore >"$test_root/transaction-create-failure.out" 2>&1 || status=$?
assert 'transaction creation persistence failure returns failure' test "$status" -eq 1
assert 'transaction creation failure preserves target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'journal create sentinel'
assert 'transaction creation failure leaves no transaction record' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq 1

new_fixture ambiguous-create-failure
printf 'ambiguous create sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_AFTER=1 FAIL_MARKER="$test_root/create-after-rename-marker" \
  run_restore >"$test_root/ambiguous-create-failure.out" 2>&1 || status=$?
assert 'transaction creation succeeds when the exact PREPARING record persisted' test "$status" -eq 0
assert 'restore proceeds after reconciling its persisted transaction record' \
  test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'prior user configuration'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'reconciled transaction creation completes normally' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE

plan_mock="$test_root/fail-planned-record-write"
mkdir -p "$plan_mock"
cat > "$plan_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.targets/000000.v2 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 63; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$plan_mock/mv"

new_fixture planned-failure
printf 'planned sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
PATH="$plan_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/planned-count" FAIL_AT=1 \
  run_restore >"$test_root/planned-failure.out" 2>&1 || status=$?
assert 'PLANNED persistence failure returns failure' test "$status" -eq 1
assert 'PLANNED persistence failure preserves target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'planned sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'PLANNED persistence failure leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

new_fixture backup-reference-failure
printf 'backup reference sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
PATH="$plan_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/backup-ref-count" FAIL_AT=2 \
  run_restore >"$test_root/backup-reference-failure.out" 2>&1 || status=$?
assert 'rollback-reference persistence failure returns failure' test "$status" -eq 1
assert 'rollback-reference persistence failure preserves target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'backup reference sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'rollback-reference persistence failure leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

# Backup creation failure removes the incomplete copy and records no target
# mutation. A copied-but-corrupt rollback artifact is detected before rename.
new_fixture backup-create-failure
printf 'backup copy sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
cp_mock="$test_root/fail-backup-cp"
mkdir -p "$cp_mock"
cat > "$cp_mock/cp" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == *.arclith-backup.* ]]; then exit 67; fi
exec "$REAL_CP" "$@"
EOF
chmod +x "$cp_mock/cp"
status=0
PATH="$cp_mock:$PATH" REAL_CP="$real_cp" run_restore >"$test_root/backup-create-failure.out" 2>&1 || status=$?
assert 'rollback backup creation failure returns failure' test "$status" -eq 1
assert 'rollback backup creation failure preserves target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'backup copy sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'backup creation failure reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

new_fixture backup-verification-failure
printf 'backup verification sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
cp_corrupt="$test_root/corrupt-backup-cp"
mkdir -p "$cp_corrupt"
cat > "$cp_corrupt/cp" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
"$REAL_CP" "$@" || exit $?
if [[ $destination == *.arclith-backup.* ]]; then printf 'corrupt copy\n' > "$destination"; fi
EOF
chmod +x "$cp_corrupt/cp"
status=0
PATH="$cp_corrupt:$PATH" REAL_CP="$real_cp" run_restore >"$test_root/backup-verification-failure.out" 2>&1 || status=$?
assert 'rollback backup verification failure returns failure' test "$status" -eq 1
assert 'rollback backup verification failure preserves target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'backup verification sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'rollback backup verification failure is UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

# Source staging failure and checkpoint failures at STAGED and MUTATION_INTENT
# boundaries never replace the target.
new_fixture staging-failure
printf 'staging sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
cp_stage="$test_root/fail-source-stage"
mkdir -p "$cp_stage"
source_path="$HOME_FIXTURE/.config/kitty/kitty.conf.arclith-backup.$BACKUP_ID"
cat > "$cp_stage/cp" <<'EOF'
#!/usr/bin/env bash
source_path=${@: -2:1}
if [[ $source_path == "$FAIL_SOURCE" ]]; then exit 68; fi
exec "$REAL_CP" "$@"
EOF
chmod +x "$cp_stage/cp"
status=0
PATH="$cp_stage:$PATH" REAL_CP="$real_cp" FAIL_SOURCE="$source_path" run_restore >"$test_root/staging-failure.out" 2>&1 || status=$?
assert 'source staging failure returns failure' test "$status" -eq 1
assert 'source staging failure preserves target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'staging sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'source staging failure reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

boundary_mock="$test_root/fail-boundary-target-write"
mkdir -p "$boundary_mock"
cat > "$boundary_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.targets/000000.v2 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 63; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$boundary_mock/mv"

for boundary in staged intent; do
  new_fixture "$boundary-checkpoint-failure"
  printf '%s checkpoint sentinel\n' "$boundary" > "$HOME_FIXTURE/.config/kitty/kitty.conf"
  fail_at=3
  [[ $boundary != intent ]] || fail_at=4
  status=0
  PATH="$boundary_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/$boundary-count" FAIL_AT="$fail_at" \
    run_restore >"$test_root/$boundary-checkpoint-failure.out" 2>&1 || status=$?
  assert "$boundary checkpoint failure returns failure" test "$status" -eq 1
  assert "$boundary checkpoint failure preserves target" test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = "$boundary checkpoint sentinel"
  transaction=$(latest_transaction "$HOME_FIXTURE")
  read_transaction "$HOME_FIXTURE" "$transaction"
  if [[ $boundary == intent ]]; then
    assert 'mutation-intent checkpoint failure reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
    read_target "$HOME_FIXTURE" "$transaction"
    assert 'mutation-intent checkpoint failure records NOT_MUTATED' test "$CONFIG_TXN_TARGET_STATE" = NOT_MUTATED
  else
    assert 'STAGED checkpoint failure leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
  fi
done

transaction_mock="$test_root/fail-transaction-transition"
mkdir -p "$transaction_mock"
cat > "$transaction_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.v1 && $destination != */transactions/*.targets/*.v1 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 64; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$transaction_mock/mv"
for boundary in prepared applying; do
  new_fixture "$boundary-transaction-failure"
  printf '%s transaction sentinel\n' "$boundary" > "$HOME_FIXTURE/.config/kitty/kitty.conf"
  fail_at=2
  [[ $boundary != applying ]] || fail_at=3
  status=0
  PATH="$transaction_mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/$boundary-tx-count" FAIL_AT="$fail_at" \
    run_restore >"$test_root/$boundary-transaction-failure.out" 2>&1 || status=$?
  assert "$boundary transaction write failure returns failure" test "$status" -eq 1
  assert "$boundary transaction write failure preserves target" test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = "$boundary transaction sentinel"
  transaction=$(latest_transaction "$HOME_FIXTURE")
  read_transaction "$HOME_FIXTURE" "$transaction"
  assert "$boundary transaction write failure leaves UNCERTAIN" test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
done

# A failed target rename before replacement resolves as NOT_MUTATED. A rename
# that completes but reports failure is rolled back using the saved copy.
new_fixture rename-before
printf 'before-rename sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
mock="$test_root/mv-before"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_TARGET" ]]; then exit 61; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_TARGET="$HOME_FIXTURE/.config/kitty/kitty.conf" \
  run_restore >"$test_root/rename-before.out" 2>&1 || status=$?
assert 'pre-replacement rename failure returns failure' test "$status" -eq 1
assert 'pre-replacement failure preserves current target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'before-rename sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'pre-replacement failure reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
read_target "$HOME_FIXTURE" "$transaction"
assert 'pre-replacement failure records NOT_MUTATED' test "$CONFIG_TXN_TARGET_STATE" = NOT_MUTATED
assert 'lock can be reacquired after restore error' config_lock_acquire "$HOME_FIXTURE"
config_lock_release

new_fixture rename-after
printf 'after-rename sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
mock="$test_root/mv-after"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_TARGET" && ! -e $FAIL_MARKER ]]; then
  "$REAL_MV" "$@" || exit $?
  : > "$FAIL_MARKER"
  exit 62
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_TARGET="$HOME_FIXTURE/.config/kitty/kitty.conf" FAIL_MARKER="$test_root/mv-after-once" \
  run_restore >"$test_root/rename-after.out" 2>&1 || status=$?
assert 'post-replacement rename error returns failure' test "$status" -eq 1
assert 'post-replacement error restores prior target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'after-rename sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'post-replacement rollback reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
read_target "$HOME_FIXTURE" "$transaction"
assert 'post-replacement rollback records ROLLED_BACK' test "$CONFIG_TXN_TARGET_STATE" = ROLLED_BACK

# Journal write injection uses deterministic rename counts: create transaction
# first, then target PLANNED, rollback-reference update, STAGED, MUTATION_INTENT,
# APPLIED, and rollback checkpoints.
new_fixture applied-checkpoint-failure
printf 'applied checkpoint sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
mock="$test_root/fail-target-record-write"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ -n ${FAIL_MANIFEST:-} && $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MANIFEST_MARKER ]]; then
  : > "$FAIL_MANIFEST_MARKER"
  exit 66
fi
if [[ $destination == */transactions/*.targets/000000.v2 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 63; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/target-write-count" FAIL_AT=5 \
  run_restore >"$test_root/applied-checkpoint-failure.out" 2>&1 || status=$?
assert 'APPLIED persistence failure returns failure' test "$status" -eq 1
assert 'APPLIED persistence failure rolls target back' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'applied checkpoint sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'APPLIED persistence rollback reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
read_target "$HOME_FIXTURE" "$transaction"
assert 'APPLIED persistence failure is not recorded as APPLIED' test "$CONFIG_TXN_TARGET_STATE" = ROLLED_BACK

# Failing ROLLBACK_INTENT persistence prevents the rollback rename and leaves
# the already-replaced target and transaction explicitly uncertain.
new_fixture rollback-intent-failure
printf 'rollback intent sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/rollback-intent-count" FAIL_AT=6 \
  FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" FAIL_MANIFEST_MARKER="$test_root/rollback-intent-manifest-marker" \
  run_restore >"$test_root/rollback-intent-failure.out" 2>&1 || status=$?
assert 'rollback-intent persistence failure returns failure' test "$status" -eq 1
assert 'rollback-intent persistence failure leaves target for diagnosis' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" != 'rollback intent sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'rollback-intent persistence failure is UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

# COMMITTING and COMPLETE persistence failures are distinct: a failed
# COMMITTING write rolls the target back; a failed COMPLETE write leaves the
# committed target/manifest and records UNCERTAIN.
new_fixture committing-failure
printf 'committing sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
mock_root="$test_root/fail-transaction-write"
mkdir -p "$mock_root"
cat > "$mock_root/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.v1 && $destination != */transactions/*.targets/*.v1 ]]; then
  count=0; [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == FAIL_AT )); then exit 64; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock_root/mv"
status=0
PATH="$mock_root:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/committing-count" FAIL_AT=4 \
  run_restore >"$test_root/committing-failure.out" 2>&1 || status=$?
assert 'COMMITTING persistence failure returns failure' test "$status" -eq 1
assert 'COMMITTING persistence failure rolls target back' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'committing sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'COMMITTING persistence rollback reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

new_fixture complete-failure
printf 'complete sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
PATH="$mock_root:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/complete-count" FAIL_AT=5 \
  run_restore >"$test_root/complete-failure.out" 2>&1 || status=$?
assert 'COMPLETE persistence failure returns failure' test "$status" -eq 1
assert 'COMPLETE persistence failure keeps deployment manifest' test -f "$HOME_FIXTURE/.local/state/arclith/deployments.v1"
assert 'COMPLETE persistence failure keeps committed target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'prior user configuration'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'COMPLETE persistence failure leaves UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN

# A manifest rename failure after target replacement triggers target rollback.
new_fixture manifest-failure
printf 'manifest failure sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
manifest="$HOME_FIXTURE/.local/state/arclith/deployments.v1"
manifest_before=$(sha256sum "$manifest")
manifest_mock="$test_root/fail-manifest-mv"
mkdir -p "$manifest_mock"
cat > "$manifest_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MARKER ]]; then : > "$FAIL_MARKER"; exit 65; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$manifest_mock/mv"
status=0
PATH="$manifest_mock:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$manifest" FAIL_MARKER="$test_root/manifest-failed-once" \
  run_restore >"$test_root/manifest-failure.out" 2>&1 || status=$?
assert 'manifest failure returns failure' test "$status" -eq 1
assert 'manifest failure rolls target back' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'manifest failure sentinel'
assert 'manifest failure preserves prior manifest' test "$(sha256sum "$manifest")" = "$manifest_before"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'manifest rollback reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK

# Corruption of the staged current-target recovery copy after its backup hash
# was captured must stop rollback before replacing the restored target.
new_fixture rollback-backup-corruption
printf 'restore rollback backup sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
corrupt_cp="$test_root/corrupt-restore-rollback-stage"
corrupt_mv="$test_root/fail-restore-manifest"
mkdir -p "$corrupt_cp" "$corrupt_mv"
cat > "$corrupt_cp/cp" <<'EOF'
#!/usr/bin/env bash
args=("$@"); destination=${args[${#args[@]}-1]}
"$REAL_CP" "$@" || exit $?
if [[ $destination == *.arclith-rollback.* ]]; then printf 'corrupt staged rollback bytes\n' > "$destination"; fi
EOF
cat > "$corrupt_mv/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MARKER ]]; then : > "$FAIL_MARKER"; exit 68; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$corrupt_cp/cp" "$corrupt_mv/mv"
status=0
output=$(PATH="$corrupt_cp:$corrupt_mv:$PATH" REAL_CP="$real_cp" REAL_MV="$real_mv" \
  FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" FAIL_MARKER="$test_root/restore-corrupt-manifest-failed" \
  run_restore 2>&1) || status=$?
assert 'corrupt staged restore rollback returns failure' test "$status" -eq 1
contains 'restore rejects corrupted staged rollback copy' 'failed hash verification' "$output"
assert 'restore does not install corrupted staged rollback bytes' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" != 'corrupt staged rollback bytes'
assert 'restore leaves the selected restore content when rollback copy is corrupt' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'prior user configuration'
rollback_backup_found=0
while IFS= read -r backup_path; do
  if [[ $(<"$backup_path") == 'restore rollback backup sentinel' ]]; then rollback_backup_found=1; break; fi
done < <(find "$HOME_FIXTURE" -type f -name 'kitty.conf.arclith-backup.*' -print)
assert 'restore retains original current-target recovery backup' test "$rollback_backup_found" -eq 1
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'corrupt restore rollback is transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction"
assert 'corrupt restore rollback is target UNCERTAIN' test "$CONFIG_TXN_TARGET_STATE" = UNCERTAIN

# A target rollback that succeeds but whose ROLLED_BACK checkpoint cannot be
# persisted leaves the last confirmed target state and transaction uncertain.
new_fixture rollback-checkpoint-failure
printf 'rollback checkpoint sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/rollback-checkpoint-count" FAIL_AT=7 \
  FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" FAIL_MANIFEST_MARKER="$test_root/rollback-checkpoint-manifest-marker" \
  run_restore >"$test_root/rollback-checkpoint-failure.out" 2>&1 || status=$?
assert 'ROLLED_BACK persistence failure returns failure' test "$status" -eq 1
assert 'ROLLED_BACK persistence failure restores prior target' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'rollback checkpoint sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'ROLLED_BACK persistence failure leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction"
assert 'failed rollback outcome checkpoint retains ROLLBACK_INTENT' test "$CONFIG_TXN_TARGET_STATE" = ROLLBACK_INTENT

new_fixture rollback-failure
printf 'rollback failure sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
rollback_mock="$test_root/fail-rollback-mv"
mkdir -p "$rollback_mock"
cat > "$rollback_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MANIFEST_MARKER ]]; then : > "$FAIL_MANIFEST_MARKER"; exit 69; fi
if [[ $destination == "$FAIL_TARGET" ]]; then
  count=0; [[ ! -f $FAIL_TARGET_COUNT ]] || read -r count < "$FAIL_TARGET_COUNT"
  ((count += 1)); printf '%s\n' "$count" > "$FAIL_TARGET_COUNT"
  if (( count == 2 )); then exit 70; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$rollback_mock/mv"
status=0
PATH="$rollback_mock:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" \
  FAIL_MANIFEST_MARKER="$test_root/rollback-failure-manifest-marker" FAIL_TARGET="$HOME_FIXTURE/.config/kitty/kitty.conf" \
  FAIL_TARGET_COUNT="$test_root/rollback-failure-target-count" run_restore >"$test_root/rollback-failure.out" 2>&1 || status=$?
assert 'rollback replacement failure returns failure' test "$status" -eq 1
assert 'rollback replacement failure leaves target for diagnosis' test "$(<"$HOME_FIXTURE/.config/kitty/kitty.conf")" = 'prior user configuration'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_transaction "$HOME_FIXTURE" "$transaction"
assert 'rollback replacement failure leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction"
assert 'rollback replacement failure marks target UNCERTAIN' test "$CONFIG_TXN_TARGET_STATE" = UNCERTAIN

# Invalid source backup and failed lock acquisition stop before transaction or
# target mutation; every command return also releases the lock for retry.
new_fixture invalid-source
rm -- "$HOME_FIXTURE/.config/kitty/kitty.conf.arclith-backup.$BACKUP_ID"
status=0
run_restore >"$test_root/missing-source.out" 2>&1 || status=$?
assert 'missing source backup is refused' test "$status" -eq 1
transaction_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
assert 'missing source backup creates no transaction' test "$transaction_count" -eq 1

new_fixture lock-release
status=0
run_restore >/dev/null 2>&1 || status=$?
assert 'successful restore returns zero' test "$status" -eq 0
assert 'lock can be reacquired after restore success' config_lock_acquire "$HOME_FIXTURE"
config_lock_release

new_fixture lock-contention
lock_path="$HOME_FIXTURE/.local/state/arclith/operation.lock"
ready="$test_root/lock-ready"
gate="$test_root/lock-gate"
mkfifo "$gate"
flock -x "$lock_path" bash -c 'touch "$1"; read -r _ < "$2"' _ "$ready" "$gate" &
holder_pid=$!
ready_status=0
for ((attempt=0; attempt<200; attempt++)); do [[ -e $ready ]] && { ready_status=1; break; }; sleep 0.01; done
assert 'external lock holder reaches synchronized point' test "$ready_status" -eq 1
before_count=$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
status=0
run_restore >"$test_root/lock-contention.out" 2>&1 || status=$?
assert 'conflicting restore returns lock-busy status' test "$status" -eq 75
assert 'lock contention creates no restore transaction' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq "$before_count"
printf 'continue\n' > "$gate"
wait "$holder_pid"
assert 'lock contention preserves target' cmp -s "$HOME_FIXTURE/.config/kitty/kitty.conf" "$FIXTURE/core/configs/kitty/kitty.conf"

# If hashing the restored target fails while building its managed-state
# record, restore must fail, roll back, and leave the previous manifest valid.
new_fixture managed-digest-failure
printf 'restore digest failure sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
manifest="$HOME_FIXTURE/.local/state/arclith/deployments.v1"
manifest_before=$(sha256sum "$manifest")
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
hash_mock="$test_root/fail-restore-managed-hash"
mkdir -p "$hash_mock"
cat > "$hash_mock/sha256sum" <<'EOF'
#!/usr/bin/env bash
path=${!#}
if [[ $path == "$HASH_FAIL_PATH" && ! -e $HASH_FAIL_MARKER ]]; then
  : > "$HASH_FAIL_MARKER"
  if [[ $HASH_FAIL_MODE == malformed ]]; then printf 'malformed  %s\n' "$path"; exit 0; fi
  exit 55
fi
exec "$REAL_SHA256SUM" "$@"
EOF
chmod +x "$hash_mock/sha256sum"
real_sha256sum=$(command -v sha256sum)
status=0
PATH="$hash_mock:$PATH" REAL_SHA256SUM="$real_sha256sum" HASH_FAIL_PATH="$target" HASH_FAIL_MARKER="$test_root/restore-hash-failed" HASH_FAIL_MODE=fail \
  run_restore >"$test_root/restore-hash-failure.out" 2>&1 || status=$?
assert 'restore managed-target hash failure returns failure' test "$status" -eq 1
assert 'restore hash failure rolls back the installed target' test "$(<"$target")" = 'restore digest failure sentinel'
assert 'restore hash failure preserves the previous manifest' test "$(sha256sum "$manifest")" = "$manifest_before"
state_status=0
config_load_registry "$FIXTURE" && config_state_load "$HOME_FIXTURE" || state_status=$?
assert 'restore hash failure leaves the previous manifest readable' test "$state_status" -eq 0
recovery_backup_found=0
while IFS= read -r backup_path; do
  if [[ $(<"$backup_path") == 'restore digest failure sentinel' ]]; then recovery_backup_found=1; break; fi
done < <(find "$HOME_FIXTURE" -type f -name 'kitty.conf.arclith-backup.*' -print)
assert 'restore hash failure retains the current-target recovery backup' test "$recovery_backup_found" -eq 1

printf 'Restore checkpoint integration tests passed; all homes were isolated under %s.\n' "$test_root"
