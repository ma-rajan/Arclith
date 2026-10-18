#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-target-checkpoints.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source "$repo_root/core/config.sh"
real_mv=$(command -v mv)
real_rm=$(command -v rm)
real_cp=$(command -v cp)

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
  mkdir -p "$FIXTURE" "$HOME_FIXTURE"
  cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
    "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$FIXTURE/"
}
latest_transaction() {
  local home=$1 path
  path=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' \
    | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  [[ -n $path ]] || return 1
  printf '%s' "${path##*/}" | sed 's/\.v1$//'
}
read_tx() { config_transaction_journal_read "$1" "$2"; }
read_target() { config_transaction_target_read "$1" "$2" "$3"; }

# Preview and dry-run paths must not create even the journal directory.
new_fixture preview
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config preview kitty >/dev/null
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply-new kitty --dry-run >/dev/null
assert 'preview and apply-new dry-run create no journal directory' test ! -e "$HOME_FIXTURE/.local/state/arclith/transactions"

# A successful multi-target apply records each target and completes only after
# the deployment manifest save has succeeded.
new_fixture success
mkdir -p "$FIXTURE/core/configs/kitty/extra"
printf 'second target\n' > "$FIXTURE/core/configs/kitty/extra/second.conf"
mkdir -p "$HOME_FIXTURE/.config/kitty"
printf 'preexisting user target\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes >"$test_root/success.out"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'successful transaction reaches COMPLETE' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
assert 'successful transaction operation is apply' test "$CONFIG_TXN_JOURNAL_OPERATION" = apply
assert 'successful multi-target transaction has two checkpoints' test "$(find "$HOME_FIXTURE/.local/state/arclith/transactions/$transaction.targets" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq 2
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'first target is checkpointed APPLIED' test "$CONFIG_TXN_TARGET_STATE" = APPLIED
read_target "$HOME_FIXTURE" "$transaction" 000001
assert 'second target is checkpointed APPLIED' test "$CONFIG_TXN_TARGET_STATE" = APPLIED
backup_checkpoint_found=0
for index in 000000 000001; do
  read_target "$HOME_FIXTURE" "$transaction" "$index"
  if [[ $CONFIG_TXN_TARGET_PATH == .config/kitty/kitty.conf ]]; then
    assert 'existing target presence is recorded' test "$CONFIG_TXN_TARGET_ORIGINAL" = yes
    assert 'existing target checkpoint references its tracked backup ID' bash -c '[[ "$1" =~ ^[A-Za-z0-9]{8}$ ]]' _ "$CONFIG_TXN_TARGET_BACKUP"
    backup_checkpoint_found=1
  fi
done
assert 'preexisting target has a checkpoint' test "$backup_checkpoint_found" -eq 1

# apply-new uses the same checkpoint protocol and retains its operation name.
printf 'new apply-new target\n' > "$FIXTURE/core/configs/kitty/new-theme.conf"
HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply-new kitty --yes >"$test_root/apply-new.out"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'apply-new transaction is distinguished in the journal' test "$CONFIG_TXN_JOURNAL_OPERATION" = apply-new
assert 'apply-new transaction reaches COMPLETE' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'apply-new target reaches APPLIED' test "$CONFIG_TXN_TARGET_STATE" = APPLIED

# A COMPLETE journal rename that lands before its wrapper reports failure is
# reconciled, allowing the committed apply call to return success accurately.
new_fixture ambiguous-complete-transition
ambiguous_mv="$test_root/complete-mv-then-fail"
mkdir -p "$ambiguous_mv"
cat > "$ambiguous_mv/mv" <<'EOF'
#!/usr/bin/env bash
args=("$@"); source_path=${args[${#args[@]}-2]}; destination=${args[${#args[@]}-1]}
if [[ $destination == */transactions/*.v1 && ! -e $COMPLETE_MARKER ]] \
  && grep -q '^STATE|COMPLETE$' "$source_path"; then
  "$REAL_MV" "$@" || exit $?
  : > "$COMPLETE_MARKER"
  exit 69
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$ambiguous_mv/mv"
status=0
output=$(PATH="$ambiguous_mv:$PATH" REAL_MV="$real_mv" COMPLETE_MARKER="$test_root/complete-renamed-marker" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'apply returns success when COMPLETE persisted despite mv status' test "$status" -eq 0
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'ambiguous apply transition leaves persisted COMPLETE state' test "$CONFIG_TXN_JOURNAL_STATE" = COMPLETE
assert 'ambiguous apply transition leaves committed target and manifest' \
  test -f "$HOME_FIXTURE/.config/kitty/kitty.conf" -a -f "$HOME_FIXTURE/.local/state/arclith/deployments.v1"
assert 'ambiguous apply transition leaves no journal temporary file' \
  bash -c '[[ -z $(find "$1/.local/state/arclith/transactions" -maxdepth 1 -type f -name ".*.tmp.*" -print -quit) ]]' _ "$HOME_FIXTURE"

# Failure after MUTATION_INTENT but before the target rename is confirmed as
# NOT_MUTATED, with the transaction safely terminal as ROLLED_BACK.
new_fixture before-mutation
mock="$test_root/fail-target-mv"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_TARGET" ]]; then exit 41; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
output=$(PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_TARGET="$target" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'failed target rename returns failure' test "$status" -eq 1
assert 'failed target rename leaves target absent' test ! -e "$target"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'pre-mutation failure is recorded as ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'unreached target mutation is recorded NOT_MUTATED' test "$CONFIG_TXN_TARGET_STATE" = NOT_MUTATED

# A failed mutation-intent write must stop before the target rename.
new_fixture intent-checkpoint-failure
mock="$test_root/fail-intent-checkpoint"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.targets/000000.v1 ]]; then
  count=0
  [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1))
  printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == 3 )); then exit 44; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
output=$(PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/intent-count" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'mutation-intent persistence failure returns failure' test "$status" -eq 1
contains 'mutation-intent persistence failure is explicit' 'Could not persist mutation intent' "$output"
assert 'mutation-intent persistence failure leaves target absent' test ! -e "$target"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'pre-mutation journal failure resolves to ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'failed intent checkpoint never claims target application' test "$CONFIG_TXN_TARGET_STATE" = NOT_MUTATED

# Fail only the fourth atomic replacement of this target checkpoint: PLANNED,
# STAGED, MUTATION_INTENT succeed, then APPLIED persistence fails. The target
# must be rolled back and must never be reported as APPLIED.
new_fixture applied-checkpoint-failure
mock="$test_root/fail-applied-checkpoint"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.targets/000000.v1 ]]; then
  count=0
  [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1))
  printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == 4 )); then exit 42; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
output=$(PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/applied-count" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'APPLIED checkpoint failure returns failure' test "$status" -eq 1
assert 'APPLIED checkpoint failure rolls target back' test ! -e "$target"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'successful rollback reaches ROLLED_BACK' test "$CONFIG_TXN_JOURNAL_STATE" = ROLLED_BACK
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'rolled-back target is not falsely marked APPLIED' test "$CONFIG_TXN_TARGET_STATE" = ROLLED_BACK

# A failed final transaction write occurs after both targets and the manifest
# have been saved. The journal is moved to UNCERTAIN where possible and files
# remain intact for diagnosis.
new_fixture completion-checkpoint-failure
mock="$test_root/fail-complete"
mkdir -p "$mock"
cat > "$mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == */transactions/*.v1 && $destination != */transactions/*.targets/*.v1 ]]; then
  count=0
  [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1))
  printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == 5 )); then exit 43; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock/mv"
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
output=$(PATH="$mock:$PATH" REAL_MV="$real_mv" FAIL_COUNT="$test_root/complete-count" HOME="$HOME_FIXTURE" \
  "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'completion checkpoint failure is surfaced' test "$status" -eq 1
contains 'completion checkpoint failure is explicit' 'journal completion checkpoint failed' "$output"
assert 'completed target and manifest remain present' test -f "$target" && test -f "$HOME_FIXTURE/.local/state/arclith/deployments.v1"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'failed completion checkpoint leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'confirmed target remains APPLIED under uncertain transaction' test "$CONFIG_TXN_TARGET_STATE" = APPLIED

# A failed ROLLBACK_INTENT checkpoint must stop apply rollback before either a
# replacement or removal. The later UNCERTAIN checkpoint is allowed to persist.
new_fixture rollback-intent-checkpoint-failure
mkdir -p "$HOME_FIXTURE/.config/kitty"
printf 'rollback intent original sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
intent_mock="$test_root/fail-apply-rollback-intent"
mkdir -p "$intent_mock"
cat > "$intent_mock/mv" <<'EOF'
#!/usr/bin/env bash
args=("$@"); source_path=${args[${#args[@]}-2]}; destination=${args[${#args[@]}-1]}
if [[ $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MANIFEST_MARKER ]]; then : > "$FAIL_MANIFEST_MARKER"; exit 65; fi
if [[ $destination == */transactions/*.targets/*.v1 ]] && grep -q '^STATE|ROLLBACK_INTENT$' "$source_path" \
  && [[ ! -e $FAIL_INTENT_MARKER ]]; then : > "$FAIL_INTENT_MARKER"; exit 66; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$intent_mock/mv"
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
output=$(PATH="$intent_mock:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" \
  FAIL_MANIFEST_MARKER="$test_root/apply-intent-manifest-failed" FAIL_INTENT_MARKER="$test_root/apply-intent-failed" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'apply rollback-intent persistence failure returns failure' test "$status" -eq 1
contains 'apply reports that rollback stopped before target mutation' 'target was left unchanged by rollback' "$output"
assert 'apply does not restore over the target after intent failure' cmp -s "$target" "$FIXTURE/core/configs/kitty/kitty.conf"
intent_backup=$(find "$HOME_FIXTURE" -type f -name 'kitty.conf.arclith-backup.*' -print -quit)
assert 'apply keeps the original recovery backup after intent failure' test -n "$intent_backup" && test "$(<"$intent_backup")" = 'rollback intent original sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'apply intent failure is persisted as transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'apply intent failure is persisted as target UNCERTAIN' test "$CONFIG_TXN_TARGET_STATE" = UNCERTAIN

# The same fail-closed intent policy applies when the original target was absent.
new_fixture rollback-intent-absent
rm -- "$FIXTURE/core/configs/kitty/kitty.conf"
printf 'only absent-target fixture\n' > "$FIXTURE/core/configs/kitty/only.conf"
status=0
output=$(PATH="$intent_mock:$PATH" REAL_MV="$real_mv" FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" \
  FAIL_MANIFEST_MARKER="$test_root/apply-intent-absent-manifest-failed" FAIL_INTENT_MARKER="$test_root/apply-intent-absent-failed" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
target="$HOME_FIXTURE/.config/kitty/only.conf"
assert 'absent-target apply intent failure returns failure' test "$status" -eq 1
contains 'absent-target apply reports rollback stopped' 'target was left unchanged by rollback' "$output"
assert 'absent target created by apply is not removed after intent failure' test "$(<"$target")" = 'only absent-target fixture'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'absent-target intent failure persists transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'absent-target intent failure persists target UNCERTAIN' test "$CONFIG_TXN_TARGET_STATE" = UNCERTAIN

# A staged apply rollback copy must still match the fingerprint captured from
# the original backup before it may replace the deployed target.
new_fixture rollback-backup-corruption
mkdir -p "$HOME_FIXTURE/.config/kitty"
printf 'apply rollback backup sentinel\n' > "$HOME_FIXTURE/.config/kitty/kitty.conf"
corrupt_cp="$test_root/corrupt-apply-rollback-stage"
corrupt_mv="$test_root/fail-apply-manifest"
mkdir -p "$corrupt_cp" "$corrupt_mv"
cat > "$corrupt_cp/cp" <<'EOF'
#!/usr/bin/env bash
args=("$@"); destination=${args[${#args[@]}-1]}
"$REAL_CP" "$@" || exit $?
if [[ $destination == *.arclith-restore.* ]]; then printf 'corrupt staged rollback bytes\n' > "$destination"; fi
EOF
cat > "$corrupt_mv/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MANIFEST" && ! -e $FAIL_MARKER ]]; then : > "$FAIL_MARKER"; exit 67; fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$corrupt_cp/cp" "$corrupt_mv/mv"
target="$HOME_FIXTURE/.config/kitty/kitty.conf"
status=0
output=$(PATH="$corrupt_cp:$corrupt_mv:$PATH" REAL_CP="$real_cp" REAL_MV="$real_mv" \
  FAIL_MANIFEST="$HOME_FIXTURE/.local/state/arclith/deployments.v1" FAIL_MARKER="$test_root/apply-corrupt-manifest-failed" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'corrupt staged apply rollback returns failure' test "$status" -eq 1
contains 'apply rejects corrupted staged rollback copy' 'failed hash verification' "$output"
assert 'apply does not install corrupted staged rollback bytes' test "$(<"$target")" != 'corrupt staged rollback bytes'
assert 'apply does not claim original bytes were restored' test "$(<"$target")" != 'apply rollback backup sentinel'
apply_backup=$(find "$HOME_FIXTURE" -type f -name 'kitty.conf.arclith-backup.*' -print -quit)
assert 'apply retains original backup after staged-copy corruption' test -n "$apply_backup" && test "$(<"$apply_backup")" = 'apply rollback backup sentinel'
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'corrupt apply rollback is transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
read_target "$HOME_FIXTURE" "$transaction" 000000
assert 'corrupt apply rollback is target UNCERTAIN' test "$CONFIG_TXN_TARGET_STATE" = UNCERTAIN

# If rollback itself cannot remove a newly applied target, both the target and
# transaction records remain UNCERTAIN rather than claiming rollback success.
new_fixture rollback-failure
rm -- "$FIXTURE/core/configs/kitty/kitty.conf"
printf 'first checkpoint target\n' > "$FIXTURE/core/configs/kitty/a.conf"
printf 'second checkpoint target\n' > "$FIXTURE/core/configs/kitty/b.conf"
mv_mock="$test_root/fail-second-target-mv"
rm_mock="$test_root/fail-rollback-rm"
mkdir -p "$mv_mock" "$rm_mock"
cat > "$mv_mock/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$HOME/.config/kitty/"* ]]; then
  count=0
  [[ ! -f $FAIL_COUNT ]] || read -r count < "$FAIL_COUNT"
  ((count += 1))
  printf '%s\n' "$count" > "$FAIL_COUNT"
  if (( count == 1 )); then printf '%s\n' "$destination" > "$FAIL_FIRST_TARGET"; fi
  if (( count == 2 )); then exit 45; fi
fi
exec "$REAL_MV" "$@"
EOF
cat > "$rm_mock/rm" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ -f $FAIL_FIRST_TARGET && $destination == "$(<"$FAIL_FIRST_TARGET")" ]]; then exit 46; fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$mv_mock/mv" "$rm_mock/rm"
status=0
output=$(PATH="$mv_mock:$rm_mock:$PATH" REAL_MV="$real_mv" REAL_RM="$real_rm" \
  FAIL_COUNT="$test_root/rollback-mv-count" FAIL_FIRST_TARGET="$test_root/rollback-first-target" \
  HOME="$HOME_FIXTURE" "$FIXTURE/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'rollback failure returns failure' test "$status" -eq 1
contains 'rollback failure is reported' 'deployment rollback was incomplete' "$output"
first_target=$(<"$test_root/rollback-first-target")
assert 'target with failed rollback remains for diagnosis' test -f "$first_target"
transaction=$(latest_transaction "$HOME_FIXTURE")
read_tx "$HOME_FIXTURE" "$transaction"
assert 'failed rollback leaves transaction UNCERTAIN' test "$CONFIG_TXN_JOURNAL_STATE" = UNCERTAIN
checkpoint_found=0
for index in 000000 000001; do
  read_target "$HOME_FIXTURE" "$transaction" "$index"
  if [[ $HOME_FIXTURE/${CONFIG_TXN_TARGET_PATH} == "$first_target" ]]; then
    assert 'target with failed rollback is UNCERTAIN' test "$CONFIG_TXN_TARGET_STATE" = UNCERTAIN
    checkpoint_found=1
  fi
done
assert 'surviving target has a checkpoint' test "$checkpoint_found" -eq 1

printf 'Per-target transaction checkpoint tests passed; all lifecycle fixtures were isolated under %s.\n' "$test_root"
