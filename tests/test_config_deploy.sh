#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-deploy-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
home="$test_root/home"
mock_bin="$test_root/mock-bin"
real_mv=$(command -v mv)
state_file="$home/.local/state/arclith/deployments.v1"
mkdir -p "$fixture" "$home" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$fixture/"
cat > "$mock_bin/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MV_TARGET" && ! -e $FAIL_MV_MARKER ]]; then
  if [[ ${FAIL_MV_BEFORE:-0} == 1 ]]; then
    : > "$FAIL_MV_MARKER"
    exit 1
  fi
  "$REAL_MV" "$@"
  : > "$FAIL_MV_MARKER"
  exit 1
fi
exec "$REAL_MV" "$@"
EOF
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

source_file="$fixture/core/configs/kitty/kitty.conf"
target="$home/.config/kitty/kitty.conf"
mkdir -p "$(dirname -- "$target")"
printf 'unrelated user data\n' > "$home/.config/kitty/keep.txt"
before_preview=$(find "$fixture/core/configs" "$home" -type f -print0 | sort -z | xargs -0 sha256sum)
contains 'missing state is treated as empty' 'No tracked backups' "$(HOME="$home" "$fixture/arclith.sh" config backups)"
contains 'update check handles a fresh home without managed files' 'No managed configuration files to check.' "$(HOME="$home" "$fixture/arclith.sh" config updates)"
preview=$(HOME="$home" "$fixture/arclith.sh" config preview kitty)
contains 'preview describes the new Kitty target' NEW "$preview"
after_preview=$(find "$fixture/core/configs" "$home" -type f -print0 | sort -z | xargs -0 sha256sum)
assert 'preview remains read-only' test "$before_preview" = "$after_preview"

if PATH="$mock_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_TARGET="$state_file" FAIL_MV_MARKER="$test_root/initial-state-failed-once" FAIL_MV_BEFORE=1 \
  HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/initial-state-failure.out" 2>&1; then
  printf 'not ok - failed initial state write should fail apply\n' >&2; exit 1
fi
contains 'initial state write failure is reported' 'state could not be saved' "$(<"$test_root/initial-state-failure.out")"
assert 'initial state write failure removes newly installed target' test ! -e "$target"
assert 'initial state write failure leaves no manifest' test ! -e "$state_file"

apply_output=$(HOME="$home" "$fixture/arclith.sh" config apply kitty --yes)
contains 'new config file is applied' 'Success: configuration component kitty applied' "$apply_output"
assert 'installed file matches bundled source' cmp -s "$source_file" "$target"
assert 'new config file has restrictive permissions' test "$(stat -c '%a' "$target")" = 600
assert 'unrelated file is preserved' test "$(cat "$home/.config/kitty/keep.txt")" = 'unrelated user data'
assert 'state directory is owner-only' test "$(stat -c '%a' "$home/.local/state/arclith")" = 700
assert 'state manifest is owner-only' test "$(stat -c '%a' "$state_file")" = 600
contains 'state manifest has version header' 'ARCLITH_STATE|1' "$(head -n 1 "$state_file")"
contains 'new deployment is tracked as unchanged' 'kitty  .config/kitty/kitty.conf  unchanged' "$(HOME="$home" "$fixture/arclith.sh" config status)"
contains 'unchanged bundled source is reported current' 'CURRENT  kitty  .config/kitty/kitty.conf' "$(HOME="$home" "$fixture/arclith.sh" config updates kitty)"

source_original="$test_root/kitty.original"
cp "$source_file" "$source_original"
target_before=$(sha256sum "$target")
state_before=$(sha256sum "$state_file")
printf '\n# updated bundled defaults\n' >> "$source_file"
source_changed=$(sha256sum "$source_file")
updates_output=$(HOME="$home" "$fixture/arclith.sh" config updates kitty)
contains 'bundled source changes are identified' 'UPDATE AVAILABLE  kitty' "$updates_output"
contains 'update command explains explicit apply path' 'config apply kitty' "$updates_output"
assert 'source comparison preserves deployed target' test "$target_before" = "$(sha256sum "$target")"
assert 'source comparison preserves deployment state' test "$state_before" = "$(sha256sum "$state_file")"
assert 'source comparison does not modify bundled files' test "$source_changed" = "$(sha256sum "$source_file")"
contains 'update detection leaves deployment status compatible' 'kitty  .config/kitty/kitty.conf  unchanged' "$(HOME="$home" "$fixture/arclith.sh" config status kitty)"

printf 'local kitty edit\n' > "$target"
local_update_output=$(HOME="$home" "$fixture/arclith.sh" config updates kitty)
contains 'local edits are reported as warnings' 'WARN LOCAL MODIFICATION  kitty' "$local_update_output"
assert 'local edit is preserved by update check' test "$(cat "$target")" = 'local kitty edit'
cp "$source_original" "$source_file"
cp "$source_original" "$target"
unavailable_source="$fixture/core/configs/kitty"
mv "$unavailable_source" "$test_root/kitty.source.saved"
unavailable_output=$(HOME="$home" "$fixture/arclith.sh" config updates kitty)
contains 'unavailable optional source is a warning' 'WARN SOURCE UNAVAILABLE  kitty' "$unavailable_output"
mv "$test_root/kitty.source.saved" "$unavailable_source"
printf '\0binary' > "$source_file"
if HOME="$home" "$fixture/arclith.sh" config updates kitty >"$test_root/updates-invalid-source.out" 2>&1; then
  printf 'not ok - invalid bundled source should fail update check\n' >&2; exit 1
else status=$?; fi
assert 'invalid bundled source returns failure status' test "$status" -eq 1
contains 'invalid bundled source is explained' 'FAIL SOURCE INVALID  kitty' "$(<"$test_root/updates-invalid-source.out")"
cp "$source_original" "$source_file"

if HOME="$home" "$fixture/arclith.sh" config updates not-a-component >"$test_root/updates-invalid.out" 2>&1; then
  printf 'not ok - invalid update component should fail\n' >&2; exit 1
else status=$?; fi
assert 'invalid update component returns usage status' test "$status" -eq 2
contains 'invalid update component is explained' 'Unknown configuration component' "$(<"$test_root/updates-invalid.out")"
if HOME="$home" "$fixture/arclith.sh" config updates kitty extra >"$test_root/updates-usage.out" 2>&1; then
  printf 'not ok - invalid update arguments should fail\n' >&2; exit 1
else status=$?; fi
assert 'invalid update argument count returns usage status' test "$status" -eq 2
mv "$target" "$test_root/target.saved"
ln -s "$test_root/elsewhere" "$target"
if HOME="$home" "$fixture/arclith.sh" config updates kitty >"$test_root/updates-unsafe.out" 2>&1; then
  printf 'not ok - unsafe update target should fail\n' >&2; exit 1
else status=$?; fi
assert 'unsafe target returns failure status' test "$status" -eq 1
contains 'unsafe target is classified as failure' 'FAIL UNSAFE TARGET  kitty' "$(<"$test_root/updates-unsafe.out")"
rm "$target"
mv "$test_root/target.saved" "$target"

printf 'user kitty settings\n' > "$target"
chmod 640 "$target"
if HOME="$home" "$fixture/arclith.sh" config apply kitty </dev/null >"$test_root/refused.out" 2>&1; then
  printf 'not ok - overwrite without confirmation should fail\n' >&2; exit 1
fi
contains 'overwrite refusal is reported' 'Skipped: no files were changed' "$(<"$test_root/refused.out")"
assert 'refused overwrite preserves target' test "$(cat "$target")" = 'user kitty settings'
assert 'refused overwrite creates no backup' bash -c '[[ -z $(find "$1" -name "*.arclith-backup.*" -print -quit) ]]' _ "$home"

printf 'y\n' | HOME="$home" "$fixture/arclith.sh" config apply kitty >"$test_root/confirmed.out" 2>&1
backup=$(find "$home" -name 'kitty.conf.arclith-backup.*' -type f -print -quit)
backup_id=${backup##*.arclith-backup.}
assert 'confirmed overwrite creates a backup' test -n "$backup"
assert 'backup preserves previous content' test "$(cat "$backup")" = 'user kitty settings'
assert 'backup permissions are restrictive' test "$(stat -c '%a' "$backup")" = 600
assert 'confirmed overwrite installs source' cmp -s "$source_file" "$target"
assert 'confirmed overwrite still preserves unrelated file' test "$(cat "$home/.config/kitty/keep.txt")" = 'unrelated user data'
contains 'backup listing trusts and verifies the backup' "$backup_id  kitty  .config/kitty/kitty.conf  available" "$(HOME="$home" "$fixture/arclith.sh" config backups)"

printf 'user edit after deployment\n' > "$target"
contains 'modified deployed files are detected' 'kitty  .config/kitty/kitty.conf  modified' "$(HOME="$home" "$fixture/arclith.sh" config status kitty)"
if HOME="$home" "$fixture/arclith.sh" config restore "$backup_id" </dev/null >"$test_root/restore-refused.out" 2>&1; then
  printf 'not ok - restore overwrite without confirmation should fail\n' >&2; exit 1
fi
contains 'restore previews the selected backup' "backup: $backup_id" "$(<"$test_root/restore-refused.out")"
assert 'refused restore preserves the modified file' test "$(cat "$target")" = 'user edit after deployment'
printf 'y\n' | HOME="$home" "$fixture/arclith.sh" config restore "$backup_id" >"$test_root/restore.out" 2>&1
contains 'selected backup is restored' "Success: backup $backup_id restored" "$(<"$test_root/restore.out")"
assert 'restore preserves the replaced target as a backup' test "$(cat "$(find "$home" -name 'kitty.conf.arclith-backup.*' -type f -print | while IFS= read -r p; do [[ $p != "$backup" ]] && { printf '%s\n' "$p"; break; }; done)")" = 'user edit after deployment'
assert 'restore updates managed hash state' test "$(HOME="$home" "$fixture/arclith.sh" config status kitty | tail -n 1)" = 'kitty  .config/kitty/kitty.conf  unchanged'
contains 'both recovery points are listed' 'available' "$(HOME="$home" "$fixture/arclith.sh" config backups)"

# A path-like identifier is never interpreted as a path.
if HOME="$home" "$fixture/arclith.sh" config restore '../../etc/passwd' --yes >"$test_root/path-id.out" 2>&1; then
  printf 'not ok - path traversal backup id should fail\n' >&2; exit 1
fi
contains 'path-like backup identifiers are rejected' '8-character Arclith ID' "$(<"$test_root/path-id.out")"

# Corrupt state is rejected instead of being used to locate a backup.
cp "$state_file" "$test_root/state.good"
printf 'ARCLITH_STATE|999\n' > "$state_file"
if HOME="$home" "$fixture/arclith.sh" config backups >"$test_root/corrupt-state.out" 2>&1; then
  printf 'not ok - unsupported state version should fail\n' >&2; exit 1
fi
contains 'corrupt state is rejected' 'Unsupported deployment state manifest version' "$(<"$test_root/corrupt-state.out")"
if HOME="$home" "$fixture/arclith.sh" config updates kitty >"$test_root/updates-corrupt-state.out" 2>&1; then
  printf 'not ok - updates should reject unsupported state version\n' >&2; exit 1
else status=$?; fi
assert 'update check rejects corrupt deployment state' test "$status" -eq 1
contains 'update state error is explained' 'Unsupported deployment state manifest version' "$(<"$test_root/updates-corrupt-state.out")"
cp "$test_root/state.good" "$state_file"
chmod 600 "$state_file"

# State symlinks and unsafe serialized targets are rejected.
mv "$state_file" "$test_root/state.saved"
ln -s "$test_root/state.saved" "$state_file"
if HOME="$home" "$fixture/arclith.sh" config backups >"$test_root/state-link.out" 2>&1; then
  printf 'not ok - symlinked state manifest should fail\n' >&2; exit 1
fi
contains 'symlinked state manifest is rejected' 'Unsafe deployment state manifest' "$(<"$test_root/state-link.out")"
rm "$state_file"
cp "$test_root/state.saved" "$state_file"
chmod 600 "$state_file"
mv "$state_file" "$test_root/state.saved"
ln -s "$test_root/missing-state-target" "$state_file"
if HOME="$home" "$fixture/arclith.sh" config backups >"$test_root/state-dangling-link.out" 2>&1; then
  printf 'not ok - dangling state manifest symlink should fail\n' >&2; exit 1
fi
contains 'dangling state manifest symlink is rejected' 'Unsafe deployment state manifest' "$(<"$test_root/state-dangling-link.out")"
rm "$state_file"
cp "$test_root/state.saved" "$state_file"
chmod 600 "$state_file"
cp "$state_file" "$test_root/state.good"
sed 's|^M|M|; s|\.config/kitty/kitty.conf|../outside|' "$state_file" > "$test_root/state.bad-path"
mv "$test_root/state.bad-path" "$state_file"
chmod 600 "$state_file"
if HOME="$home" "$fixture/arclith.sh" config backups >"$test_root/state-path.out" 2>&1; then
  printf 'not ok - unsafe state target should fail\n' >&2; exit 1
fi
contains 'unsafe target in state is rejected' 'invalid managed-file record' "$(<"$test_root/state-path.out")"
cp "$test_root/state.good" "$state_file"
chmod 600 "$state_file"

# A backup path that has been replaced by a symlink is not trusted.
cp "$backup" "$test_root/backup.good"
printf 'outside data\n' > "$test_root/backup-outside"
rm -f -- "$backup"
ln -s "$test_root/backup-outside" "$backup"
contains 'symlinked backup is reported unsafe' "$backup_id  kitty  .config/kitty/kitty.conf  unsafe" "$(HOME="$home" "$fixture/arclith.sh" config backups)"
if HOME="$home" "$fixture/arclith.sh" config restore "$backup_id" --yes >"$test_root/backup-link.out" 2>&1; then
  printf 'not ok - symlinked backup should fail\n' >&2; exit 1
fi
contains 'symlinked backup is refused' 'Backup cannot be restored' "$(<"$test_root/backup-link.out")"
rm "$backup"
cp "$test_root/backup.good" "$backup"
chmod 600 "$backup"
cp "$backup" "$test_root/backup.intact"
printf 'tampered backup\n' > "$backup"
contains 'modified backup is reported invalid' "$backup_id  kitty  .config/kitty/kitty.conf  invalid" "$(HOME="$home" "$fixture/arclith.sh" config backups)"
if HOME="$home" "$fixture/arclith.sh" config restore "$backup_id" --yes >"$test_root/backup-invalid.out" 2>&1; then
  printf 'not ok - hash-mismatched backup should fail\n' >&2; exit 1
fi
contains 'hash-mismatched backup is refused' 'Backup cannot be restored' "$(<"$test_root/backup-invalid.out")"
cp "$test_root/backup.intact" "$backup"
chmod 600 "$backup"

# A restore that reports failure after replacing the target restores the
# pre-restore file and leaves the tracked state unchanged.
printf 'restore rollback sentinel\n' > "$target"
chmod 640 "$target"
state_hash_before=$(sha256sum "$state_file")
if PATH="$mock_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_TARGET="$target" FAIL_MV_MARKER="$test_root/restore-mv-failed-once" \
  HOME="$home" "$fixture/arclith.sh" config restore "$backup_id" --yes >"$test_root/restore-rollback.out" 2>&1; then
  printf 'not ok - simulated restore failure should fail\n' >&2; exit 1
fi
contains 'restore failure attempts rollback' 'Rollback restored the prior target' "$(<"$test_root/restore-rollback.out")"
assert 'restore rollback preserves current target' test "$(cat "$target")" = 'restore rollback sentinel'
assert 'restore rollback preserves state manifest' test "$(sha256sum "$state_file")" = "$state_hash_before"

# State commits that report a post-rename failure restore both the previous
# manifest and the just-replaced target.
printf 'state rollback sentinel\n' > "$target"
chmod 640 "$target"
state_hash_before=$(sha256sum "$state_file")
if PATH="$mock_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_TARGET="$state_file" FAIL_MV_MARKER="$test_root/state-mv-failed-once" \
  HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/state-rollback.out" 2>&1; then
  printf 'not ok - simulated state commit failure should fail apply\n' >&2; exit 1
fi
contains 'state commit failure triggers deployment rollback' 'Restored: .config/kitty/kitty.conf' "$(<"$test_root/state-rollback.out")"
assert 'state commit failure restores target contents' test "$(cat "$target")" = 'state rollback sentinel'
assert 'state commit failure preserves previous manifest' test "$(sha256sum "$state_file")" = "$state_hash_before"

# Missing backups remain visible as unavailable and cannot be restored.
rm -f -- "$backup"
contains 'missing backup is reported' "$backup_id  kitty  .config/kitty/kitty.conf  missing-or-unsafe" "$(HOME="$home" "$fixture/arclith.sh" config backups)"
if HOME="$home" "$fixture/arclith.sh" config restore "$backup_id" --yes >"$test_root/missing-backup.out" 2>&1; then
  printf 'not ok - missing backup should fail\n' >&2; exit 1
fi
contains 'missing backup is refused' 'Backup cannot be restored' "$(<"$test_root/missing-backup.out")"

# Simulate a rename that completes but reports failure; the engine must restore
# the prior file from its backup.
printf 'rollback sentinel\n' > "$target"
chmod 640 "$target"
if PATH="$mock_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_TARGET="$target" FAIL_MV_MARKER="$test_root/mv-failed-once" \
  HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/rollback.out" 2>&1; then
  printf 'not ok - simulated deployment failure should fail\n' >&2; exit 1
fi
contains 'rollback is reported' 'Restored: .config/kitty/kitty.conf' "$(<"$test_root/rollback.out")"
assert 'rollback restores original target content' test "$(cat "$target")" = 'rollback sentinel'
assert 'rollback restores original target mode' test "$(stat -c '%a' "$target")" = 640
assert 'rollback retains a recoverable backup' test -n "$(find "$home" -name 'kitty.conf.arclith-backup.*' -type f -print -quit)"

rm -rf "$fixture/core/configs/kitty"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/missing.out" 2>&1; then
  printf 'not ok - missing source should fail\n' >&2; exit 1
fi
contains 'missing source is rejected' 'source status is unavailable' "$(<"$test_root/missing.out")"

mkdir -p "$fixture/core/configs/kitty"
printf 'unsafe source\n' > "$test_root/outside.conf"
ln -s "$test_root/outside.conf" "$fixture/core/configs/kitty/kitty.conf"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/source-link.out" 2>&1; then
  printf 'not ok - symlinked source should fail\n' >&2; exit 1
fi
contains 'symlinked source is rejected' 'source status is unsafe-entry' "$(<"$test_root/source-link.out")"

rm "$fixture/core/configs/kitty/kitty.conf"
: > "$fixture/core/configs/kitty/kitty.conf"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/empty.out" 2>&1; then
  printf 'not ok - empty source should fail\n' >&2; exit 1
fi
contains 'empty source file is rejected' 'must be non-empty text' "$(<"$test_root/empty.out")"

printf 'invalid\0binary\n' > "$fixture/core/configs/kitty/kitty.conf"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/binary.out" 2>&1; then
  printf 'not ok - binary source should fail\n' >&2; exit 1
fi
contains 'binary source file is rejected' 'must be non-empty text' "$(<"$test_root/binary.out")"

printf 'safe source\n' > "$fixture/core/configs/kitty/kitty.conf"
rm -rf "$home/.config/kitty"
mkdir -p "$target"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/target-directory.out" 2>&1; then
  printf 'not ok - directory at file target should fail\n' >&2; exit 1
fi
contains 'directory at file target is rejected' 'not a regular file' "$(<"$test_root/target-directory.out")"
rm -rf "$home/.config/kitty"
ln -s "$test_root" "$home/.config/kitty"
if HOME="$home" "$fixture/arclith.sh" config apply kitty --yes >"$test_root/target-link.out" 2>&1; then
  printf 'not ok - symlink target parent should fail\n' >&2; exit 1
fi
contains 'symlinked target parent is rejected' 'Unsafe target parent contains a symlink' "$(<"$test_root/target-link.out")"

# Uninstall scenarios use isolated fixture homes. The actual user's HOME is never used.
uninstall_home="$test_root/uninstall-home"
uninstall_target="$uninstall_home/.config/kitty/kitty.conf"
mkdir -p "$uninstall_home/.config/kitty"
printf 'preexisting user config\n' > "$uninstall_target"
printf 'keep this unrelated file\n' > "$uninstall_home/.config/kitty/keep.txt"
HOME="$uninstall_home" "$fixture/arclith.sh" config apply kitty --yes > "$test_root/uninstall-apply.out"
old_uninstall_backup=$(find "$uninstall_home" -name 'kitty.conf.arclith-backup.*' -type f -print -quit)
old_uninstall_backup_id=${old_uninstall_backup##*.arclith-backup.}
uninstall_state="$uninstall_home/.local/state/arclith/deployments.v1"
uninstall_before=$(sha256sum "$uninstall_target" "$uninstall_state")
dry_run=$(HOME="$uninstall_home" "$fixture/arclith.sh" config uninstall kitty --dry-run)
contains 'uninstall dry-run lists verified removal' 'REMOVE' "$dry_run"
contains 'uninstall dry-run does not modify targets or state' 'Dry run complete' "$dry_run"
assert 'uninstall dry-run preserves target and state' test "$(sha256sum "$uninstall_target" "$uninstall_state")" = "$uninstall_before"
assert 'uninstall dry-run creates no backup' test "$(find "$uninstall_home" -name 'kitty.conf.arclith-backup.*' -type f | wc -l)" -eq 1
HOME="$uninstall_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall.out"
contains 'verified managed file is removed' 'Removed: .config/kitty/kitty.conf' "$(<"$test_root/uninstall.out")"
assert 'uninstall removes unchanged managed target' test ! -e "$uninstall_target"
assert 'uninstall preserves unrelated user file' test "$(cat "$uninstall_home/.config/kitty/keep.txt")" = 'keep this unrelated file'
assert 'uninstall preserves preexisting backup' test -f "$old_uninstall_backup"
assert 'uninstall retains new tracked recovery backup' test "$(find "$uninstall_home" -name 'kitty.conf.arclith-backup.*' -type f | wc -l)" -eq 2
contains 'uninstall recovery backup is available' 'available' "$(HOME="$uninstall_home" "$fixture/arclith.sh" config backups kitty)"
assert 'uninstall clears the removed ownership record' test "$(HOME="$uninstall_home" "$fixture/arclith.sh" config status kitty | tail -n 1)" = 'No managed configuration files.'
HOME="$uninstall_home" "$fixture/arclith.sh" config restore "$old_uninstall_backup_id" --yes > "$test_root/uninstall-original-restore.out"
assert 'uninstall preserves and restores pre-deployment user content' test "$(cat "$uninstall_target")" = 'preexisting user config'
uninstall_recovery_backup=$(find "$uninstall_home" -name 'kitty.conf.arclith-backup.*' -type f -print | while IFS= read -r candidate; do cmp -s "$candidate" "$fixture/core/configs/kitty/kitty.conf" && { printf '%s\n' "$candidate"; break; }; done)
uninstall_recovery_id=${uninstall_recovery_backup##*.arclith-backup.}
HOME="$uninstall_home" "$fixture/arclith.sh" config restore "$uninstall_recovery_id" --yes > "$test_root/uninstall-recovery-restore.out"
assert 'uninstall recovery backup restores removed file' cmp -s "$uninstall_target" "$fixture/core/configs/kitty/kitty.conf"
HOME="$uninstall_home" "$fixture/arclith.sh" config restore "$uninstall_recovery_id" --yes > "$test_root/repeated-restore.out"
assert 'repeated restore remains safe and idempotent' cmp -s "$uninstall_target" "$fixture/core/configs/kitty/kitty.conf"

modified_home="$test_root/uninstall-modified-home"
mkdir -p "$modified_home"
HOME="$modified_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
modified_target="$modified_home/.config/kitty/kitty.conf"
printf 'user edit must survive\n' > "$modified_target"
if HOME="$modified_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-modified.out" 2>&1; then
  printf 'not ok - modified managed file should not be uninstalled\n' >&2; exit 1
fi
contains 'modified file is reported and preserved' 'PRESERVE' "$(<"$test_root/uninstall-modified.out")"
assert 'modified file contents are preserved' test "$(cat "$modified_target")" = 'user edit must survive'
contains 'modified file remains tracked' 'modified' "$(HOME="$modified_home" "$fixture/arclith.sh" config status kitty)"

missing_home="$test_root/uninstall-missing-home"
mkdir -p "$missing_home"
HOME="$missing_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
missing_target="$missing_home/.config/kitty/kitty.conf"
rm "$missing_target"
contains 'already missing target is reported' 'ALREADY MISSING' "$(HOME="$missing_home" "$fixture/arclith.sh" config uninstall kitty --yes)"
assert 'already missing target ownership record is cleared' test "$(HOME="$missing_home" "$fixture/arclith.sh" config status kitty | tail -n 1)" = 'No managed configuration files.'

unowned_home="$test_root/uninstall-unowned-home"
mkdir -p "$unowned_home/.config/kitty"
printf 'manual file\n' > "$unowned_home/.config/kitty/kitty.conf"
if HOME="$unowned_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-unowned.out" 2>&1; then
  printf 'not ok - file without ownership state should not be uninstalled\n' >&2; exit 1
fi
contains 'missing ownership state is refused' 'no trusted deployment state' "$(<"$test_root/uninstall-unowned.out")"
assert 'unowned file is preserved' test -f "$unowned_home/.config/kitty/kitty.conf"

invalid_home="$test_root/uninstall-invalid-home"
mkdir -p "$invalid_home"
HOME="$invalid_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
invalid_state="$invalid_home/.local/state/arclith/deployments.v1"
sed 's/[0-9a-f]\{64\}$/notahash/' "$invalid_state" > "$test_root/uninstall-invalid-state"
mv "$test_root/uninstall-invalid-state" "$invalid_state"
chmod 600 "$invalid_state"
if HOME="$invalid_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-invalid.out" 2>&1; then
  printf 'not ok - invalid recorded hash should not authorize removal\n' >&2; exit 1
fi
contains 'invalid ownership hash is rejected' 'invalid managed-file record' "$(<"$test_root/uninstall-invalid.out")"
assert 'invalid state leaves target intact' test -f "$invalid_home/.config/kitty/kitty.conf"

missing_hash_home="$test_root/uninstall-missing-hash-home"
mkdir -p "$missing_hash_home"
HOME="$missing_hash_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
missing_hash_state="$missing_hash_home/.local/state/arclith/deployments.v1"
sed 's/|[0-9a-f]\{64\}$//' "$missing_hash_state" > "$test_root/uninstall-missing-hash-state"
mv "$test_root/uninstall-missing-hash-state" "$missing_hash_state"
chmod 600 "$missing_hash_state"
if HOME="$missing_hash_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-missing-hash.out" 2>&1; then
  printf 'not ok - missing recorded hash should not authorize removal\n' >&2; exit 1
fi
contains 'missing ownership hash is rejected' 'malformed managed-file record' "$(<"$test_root/uninstall-missing-hash.out")"
assert 'missing recorded hash leaves target intact' test -f "$missing_hash_home/.config/kitty/kitty.conf"

traversal_home="$test_root/uninstall-traversal-home"
mkdir -p "$traversal_home"
HOME="$traversal_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
traversal_state="$traversal_home/.local/state/arclith/deployments.v1"
sed 's|.config/kitty/kitty.conf|../outside|' "$traversal_state" > "$test_root/uninstall-traversal-state"
mv "$test_root/uninstall-traversal-state" "$traversal_state"
chmod 600 "$traversal_state"
if HOME="$traversal_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-traversal.out" 2>&1; then
  printf 'not ok - traversal path should not authorize removal\n' >&2; exit 1
fi
contains 'traversal target in state is rejected' 'invalid managed-file record' "$(<"$test_root/uninstall-traversal.out")"
assert 'traversal state leaves original target intact' test -f "$traversal_home/.config/kitty/kitty.conf"

symlink_home="$test_root/uninstall-symlink-home"
mkdir -p "$symlink_home"
HOME="$symlink_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
symlink_outside="$test_root/uninstall-outside"
printf 'outside file\n' > "$symlink_outside"
rm -rf "$symlink_home/.config/kitty"
ln -s "$test_root" "$symlink_home/.config/kitty"
if HOME="$symlink_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-symlink.out" 2>&1; then
  printf 'not ok - symlinked target parent should not be uninstalled\n' >&2; exit 1
fi
contains 'symlinked target parent is refused' 'Unsafe managed target path' "$(<"$test_root/uninstall-symlink.out")"
assert 'outside file is preserved' test "$(cat "$symlink_outside")" = 'outside file'

# Simulate rm deleting a file and then reporting failure; uninstall must recover it.
cat > "$mock_bin/rm" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_RM_TARGET" && ! -e $FAIL_RM_MARKER ]]; then
  "$REAL_RM" "$@"
  : > "$FAIL_RM_MARKER"
  exit 1
fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$mock_bin/rm"
failure_home="$test_root/uninstall-failure-home"
mkdir -p "$failure_home"
HOME="$failure_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
failure_target="$failure_home/.config/kitty/kitty.conf"
real_rm=$(command -v rm)
if PATH="$mock_bin:$PATH" REAL_RM="$real_rm" REAL_MV="$real_mv" FAIL_RM_TARGET="$failure_target" FAIL_RM_MARKER="$test_root/rm-failed-once" \
  HOME="$failure_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-failure.out" 2>&1; then
  printf 'not ok - simulated uninstall failure should fail\n' >&2; exit 1
fi
contains 'failed uninstall reports rollback' 'Rollback restored' "$(<"$test_root/uninstall-failure.out")"
assert 'failed uninstall restores removed file' cmp -s "$failure_target" "$fixture/core/configs/kitty/kitty.conf"
contains 'failed uninstall leaves ownership state consistent' 'unchanged' "$(HOME="$failure_home" "$fixture/arclith.sh" config status kitty)"
contains 'failed uninstall preserves recovery backup' 'available' "$(HOME="$failure_home" "$fixture/arclith.sh" config backups kitty)"

# A failed final state commit must put the removed file and managed record back.
state_failure_home="$test_root/uninstall-state-failure-home"
mkdir -p "$state_failure_home"
HOME="$state_failure_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
state_failure_target="$state_failure_home/.config/kitty/kitty.conf"
state_failure_manifest="$state_failure_home/.local/state/arclith/deployments.v1"
state_failure_bin="$test_root/state-failure-bin"
mkdir -p "$state_failure_bin"
cat > "$state_failure_bin/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ $destination == "$FAIL_MV_TARGET" ]]; then
  count=0
  [[ ! -f $FAIL_MV_COUNTER ]] || read -r count < "$FAIL_MV_COUNTER"
  ((count += 1))
  printf '%s\n' "$count" > "$FAIL_MV_COUNTER"
  if (( count == 2 )); then exit 1; fi
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$state_failure_bin/mv"
if PATH="$state_failure_bin:$PATH" REAL_MV="$real_mv" FAIL_MV_TARGET="$state_failure_manifest" FAIL_MV_COUNTER="$test_root/state-mv-count" \
  HOME="$state_failure_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/uninstall-state-failure.out" 2>&1; then
  printf 'not ok - simulated final uninstall state failure should fail\n' >&2; exit 1
fi
contains 'final state failure reports file recovery' 'Rollback restored' "$(<"$test_root/uninstall-state-failure.out")"
assert 'final state failure restores deployed file' cmp -s "$state_failure_target" "$fixture/core/configs/kitty/kitty.conf"
contains 'final state failure restores managed state' 'unchanged' "$(HOME="$state_failure_home" "$fixture/arclith.sh" config status kitty)"
assert 'final state failure preserves valid tracked recovery backup' test "$(HOME="$state_failure_home" "$fixture/arclith.sh" config backups kitty | grep -c available)" -eq 1

# Uninstalling one component must not cross into another registered target.
multi_home="$test_root/multi-component-home"
mkdir -p "$fixture/core/configs/zsh" "$multi_home"
printf 'export PATH=$HOME/bin:$PATH\n' > "$fixture/core/configs/zsh/.zshrc"
HOME="$multi_home" "$fixture/arclith.sh" config apply kitty --yes >/dev/null
HOME="$multi_home" "$fixture/arclith.sh" config apply zsh --yes >/dev/null
multi_kitty_target="$multi_home/.config/kitty/kitty.conf"
multi_zsh_target="$multi_home/.zshrc"
HOME="$multi_home" "$fixture/arclith.sh" config uninstall kitty --yes > "$test_root/multi-uninstall.out"
assert 'component uninstall leaves other component target intact' cmp -s "$multi_zsh_target" "$fixture/core/configs/zsh/.zshrc"
contains 'other component remains tracked unchanged' 'zsh  .zshrc  unchanged' "$(HOME="$multi_home" "$fixture/arclith.sh" config status zsh)"
assert 'selected component alone is removed' test ! -e "$multi_kitty_target"
HOME="$multi_home" "$fixture/arclith.sh" config uninstall zsh --yes >/dev/null
assert 'second component can be uninstalled independently' test ! -e "$multi_zsh_target"

# Newly bundled components use the same validated and tracked lifecycle. All
# homes below are temporary fixtures; no host configuration is touched.
waybar_home="$test_root/waybar-home"
mkdir -p "$waybar_home/.config/waybar"
waybar_target="$waybar_home/.config/waybar/config.jsonc"
waybar_source="$fixture/core/configs/waybar/config.jsonc"
waybar_preview=$(HOME="$waybar_home" "$fixture/arclith.sh" config preview waybar)
contains 'Waybar source is registered and previewable' NEW "$waybar_preview"
assert 'Waybar preview creates no target' test ! -e "$waybar_target"
printf 'keep unrelated Waybar data\n' > "$waybar_home/.config/waybar/keep.txt"
HOME="$waybar_home" "$fixture/arclith.sh" config apply waybar --yes >/dev/null
assert 'Waybar deployment installs the bundled configuration' cmp -s "$waybar_source" "$waybar_target"
contains 'Waybar registration reports an available source' 'waybar     available' "$(HOME="$waybar_home" "$fixture/arclith.sh" config list)"
HOME="$waybar_home" "$fixture/arclith.sh" config uninstall waybar --yes > "$test_root/waybar-uninstall.out"
assert 'Waybar uninstall removes unchanged managed config' test ! -e "$waybar_target"
assert 'Waybar uninstall preserves unrelated files' test "$(cat "$waybar_home/.config/waybar/keep.txt")" = 'keep unrelated Waybar data'
waybar_recovery=$(find "$waybar_home" -name 'config.jsonc.arclith-backup.*' -type f -print -quit)
waybar_recovery_id=${waybar_recovery##*.arclith-backup.}
test -n "$waybar_recovery_id"
HOME="$waybar_home" "$fixture/arclith.sh" config restore "$waybar_recovery_id" --yes >/dev/null
assert 'Waybar recovery backup restores deployed config' cmp -s "$waybar_source" "$waybar_target"

rofi_home="$test_root/rofi-home"
mkdir -p "$rofi_home/.config/rofi"
rofi_target="$rofi_home/.config/rofi/config.rasi"
rofi_source="$fixture/core/configs/rofi/config.rasi"
printf 'existing user Rofi settings\n' > "$rofi_target"
rofi_preview=$(HOME="$rofi_home" "$fixture/arclith.sh" config preview rofi)
contains 'Rofi source is registered and previewable' CONFLICT "$rofi_preview"
if HOME="$rofi_home" "$fixture/arclith.sh" config apply rofi </dev/null > "$test_root/rofi-refused.out" 2>&1; then
  printf 'not ok - Rofi conflict should require confirmation\n' >&2; exit 1
fi
assert 'Rofi declined conflict preserves existing user file' test "$(cat "$rofi_target")" = 'existing user Rofi settings'
HOME="$rofi_home" "$fixture/arclith.sh" config apply rofi --yes >/dev/null
assert 'Rofi deployment installs the bundled configuration' cmp -s "$rofi_source" "$rofi_target"
rofi_backup=$(find "$rofi_home" -name 'config.rasi.arclith-backup.*' -type f -print -quit)
rofi_backup_id=${rofi_backup##*.arclith-backup.}
assert 'Rofi overwrite preserves original user configuration' test "$(cat "$rofi_backup")" = 'existing user Rofi settings'
printf 'user changed Rofi settings\n' > "$rofi_target"
if HOME="$rofi_home" "$fixture/arclith.sh" config uninstall rofi --yes > "$test_root/rofi-modified.out" 2>&1; then
  printf 'not ok - modified Rofi config should not be removed\n' >&2; exit 1
fi
contains 'Rofi uninstall preserves modified user configuration' PRESERVE "$(cat "$test_root/rofi-modified.out")"
assert 'modified Rofi file remains intact' test "$(cat "$rofi_target")" = 'user changed Rofi settings'
HOME="$rofi_home" "$fixture/arclith.sh" config restore "$rofi_backup_id" --yes >/dev/null
assert 'Rofi backup restores original user configuration' test "$(cat "$rofi_target")" = 'existing user Rofi settings'

printf 'All configuration deployment tests passed.\n'
