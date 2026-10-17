#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-rollback-conflict-matrix.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

fixture="$test_root/project"
mock_bin="$test_root/mock-bin"
real_mv=$(command -v mv)
mkdir -p "$fixture" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$fixture/"

cat > "$mock_bin/mv" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source_path=${@: -2:1}
destination=${!#}
if [[ ${FAIL_UNCERTAIN_CHECKPOINT:-no} == yes \
  && $destination == */transactions/*.targets/000000.v1 \
  && -f $source_path && $(grep -c '^STATE|UNCERTAIN$' "$source_path" || true) -gt 0 ]]; then
  exit 74
fi
if [[ $destination == "$FAIL_STATE_TARGET" && ! -e $FAIL_STATE_MARKER ]]; then
  : > "$FAIL_STATE_MARKER"
  exit 73
fi

if [[ ${CONFLICT_MODE:-} == residual-race && $destination == "$CONFLICT_TARGET" \
  && $source_path == *.arclith-restore.* ]]; then
  printf 'edit injected after final verification\n' > "$CONFLICT_TARGET"
  : > "$RACE_MARKER"
fi

"$REAL_MV" "$@"
if [[ $destination == "$CONFLICT_TARGET" && ! -e ${CONFLICT_MARKER:-/dev/null} ]]; then
  before=$(stat -c '%d:%i' -- "$CONFLICT_TARGET")
  case ${CONFLICT_MODE:-none} in
    inplace) printf 'intervening in-place edit\n' > "$CONFLICT_TARGET" ;;
    changed-inode-same-content)
      sibling="$CONFLICT_TARGET.audit-replacement"
      cp -- "$CONFLICT_TARGET" "$sibling"
      "$REAL_MV" -T -- "$sibling" "$CONFLICT_TARGET"
      ;;
    changed-inode-content)
      sibling="$CONFLICT_TARGET.audit-replacement"
      printf 'replacement with different content\n' > "$sibling"
      "$REAL_MV" -T -- "$sibling" "$CONFLICT_TARGET"
      ;;
    missing) rm -f -- "$CONFLICT_TARGET" ;;
    symlink)
      rm -f -- "$CONFLICT_TARGET"
      ln -s -- "$CONFLICT_SENTINEL" "$CONFLICT_TARGET"
      ;;
    directory)
      rm -f -- "$CONFLICT_TARGET"
      mkdir -- "$CONFLICT_TARGET"
      ;;
  esac
  after=missing
  [[ ! -e $CONFLICT_TARGET && ! -L $CONFLICT_TARGET ]] || after=$(stat -c '%d:%i' -- "$CONFLICT_TARGET" 2>/dev/null || printf unsafe)
  printf '%s\n%s\n' "$before" "$after" > "$CONFLICT_MARKER"
fi
EOF
chmod +x "$mock_bin/mv"

latest_journal() {
  find "$1/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -print -quit
}
assert_uncertain() {
  local home=$1 journal id target_record
  journal=$(latest_journal "$home")
  id=${journal##*/}; id=${id%.v1}
  target_record="$home/.local/state/arclith/transactions/$id.targets/000000.v1"
  grep -q '^STATE|UNCERTAIN$' "$journal" && grep -q '^STATE|UNCERTAIN$' "$target_record"
}
assert_backup_retained() {
  local home=$1 expected=$2 backup
  backup=$(find "$home" -type f -name 'kitty.conf.arclith-backup.*' -print -quit)
  [[ -n $backup && $(<"$backup") == "$expected" ]]
}
run_apply_case() {
  local name=$1 mode=$2 original=$3 fail_uncertain=${4:-no}
  local home="$test_root/home-$name" target="$test_root/home-$name/.config/kitty/kitty.conf"
  local state_file="$test_root/home-$name/.local/state/arclith/deployments.v1"
  local status=0 output journal id target_record observed
  mkdir -p "$home/.config/kitty"
  if [[ $original != absent ]]; then printf '%s\n' "$original" > "$target"; fi
  output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" \
    FAIL_STATE_TARGET="$state_file" FAIL_STATE_MARKER="$test_root/$name-state-failure" \
    CONFLICT_MODE="$mode" CONFLICT_TARGET="$target" CONFLICT_MARKER="$test_root/$name-conflict" \
    CONFLICT_SENTINEL="$test_root/$name-sentinel" RACE_MARKER="$test_root/$name-race" \
    FAIL_UNCERTAIN_CHECKPOINT="$fail_uncertain" HOME="$home" \
    "$fixture/arclith.sh" config apply kitty --yes 2>&1) || status=$?
  [[ $status -eq 1 ]] || { printf 'not ok - %s apply failure returned status %s\n' "$name" "$status" >&2; exit 1; }
  journal=$(latest_journal "$home")
  id=${journal##*/}; id=${id%.v1}
  target_record="$home/.local/state/arclith/transactions/$id.targets/000000.v1"
  observed=missing
  [[ ! -e $target && ! -L $target ]] || observed=$(cat -- "$target" 2>/dev/null || printf 'non-regular')

  if [[ $mode == none || $mode == residual-race ]]; then
    grep -q '^STATE|ROLLED_BACK$' "$journal" \
      || { printf 'not ok - %s normal rollback did not reach ROLLED_BACK\n' "$name" >&2; exit 1; }
    [[ $observed == "$original" ]] \
      || { printf 'not ok - %s normal rollback did not restore original content\n' "$name" >&2; exit 1; }
    if [[ $mode == residual-race ]]; then
      [[ -e $test_root/$name-race && $observed == "$original" ]] \
        || { printf 'not ok - residual race injection did not occur\n' >&2; exit 1; }
      printf 'ok - injected write after the final check was overwritten; this test documents the remaining race\n'
    else
      grep -q '^STATE|ROLLED_BACK$' "$target_record" || exit 1
      printf 'ok - normal rollback with no intervening target change completes\n'
    fi
    assert_backup_retained "$home" "$original" || { printf 'not ok - original backup was not retained\n' >&2; exit 1; }
    return
  fi

  grep -q '^STATE|UNCERTAIN$' "$journal" \
    || { printf 'not ok - %s transaction is not UNCERTAIN\n' "$name" >&2; exit 1; }
  if [[ $fail_uncertain == yes ]]; then
    grep -q '^STATE|ROLLBACK_INTENT$' "$target_record" \
      || { printf 'not ok - failed uncertain checkpoint did not retain the last persisted target state\n' >&2; exit 1; }
    [[ $output == *'target checkpoint could not be recorded'* ]] \
      || { printf 'not ok - uncertain checkpoint persistence failure was not reported\n' >&2; exit 1; }
    printf 'ok - failed uncertain target checkpoint leaves transaction uncertain and preserves target\n'
  else
    grep -q '^STATE|UNCERTAIN$' "$target_record" \
      || { printf 'not ok - %s target is not UNCERTAIN\n' "$name" >&2; exit 1; }
    case $mode in
      inplace) [[ $observed == 'intervening in-place edit' ]] || exit 1 ;;
      changed-inode-same-content)
        mapfile -t inode_values < "$test_root/$name-conflict"
        cmp -s -- "$target" "$fixture/core/configs/kitty/kitty.conf" \
          && [[ ${inode_values[0]} != "${inode_values[1]}" ]] \
          || { printf 'not ok - changed inode with matching content was not preserved (observed: %q)\n' "$observed" >&2; exit 1; }
        ;;
      changed-inode-content) [[ $observed == 'replacement with different content' ]] || exit 1 ;;
      missing) [[ ! -e $target && ! -L $target ]] || exit 1 ;;
      symlink) [[ -L $target && $(readlink -- "$target") == "$test_root/$name-sentinel" ]] || exit 1 ;;
      directory) [[ -d $target && ! -L $target ]] || exit 1 ;;
    esac
    printf 'ok - %s conflict remains at its current path and is UNCERTAIN\n' "$name"
  fi
  if [[ $original != absent ]]; then
    assert_backup_retained "$home" "$original" || { printf 'not ok - %s original backup was not retained\n' "$name" >&2; exit 1; }
  fi
}

run_restore_case() {
  local name=$1 mode=$2 home="$test_root/restore-home-$1" target=""
  local state_file journal id target_record selected_id selected_backup original status=0 output observed
  target="$home/.config/kitty/kitty.conf"
  mkdir -p "$home/.config/kitty"
  printf '%s\n' 'restore original fixture content' > "$target"
  HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
  selected_id=$(HOME="$home" "$fixture/arclith.sh" config backups | awk '/available$/{print $1; exit}')
  [[ $selected_id =~ ^[A-Za-z0-9]{8}$ ]] || { printf 'not ok - %s restore backup missing\n' "$name" >&2; exit 1; }
  selected_backup=$(find "$home" -type f -name "kitty.conf.arclith-backup.$selected_id" -print -quit)
  [[ -n $selected_backup ]] || { printf 'not ok - %s selected restore backup file missing\n' "$name" >&2; exit 1; }
  original=$(cat -- "$target")
  state_file="$home/.local/state/arclith/deployments.v1"
  output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" \
    FAIL_STATE_TARGET="$state_file" FAIL_STATE_MARKER="$test_root/$name-state-failure" \
    CONFLICT_MODE="$mode" CONFLICT_TARGET="$target" CONFLICT_MARKER="$test_root/$name-conflict" \
    CONFLICT_SENTINEL="$test_root/$name-sentinel" RACE_MARKER="$test_root/$name-race" \
    HOME="$home" "$fixture/arclith.sh" config restore "$selected_id" --yes 2>&1) || status=$?
  [[ $status -eq 1 ]] || { printf 'not ok - %s restore returned status %s\n' "$name" "$status" >&2; exit 1; }
  journal=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d ' ' -f 2-)
  id=${journal##*/}; id=${id%.v1}
  target_record="$home/.local/state/arclith/transactions/$id.targets/000000.v2"
  observed=missing
  [[ ! -e $target && ! -L $target ]] || observed=$(cat -- "$target" 2>/dev/null || printf 'non-regular')

  if [[ $mode == none ]]; then
    grep -q '^STATE|ROLLED_BACK$' "$journal" \
      && grep -q '^STATE|ROLLED_BACK$' "$target_record" \
      && [[ $observed == "$original" ]] \
      || { printf 'not ok - %s normal restore rollback failed\n' "$name" >&2; exit 1; }
    printf 'ok - normal restore rollback with no intervening change completes\n'
  else
    grep -q '^STATE|UNCERTAIN$' "$journal" \
      && grep -q '^STATE|UNCERTAIN$' "$target_record" \
      || { printf 'not ok - %s restore conflict was not marked UNCERTAIN\n' "$name" >&2; exit 1; }
    case $mode in
      inplace) [[ $observed == 'intervening in-place edit' ]] || exit 1 ;;
      changed-inode-same-content)
        mapfile -t inode_values < "$test_root/$name-conflict"
        cmp -s -- "$target" "$selected_backup" \
          && [[ ${inode_values[0]} != "${inode_values[1]}" ]] \
          || { printf 'not ok - %s changed inode was not preserved\n' "$name" >&2; exit 1; }
        ;;
      changed-inode-content) [[ $observed == 'replacement with different content' ]] || exit 1 ;;
      missing) [[ ! -e $target && ! -L $target ]] || exit 1 ;;
      symlink) [[ -L $target && $(readlink -- "$target") == "$test_root/$name-sentinel" ]] || exit 1 ;;
      directory) [[ -d $target && ! -L $target ]] || exit 1 ;;
    esac
    [[ -n $(find "$home" -type f -name 'kitty.conf.arclith-backup.*' -print -quit) ]] \
      || { printf 'not ok - %s restore recovery backup was not retained\n' "$name" >&2; exit 1; }
    printf 'ok - %s restore conflict remains at its current path with backups retained and UNCERTAIN state\n' "$name"
  fi
}

run_apply_case apply-in-place inplace 'apply original'
run_apply_case apply-new-inode-same changed-inode-same-content 'apply original'
run_apply_case apply-new-inode-content changed-inode-content 'apply original'
run_apply_case apply-missing missing 'apply original'
run_apply_case apply-symlink symlink 'apply original'
run_apply_case apply-directory directory 'apply original'
run_apply_case apply-absent-in-place inplace absent
run_apply_case apply-uncertain-write inplace 'apply original' yes
run_apply_case apply-normal none 'apply original'
run_apply_case apply-residual-race residual-race 'apply original'
run_restore_case restore-in-place inplace
run_restore_case restore-new-inode-same changed-inode-same-content
run_restore_case restore-new-inode-content changed-inode-content
run_restore_case restore-missing missing
run_restore_case restore-symlink symlink
run_restore_case restore-directory directory
run_restore_case restore-normal none

printf 'Rollback conflict matrix tests passed. All files were isolated under %s.\n' "$test_root"
