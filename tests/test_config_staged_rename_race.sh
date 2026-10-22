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

# Change the staged inode after Arclith's last staged hash check, exactly when
# it is about to be renamed into the target. This deterministically models the
# same-user, non-cooperating writer window without touching the real HOME.
cat > "$mock_bin/mv" <<'MOCK'
#!/usr/bin/env bash
destination=${!#}
source=${@: -2:1}
if [[ $destination == "$RACE_TARGET" && $source == *.arclith-new.* && ! -e $RACE_MARKER ]]; then
  printf 'bytes changed in the final check-to-rename window\n' > "$source"
  : > "$RACE_MARKER"
fi
exec "$REAL_MV" "$@"
MOCK
chmod +x "$mock_bin/mv"

status=0
output=$(PATH="$mock_bin:$PATH" REAL_MV="$real_mv" RACE_TARGET="$target" \
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
