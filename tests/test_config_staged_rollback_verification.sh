#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-staged-rollback.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
mock_bin="$test_root/bin"
mkdir -p "$mock_bin"
real_mv=$(command -v mv)

cat > "$mock_bin/mv" <<'MOCK'
#!/usr/bin/env bash
destination=${!#}
source=${@: -2:1}
if [[ ${CASE_MODE:-none} == apply-rollback && $destination == */transactions/*.targets/000001.v1 \
  && $source == *.tmp.* && ! -e $FAIL_SECOND_MARKER ]] && grep -q '^STATE|MUTATION_INTENT$' "$source"; then
  : > "$FAIL_SECOND_MARKER"
  exit 47
fi
if [[ ${CASE_MODE:-none} == restore-rollback && $destination == "$STATE_TARGET" \
  && $source == *deployments.* && ! -e $FAIL_STATE_MARKER ]]; then
  : > "$FAIL_STATE_MARKER"
  exit 48
fi
if [[ ${CASE_MODE:-none} == uninstall-rollback && $destination == "$STATE_TARGET" \
  && $source == *deployments.* ]]; then
  count=0
  [[ ! -f $STATE_COUNT_FILE ]] || count=$(<"$STATE_COUNT_FILE")
  count=$((count + 1))
  printf '%s\n' "$count" > "$STATE_COUNT_FILE"
  if [[ $count -eq 2 && ! -e $FAIL_STATE_MARKER ]]; then
    : > "$FAIL_STATE_MARKER"
    exit 49
  fi
fi
if [[ $destination == "$LIVE_TARGET" && $source == *.arclith-restore.* \
  && ${CASE_MODE:-none} == apply-rollback && ! -e $ROLLBACK_EDIT_MARKER ]]; then
  printf 'rollback stage changed before rename\n' > "$source"
  : > "$ROLLBACK_EDIT_MARKER"
fi
if [[ $destination == "$LIVE_TARGET" && $source == *.arclith-rollback.* \
  && ( ${CASE_MODE:-none} == restore-rollback || ${CASE_MODE:-none} == uninstall-rollback ) \
  && ! -e $ROLLBACK_EDIT_MARKER ]]; then
  printf 'rollback stage changed before rename\n' > "$source"
  : > "$ROLLBACK_EDIT_MARKER"
fi
exec "$REAL_MV" "$@"
MOCK
chmod +x "$mock_bin/mv"

assert_uncertain() {
  local label=$1 home=$2 target=$3 output=$4
  [[ $output == *'identity or content verification failed'* ]] \
    || { printf 'not ok - %s did not report failed rollback verification\n%s\n' "$label" "$output" >&2; exit 1; }
  [[ $(<"$target") == 'rollback stage changed before rename' ]] \
    || { printf 'not ok - %s did not preserve the conflicting target\n' "$label" >&2; exit 1; }
  local journal
  journal=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  [[ -n $journal ]] && grep -q '^STATE|UNCERTAIN$' "$journal" \
    || { printf 'not ok - %s transaction was not marked UNCERTAIN\n' "$label" >&2; exit 1; }
  printf 'ok - %s rollback conflict was preserved and recorded UNCERTAIN\n' "$label"
}

# Apply rollback restores the existing file after a later target replacement
# fails. Change its restore stage exactly at mv and confirm the new guard stops.
apply_fixture="$test_root/apply-project" apply_home="$test_root/apply-home"
mkdir -p "$apply_fixture" "$apply_home/.config/kitty"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$apply_fixture/"
printf 'original kitty configuration\n' > "$apply_home/.config/kitty/kitty.conf"
printf 'second source file\n' > "$apply_fixture/core/configs/kitty/z-extra.conf"
apply_target="$apply_home/.config/kitty/kitty.conf"
second_target="$apply_home/.config/kitty/z-extra.conf"
printf 'original second target configuration\n' > "$second_target"
apply_status=0
apply_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" CASE_MODE=apply-rollback \
  LIVE_TARGET="$second_target" SECOND_TARGET="$apply_target" \
  FAIL_SECOND_MARKER="$test_root/apply-failed-second" ROLLBACK_EDIT_MARKER="$test_root/apply-rollback-edited" \
  HOME="$apply_home" "$apply_fixture/arclith.sh" config apply kitty --yes 2>&1) || apply_status=$?
[[ $apply_status -eq 1 ]] \
  || { printf 'not ok - apply rollback fixture did not stop at the later target checkpoint\n%s\n' "$apply_output" >&2; exit 1; }
assert_uncertain apply "$apply_home" "$second_target" "$apply_output"

# Restore rolls back its replacement after manifest persistence fails. A
# modified rollback stage must not be recorded as ROLLED_BACK.
restore_fixture="$test_root/restore-project" restore_home="$test_root/restore-home"
mkdir -p "$restore_fixture" "$restore_home/.config/kitty"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$restore_fixture/"
restore_target="$restore_home/.config/kitty/kitty.conf"
printf 'restore original configuration\n' > "$restore_target"
HOME="$restore_home" "$restore_fixture/arclith.sh" config apply kitty --yes >/dev/null
restore_id=$(HOME="$restore_home" "$restore_fixture/arclith.sh" config backups | awk '/available$/{print $1; exit}')
[[ $restore_id =~ ^[A-Za-z0-9]{8}$ ]] || { printf 'not ok - restore rollback fixture has no backup\n' >&2; exit 1; }
restore_state="$restore_home/.local/state/arclith/deployments.v1"
restore_state_before=$(sha256sum "$restore_state")
restore_status=0
restore_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" CASE_MODE=restore-rollback \
  LIVE_TARGET="$restore_target" STATE_TARGET="$restore_state" \
  FAIL_STATE_MARKER="$test_root/restore-state-failed" ROLLBACK_EDIT_MARKER="$test_root/restore-rollback-edited" \
  HOME="$restore_home" "$restore_fixture/arclith.sh" config restore "$restore_id" --yes 2>&1) || restore_status=$?
[[ $restore_status -eq 1 && $(sha256sum "$restore_state") == "$restore_state_before" ]] \
  || { printf 'not ok - restore rollback fixture did not preserve the old manifest\n%s\n' "$restore_output" >&2; exit 1; }
assert_uncertain restore "$restore_home" "$restore_target" "$restore_output"

# Uninstall/prune rollback likewise installs a staged recovery copy. Fail the
# state rename, alter that recovery stage before rename, and require uncertainty.
uninstall_fixture="$test_root/uninstall-project" uninstall_home="$test_root/uninstall-home"
mkdir -p "$uninstall_fixture" "$uninstall_home"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$uninstall_fixture/"
HOME="$uninstall_home" "$uninstall_fixture/arclith.sh" config apply kitty --yes >/dev/null
uninstall_target="$uninstall_home/.config/kitty/kitty.conf"
uninstall_state="$uninstall_home/.local/state/arclith/deployments.v1"
uninstall_status=0
uninstall_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" CASE_MODE=uninstall-rollback \
  LIVE_TARGET="$uninstall_target" STATE_TARGET="$uninstall_state" \
  FAIL_STATE_MARKER="$test_root/uninstall-state-failed" STATE_COUNT_FILE="$test_root/uninstall-state-count" \
  ROLLBACK_EDIT_MARKER="$test_root/uninstall-rollback-edited" \
  HOME="$uninstall_home" "$uninstall_fixture/arclith.sh" config uninstall kitty --yes 2>&1) || uninstall_status=$?
[[ $uninstall_status -eq 1 && -f $uninstall_state ]] \
  || { printf 'not ok - uninstall rollback fixture did not retain ownership state\n%s\n' "$uninstall_output" >&2; exit 1; }
assert_uncertain uninstall "$uninstall_home" "$uninstall_target" "$uninstall_output"
