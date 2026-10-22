#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-staged-rename-race.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project" home="$test_root/home" mock_bin="$test_root/bin"
mkdir -p "$fixture" "$home/.config/kitty" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$fixture/"
target="$home/.config/kitty/kitty.conf"
printf 'original user configuration\n' > "$target"
real_mv=$(command -v mv)
real_cp=$(command -v cp)
real_sha256sum=$(command -v sha256sum)

# Change the staged inode after Arclith's last staged hash check, exactly when
# it is about to be renamed into the target. This deterministically models the
# same-user, non-cooperating writer window without touching the real HOME.
cat > "$mock_bin/mv" <<'MOCK'
#!/usr/bin/env bash
destination=${!#}
source=${@: -2:1}
if [[ $destination == "$RACE_TARGET" && ! -e $RACE_MARKER ]]; then
  case ${RACE_MODE:-none}:$source in
    changed:*.arclith-new.*|restore-changed:*.arclith-restore.*)
      printf 'bytes changed in the final check-to-rename window\n' > "$source"
      : > "$RACE_MARKER"
      ;;
    inode:*.arclith-new.*|restore-inode:*.arclith-restore.*)
      replacement="${source}.replacement"
      "$REAL_CP" -- "$source" "$replacement"
      chmod --reference="$source" "$replacement"
      "$REAL_MV" -fT -- "$replacement" "$source"
      : > "$RACE_MARKER"
      ;;
    verify-unavailable:*.arclith-new.*)
      "$REAL_MV" "$@"
      : > "$RACE_MARKER"
      exit 0
      ;;
  esac
fi
exec "$REAL_MV" "$@"
MOCK
chmod +x "$mock_bin/mv"

cat > "$mock_bin/sha256sum" <<'MOCK'
#!/usr/bin/env bash
path=${!#}
if [[ ${RACE_MODE:-none} == verify-unavailable && $path == "$RACE_TARGET" && -e $RACE_MARKER ]]; then
  exit 1
fi
exec "$REAL_SHA256SUM" "$@"
MOCK
chmod +x "$mock_bin/sha256sum"

status=0
output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" REAL_CP="$real_cp" \
  REAL_SHA256SUM="$real_sha256sum" RACE_MODE=changed RACE_TARGET="$target" \
  RACE_MARKER="$test_root/race-fired" HOME="$home" \
  "$fixture/arclith.sh" config apply kitty --yes 2>&1) || status=$?

[[ $status -eq 1 ]] || { printf 'not ok - raced staged replacement must fail (status=%s)\n' "$status" >&2; exit 1; }
[[ -e "$test_root/race-fired" ]] || { printf 'not ok - race injection did not run\n' >&2; exit 1; }
[[ $(<"$target") == 'bytes changed in the final check-to-rename window' ]] \
  || { printf 'not ok - fixture did not install the injected bytes\n' >&2; exit 1; }
[[ $output == *'post-rename integrity verification'* ]] \
  || { printf 'not ok - post-rename mismatch was not reported\n%s\n' "$output" >&2; exit 1; }
[[ $output == *'deployment rollback was incomplete'* && $output == *'preserving the target and recovery copies'* ]] \
  || { printf 'not ok - partial failure and preserved conflict were not reported\n%s\n' "$output" >&2; exit 1; }

backup=$(find "$home" -type f -name 'kitty.conf.arclith-backup.*' -print -quit)
[[ -n $backup && $(<"$backup") == 'original user configuration' ]] \
  || { printf 'not ok - original recovery backup was not retained\n' >&2; exit 1; }
journal=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -print -quit)
[[ -n $journal ]] && grep -q '^STATE|UNCERTAIN$' "$journal" \
  || { printf 'not ok - raced transaction was not recorded UNCERTAIN\n' >&2; exit 1; }
target_record="${journal%.v1}.targets/000000.v1"
grep -q '^STATE|UNCERTAIN$' "$target_record" \
  || { printf 'not ok - raced target was not recorded UNCERTAIN\n' >&2; exit 1; }
[[ ! -e "$home/.local/state/arclith/deployments.v1" ]] \
  || { printf 'not ok - failed raced deployment updated ownership state\n' >&2; exit 1; }

printf 'ok - staged-file race reproduced in isolated HOME\n'
printf 'ok - post-rename integrity mismatch failed the deployment\n'
printf 'ok - conflicting target was preserved and original backup retained\n'
printf 'ok - target and transaction journals report UNCERTAIN\n'
printf 'ok - deployment ownership manifest was not updated\n'

run_case() {
  local label=$1 mode=$2 action=$3 case_home="$test_root/$1-home" case_target="$test_root/$1-home/.config/kitty/kitty.conf"
  local case_status=0 case_output marker="$test_root/$1-fired"
  mkdir -p "$(dirname -- "$case_target")"
  if [[ $mode != inode && $action != apply-new ]]; then printf 'original user configuration\n' > "$case_target"; fi
  case_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" REAL_CP="$real_cp" \
    REAL_SHA256SUM="$real_sha256sum" RACE_MODE="$mode" RACE_TARGET="$case_target" \
    RACE_MARKER="$marker" HOME="$case_home" "$fixture/arclith.sh" config "$action" kitty --yes 2>&1) || case_status=$?

  case $label in
    inode)
      [[ $case_status -eq 1 && -e $marker && $case_output == *'post-rename integrity verification'* ]] \
        || { printf 'not ok - identical-byte inode replacement was not rejected\n%s\n' "$case_output" >&2; exit 1; }
      cmp -s "$fixture/core/configs/kitty/kitty.conf" "$case_target" \
        || { printf 'not ok - identical-byte inode case did not leave source bytes at target\n' >&2; exit 1; }
      ;;
    verify-unavailable)
      [[ $case_status -eq 1 && $case_output == *'post-rename integrity verification'* ]] \
        || { printf 'not ok - unavailable target verification did not fail closed\n%s\n' "$case_output" >&2; exit 1; }
      ;;
    success)
      [[ $case_status -eq 0 && -s $case_target && -f $case_home/.local/state/arclith/deployments.v1 ]] \
        || { printf 'not ok - normal apply-new deployment did not complete\n%s\n' "$case_output" >&2; exit 1; }
      cmp -s "$fixture/core/configs/kitty/kitty.conf" "$case_target" \
        || { printf 'not ok - normal apply-new target differs from bundled source\n' >&2; exit 1; }
      ;;
    *) printf 'not ok - unknown test case %s\n' "$label" >&2; exit 1 ;;
  esac

  if [[ $label == inode || $label == verify-unavailable ]]; then
    local case_journal
    case_journal=$(find "$case_home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -print -quit)
    [[ -n $case_journal ]] && grep -q '^STATE|UNCERTAIN$' "$case_journal" \
      || { printf 'not ok - %s did not retain UNCERTAIN transaction status\n' "$label" >&2; exit 1; }
    [[ ! -e $case_home/.local/state/arclith/deployments.v1 || $action == apply-new ]] \
      || { printf 'not ok - %s unexpectedly changed the ownership manifest\n' "$label" >&2; exit 1; }
  fi
  printf 'ok - %s staged replacement verification case\n' "$label"
}

run_case inode inode apply
run_case verify-unavailable verify-unavailable apply
run_case success none apply-new

# Restore uses a staged copy of a verified backup and must verify both the
# staged inode and expected backup hash before writing APPLIED.
restore_home="$test_root/restore-home"
restore_target="$restore_home/.config/kitty/kitty.conf"
mkdir -p "$(dirname -- "$restore_target")"
printf 'restore original user configuration\n' > "$restore_target"
HOME="$restore_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
restore_id=$(HOME="$restore_home" "$fixture/arclith.sh" config backups | awk '/available$/{print $1; exit}')
[[ $restore_id =~ ^[A-Za-z0-9]{8}$ ]] || { printf 'not ok - restore fixture did not record an available backup\n' >&2; exit 1; }
restore_state="$restore_home/.local/state/arclith/deployments.v1"
restore_state_before=$(sha256sum "$restore_state")
restore_status=0
restore_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" REAL_CP="$real_cp" \
  REAL_SHA256SUM="$real_sha256sum" RACE_MODE=restore-changed RACE_TARGET="$restore_target" \
  RACE_MARKER="$test_root/restore-fired" HOME="$restore_home" \
  "$fixture/arclith.sh" config restore "$restore_id" --yes 2>&1) || restore_status=$?
[[ $restore_status -eq 1 && $restore_output == *'post-rename integrity verification'* ]] \
  || { printf 'not ok - changed staged restore bytes were not rejected\n%s\n' "$restore_output" >&2; exit 1; }
[[ $(<"$restore_target") == 'bytes changed in the final check-to-rename window' ]] \
  || { printf 'not ok - restore conflict was not preserved at the target\n' >&2; exit 1; }
[[ $(sha256sum "$restore_state") == "$restore_state_before" ]] \
  || { printf 'not ok - failed restore changed deployment ownership state\n' >&2; exit 1; }
restore_journal=$(find "$restore_home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d ' ' -f 2-)
grep -q '^STATE|UNCERTAIN$' "$restore_journal" \
  || { printf 'not ok - changed restore did not retain UNCERTAIN status\n' >&2; exit 1; }
printf 'ok - changed staged restore bytes fail before APPLIED and preserve manifest state\n'

restore_inode_home="$test_root/restore-inode-home"
restore_inode_target="$restore_inode_home/.config/kitty/kitty.conf"
mkdir -p "$(dirname -- "$restore_inode_target")"
printf 'restore inode original configuration\n' > "$restore_inode_target"
HOME="$restore_inode_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
restore_inode_id=$(HOME="$restore_inode_home" "$fixture/arclith.sh" config backups | awk '/available$/{print $1; exit}')
restore_inode_state="$restore_inode_home/.local/state/arclith/deployments.v1"
restore_inode_state_before=$(sha256sum "$restore_inode_state")
restore_inode_status=0
restore_inode_output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" REAL_CP="$real_cp" \
  REAL_SHA256SUM="$real_sha256sum" RACE_MODE=restore-inode RACE_TARGET="$restore_inode_target" \
  RACE_MARKER="$test_root/restore-inode-fired" HOME="$restore_inode_home" \
  "$fixture/arclith.sh" config restore "$restore_inode_id" --yes 2>&1) || restore_inode_status=$?
[[ $restore_inode_status -eq 1 && $restore_inode_output == *'post-rename integrity verification'* ]] \
  || { printf 'not ok - identical-byte staged restore inode replacement was not rejected\n%s\n' "$restore_inode_output" >&2; exit 1; }
[[ $(sha256sum "$restore_inode_state") == "$restore_inode_state_before" ]] \
  || { printf 'not ok - inode-mismatched restore changed deployment ownership state\n' >&2; exit 1; }
restore_inode_journal=$(find "$restore_inode_home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d ' ' -f 2-)
grep -q '^STATE|UNCERTAIN$' "$restore_inode_journal" \
  || { printf 'not ok - inode-mismatched restore did not retain UNCERTAIN status\n' >&2; exit 1; }
printf 'ok - identical-byte staged restore inode replacement fails before APPLIED\n'
