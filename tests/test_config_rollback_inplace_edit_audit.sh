#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-rollback-inplace-audit.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fixture="$test_root/project"
home_fixture="$test_root/home"
mock_bin="$test_root/mock-bin"
target="$home_fixture/.config/kitty/kitty.conf"
state_file="$home_fixture/.local/state/arclith/deployments.v1"
real_mv=$(command -v mv)
mkdir -p "$fixture" "$home_fixture/.config/kitty" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$fixture/"
printf 'original fixture content\n' > "$target"
chmod 640 "$target"

cat > "$mock_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

destination=${!#}
if [[ $destination == "$FAIL_STATE_TARGET" && ! -e $FAIL_STATE_MARKER ]]; then
  : > "$FAIL_STATE_MARKER"
  exit 73
fi

"$REAL_MV" "$@"
if [[ $destination == "$EDIT_TARGET" && ! -e $EDIT_MARKER ]]; then
  before=$(stat -c '%d:%i' -- "$EDIT_TARGET")
  printf 'intervening in-place edit\n' > "$EDIT_TARGET"
  after=$(stat -c '%d:%i' -- "$EDIT_TARGET")
  printf '%s\n%s\n' "$before" "$after" > "$EDIT_MARKER"
fi
EOF
chmod +x "$mock_bin/mv"

status=0
output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" \
  FAIL_STATE_TARGET="$state_file" FAIL_STATE_MARKER="$test_root/state-failure-once" \
  EDIT_TARGET="$target" EDIT_MARKER="$test_root/in-place-edit-inodes" \
  HOME="$home_fixture" "$fixture/arclith.sh" config apply kitty --yes 2>&1) || status=$?

[[ $status -eq 1 ]] || { printf 'not ok - injected manifest failure should enter rollback (status=%s)\n' "$status" >&2; exit 1; }
[[ -s $test_root/in-place-edit-inodes ]] || { printf 'not ok - replacement was not edited in place\n' >&2; exit 1; }
mapfile -t inode_values < "$test_root/in-place-edit-inodes"
before_inode=${inode_values[0]:-}
after_inode=${inode_values[1]:-}
[[ $before_inode == "$after_inode" ]] || { printf 'not ok - edit changed the replacement inode\n' >&2; exit 1; }
[[ $output == *'deployment rollback was incomplete'* && $output == *'preserving the target and recovery copies'* ]] \
  || { printf 'not ok - apply conflict was not preserved and reported uncertain\n%s\n' "$output" >&2; exit 1; }

observed=$(<"$target")
if [[ $observed == 'intervening in-place edit' ]]; then
  apply_journal=$(find "$home_fixture/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -print -quit)
  apply_id=${apply_journal##*/}; apply_id=${apply_id%.v1}
  apply_target_record="$home_fixture/.local/state/arclith/transactions/$apply_id.targets/000000.v1"
  apply_backup=$(find "$home_fixture" -type f -name 'kitty.conf.arclith-backup.*' -print -quit)
  grep -q '^STATE|UNCERTAIN$' "$apply_journal" \
    || { printf 'not ok - apply transaction was not marked UNCERTAIN\n' >&2; exit 1; }
  grep -q '^STATE|UNCERTAIN$' "$apply_target_record" \
    || { printf 'not ok - apply target was not marked UNCERTAIN\n' >&2; exit 1; }
  [[ -n $apply_backup ]] && [[ $(<"$apply_backup") == 'original fixture content' ]] \
    || { printf 'not ok - apply recovery backup was not retained\n' >&2; exit 1; }
  printf 'ok - apply conflict preserved the in-place edit and retained its original backup\n'
  printf 'ok - apply target and transaction journal are UNCERTAIN\n'
  printf 'ok - inode remained %s across the intervening write\n' "$before_inode"
  printf 'PROTECTED - rollback did not replace the intervening edit\n'
else
  printf 'not ok - apply intervening content was not preserved: %s\n' "$observed" >&2
  exit 1
fi

# Restore uses the same inode-only protection. Seed its selected backup with a
# normal apply, then inject the edit after restore replaces the target and fail
# the later manifest rename to execute restore's real rollback branch.
restore_fixture="$test_root/restore-project"
restore_home="$test_root/restore-home"
restore_target="$restore_home/.config/kitty/kitty.conf"
restore_state="$restore_home/.local/state/arclith/deployments.v1"
mkdir -p "$restore_fixture" "$restore_home/.config/kitty"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$restore_fixture/"
printf 'restore original fixture content\n' > "$restore_target"
chmod 640 "$restore_target"
HOME="$restore_home" "$restore_fixture/arclith.sh" config apply kitty --yes >/dev/null
backup_id=$(HOME="$restore_home" "$restore_fixture/arclith.sh" config backups | awk '/available$/{print $1; exit}')
[[ $backup_id =~ ^[A-Za-z0-9]{8}$ ]] || { printf 'not ok - fixture restore backup was not recorded\n' >&2; exit 1; }

restore_status=0
restore_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" \
  FAIL_STATE_TARGET="$restore_state" FAIL_STATE_MARKER="$test_root/restore-state-failure-once" \
  EDIT_TARGET="$restore_target" EDIT_MARKER="$test_root/restore-in-place-edit-inodes" \
  HOME="$restore_home" "$restore_fixture/arclith.sh" config restore "$backup_id" --yes 2>&1) || restore_status=$?
[[ $restore_status -eq 1 ]] || { printf 'not ok - injected restore manifest failure should enter rollback (status=%s)\n' "$restore_status" >&2; exit 1; }
mapfile -t restore_inode_values < "$test_root/restore-in-place-edit-inodes"
[[ ${restore_inode_values[0]:-} == "${restore_inode_values[1]:-}" ]] \
  || { printf 'not ok - restore edit changed the replacement inode\n' >&2; exit 1; }
[[ $restore_output == *'preserving the target and recovery copies'* ]] \
  || { printf 'not ok - restore conflict was not reported\n%s\n' "$restore_output" >&2; exit 1; }
if [[ $(<"$restore_target") == 'intervening in-place edit' ]]; then
  restore_journal=$(find "$restore_home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' \
    -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  restore_id=${restore_journal##*/}; restore_id=${restore_id%.v1}
  restore_target_record="$restore_home/.local/state/arclith/transactions/$restore_id.targets/000000.v2"
  grep -q '^STATE|UNCERTAIN$' "$restore_journal" \
    || { printf 'not ok - restore transaction was not marked UNCERTAIN\n' >&2; exit 1; }
  grep -q '^STATE|UNCERTAIN$' "$restore_target_record" \
    || { printf 'not ok - restore target was not marked UNCERTAIN\n' >&2; exit 1; }
  [[ -n $(find "$restore_home" -type f -name 'kitty.conf.arclith-backup.*' -print -quit) ]] \
    || { printf 'not ok - restore recovery backups were not retained\n' >&2; exit 1; }
  printf 'ok - restore conflict preserved the in-place edit and retained recovery backups\n'
  printf 'ok - restore target and transaction journal are UNCERTAIN\n'
  printf 'ok - restore inode remained %s across the intervening write\n' "${restore_inode_values[0]}"
  printf 'PROTECTED - restore rollback did not replace the intervening edit\n'
else
  printf 'not ok - restore intervening content was not preserved\n' >&2
  exit 1
fi
