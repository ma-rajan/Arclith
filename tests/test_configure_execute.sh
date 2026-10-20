#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/fixture" home="$test_root/home" mock="$test_root/bin"
mkdir -p "$fixture" "$home" "$mock"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" "$repo_root/hardware" \
  "$repo_root/install" "$repo_root/packages" "$repo_root/profiles" "$fixture/"
real_awk=$(command -v awk)
cat > "$mock/awk" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == /etc/os-release ]]; then printf 'Arch fixture\037arch\037\037true\037true\037false\n'; exit 0; fi
done
exec "$REAL_AWK" "$@"
MOCK
cat > "$mock/pacman" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$PACMAN_LOG"
case ${1-} in
  -Qq) [[ ${PACMAN_QUERY_FAIL:-0} != 1 ]] || exit 43; printf 'git\n' ;;
  -S) [[ ${PACMAN_FAIL:-0} != 1 ]] || exit 42 ;;
  *) exit 64 ;;
esac
MOCK
cat > "$mock/sudo" <<'MOCK'
#!/usr/bin/env bash
exec "$@"
MOCK
chmod +x "$mock/awk" "$mock/pacman" "$mock/sudo"
export REAL_AWK="$real_awk" PACMAN_LOG="$test_root/pacman.log"
: > "$PACMAN_LOG"
run() { HOME="$home" PATH="$mock:$PATH" "$fixture/arclith.sh" configure "$@"; }
assert() { local label=$1; shift; "$@" || { printf 'not ok - %s\n' "$label" >&2; exit 1; }; printf 'ok - %s\n' "$label"; }
expect_status() { local expected=$1 label=$2 rc=0; shift 2; if run "$@" >"$test_root/out" 2>&1; then rc=0; else rc=$?; fi; assert "$label (status $expected)" test "$rc" -eq "$expected"; }

before=$(find "$home" -mindepth 1 -printf '%P|%y|%s\n' | sort)
run --apply-config --install-packages --dry-run > "$test_root/out"
assert 'combined dry-run queries package state without installing' grep -q -- '-Qq' "$PACMAN_LOG"
assert 'combined dry-run does not invoke package mutation' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"
assert 'combined dry-run does not create targets, locks, journals, or state' test "$(find "$home" -mindepth 1 -printf '%P|%y|%s\n' | sort)" = "$before"
: > "$PACMAN_LOG"

run --components kitty --apply-config --yes > "$test_root/out"
assert 'config-only applies Kitty' test -f "$home/.config/kitty/kitty.conf"
assert 'config-only does not query or install packages' test ! -s "$PACMAN_LOG"
assert 'config-only creates transaction state under fixture HOME' test -d "$home/.local/state/arclith/transactions"

kitty_target="$home/.config/kitty/kitty.conf"
printf 'user local edit
' > "$kitty_target"
transactions_before=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
run --components kitty --apply-config --yes > "$test_root/out"
assert 'apply preserves local edits to tracked managed files' test "$(<"$kitty_target")" = 'user local edit'
assert 'plan identifies tracked local edits' grep -q 'PRESERVE locally modified tracked file .config/kitty/kitty.conf' "$test_root/out"
transactions_after=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
assert 'preserved local edit creates no new transaction' test "$transactions_after" -eq "$transactions_before"

rm -rf "$home/.config" "$home/.local"
: > "$PACMAN_LOG"
run --install-packages --yes > "$test_root/out"
assert 'package-only invokes one package installation' grep -q -- '^-S --needed --' "$PACMAN_LOG"
assert 'package-only does not deploy configuration or create Arclith state' test ! -e "$home/.config" -a ! -e "$home/.local"

: > "$PACMAN_LOG"
printf 'y\n' | run --components kitty --install-packages --apply-config > "$test_root/out" 2>&1
assert 'combined operation prompts once' test "$(grep -c 'Continue with the requested actions' "$test_root/out")" -eq 1
assert 'combined operation installs packages and deploys config' grep -q -- '^-S --needed --' "$PACMAN_LOG"
assert 'combined operation reports component completion' grep -q 'Completed: configuration component kitty' "$test_root/out"

rm -rf "$home/.config" "$home/.local"
: > "$PACMAN_LOG"
expect_status 1 'declined combined confirmation exits nonzero' --components kitty --apply-config --install-packages < /dev/null
assert 'decline makes no package install call' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"
assert 'decline makes no configuration or state change' test ! -e "$home/.config" -a ! -e "$home/.local"

: > "$PACMAN_LOG"
PACMAN_FAIL=1 expect_status 42 'package failure is propagated' --components kitty --install-packages --apply-config --yes
assert 'package failure prevents config deployment' test ! -e "$home/.config/kitty/kitty.conf"
assert 'package failure reports config not attempted' grep -q 'configuration was not attempted' "$test_root/out"
: > "$PACMAN_LOG"
rm -rf "$home/.local" "$home/.config"
PACMAN_QUERY_FAIL=1 expect_status 1 'package query failure stops before mutation' --components kitty --install-packages --apply-config --yes
assert 'query failure prevents install invocation' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"
assert 'query failure prevents lock and configuration state creation' test ! -e "$home/.local/state/arclith"


# New-only planning must list existing conflicts and preserve their bytes.
rm -rf "$home/.config" "$home/.local"
mkdir -p "$home/.config/kitty"
printf 'user-owned kitty file\n' > "$home/.config/kitty/kitty.conf"
run --components kitty --apply-config --dry-run > "$test_root/out"
assert 'dry-run identifies unmanaged configuration conflicts' grep -q 'PRESERVE unmanaged conflict .config/kitty/kitty.conf' "$test_root/out"
assert 'dry-run preserves unmanaged conflict contents' test "$(<"$home/.config/kitty/kitty.conf")" = 'user-owned kitty file'
assert 'dry-run creates no state artifacts beside the conflict' test ! -e "$home/.local"
rm -rf "$home/.config"

# Change the target after the displayed plan and before confirmation. The
# locked comparison must abort before package installation or deployment.
mkfifo "$test_root/input"
: > "$PACMAN_LOG"
HOME="$home" PATH="$mock:$PATH" "$fixture/arclith.sh" configure --components kitty --apply-config --install-packages \
  < "$test_root/input" > "$test_root/out" 2>&1 &
configure_pid=$!
exec 8>"$test_root/input"
ready=0
for _ in {1..100}; do
  if grep -q 'Continue with the requested actions' "$test_root/out"; then ready=1; break; fi
  sleep 0.05
done
assert 'execution reaches confirmation after complete plan' test "$ready" -eq 1
mkdir -p "$home/.config/kitty"
printf 'created while confirmation was pending\n' > "$home/.config/kitty/kitty.conf"
printf 'y\n' >&8
exec 8>&-
if wait "$configure_pid"; then drift_status=0; else drift_status=$?; fi
assert 'changed configuration plan fails safely' test "$drift_status" -eq 1
assert 'plan drift prevents package installation' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"
assert 'plan drift leaves concurrent user file unchanged' test "$(<"$home/.config/kitty/kitty.conf")" = 'created while confirmation was pending'
assert 'plan drift diagnostic requests a fresh review' grep -q 'rerun configure to review' "$test_root/out"
rm -f "$test_root/input"
rm -rf "$home/.config" "$home/.local"

# Fail the Rofi target rename after Kitty completes. The batch must stop and
# report Waybar as not attempted, while retaining Kitty's completed file.
cat > "$mock/mv" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == */.config/rofi/* ]]; then exit 41; fi
done
exec "$REAL_MV" "$@"
MOCK
chmod +x "$mock/mv"
export REAL_MV="$(command -v mv)"
expect_status 1 'later component failure returns failure' --components kitty,rofi,waybar --apply-config --yes
assert 'earlier component remains completed after later failure' test -f "$home/.config/kitty/kitty.conf"
assert 'failed component is identified' grep -q 'Failed: configuration component rofi' "$test_root/out"
assert 'later component is reported not attempted' grep -q 'Not attempted: configuration component waybar' "$test_root/out"
assert 'partial failure makes no package installation when package action omitted' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"

# Hold the exact fixture lock from this shell; the child must return 75 before
# any package mutation. This models a competing Arclith operation.
mkdir -p -m 700 "$home/.local/state/arclith"
: > "$home/.local/state/arclith/operation.lock"
chmod 600 "$home/.local/state/arclith/operation.lock"
exec 9<>"$home/.local/state/arclith/operation.lock"
flock -n -x 9
: > "$PACMAN_LOG"
expect_status 75 'lock contention returns the established status' --components kitty --install-packages --apply-config --yes
assert 'lock contention occurs before package install' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"
exec 9>&-

# Repeated new-only apply must avoid another transaction when all targets are tracked.
rm -rf "$home/.local/state/arclith/operation.lock"
run --components kitty --apply-config --yes > "$test_root/out"
transactions_before=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
run --components kitty --apply-config --yes > "$test_root/out"
transactions_after=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
assert 'repeat invocation avoids an unnecessary transaction' test "$transactions_after" -eq "$transactions_before"

expect_status 2 'execution option duplicates are rejected' --apply-config --apply-config
expect_status 1 'unavailable source is rejected before execution' --components hyprland --apply-config --yes

rm -rf "$home/.config" "$home/.local"
source_path="$fixture/core/configs/kitty"
mv "$source_path" "$source_path.saved"
ln -s "$test_root/missing-source" "$source_path"
: > "$PACMAN_LOG"
expect_status 1 'unsafe source is rejected before requested actions' --components kitty --install-packages --apply-config --yes
assert 'unsafe source never reaches package installation' bash -c '! grep -q -- "^-S" "$1"' _ "$PACMAN_LOG"
assert 'unsafe source is never deployed' test ! -e "$home/.config/kitty/kitty.conf"
rm "$source_path"
mv "$source_path.saved" "$source_path"

cat > "$mock/mv" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == */transactions/*.v1 ]]; then exit 45; fi
done
exec "$REAL_MV" "$@"
MOCK
chmod +x "$mock/mv"
expect_status 1 'journal creation failure stops deployment' --components kitty --apply-config --yes
assert 'journal failure leaves target untouched' test ! -e "$home/.config/kitty/kitty.conf"
assert 'journal failure diagnostic is preserved' grep -q 'Could not create transaction journal' "$test_root/out"
rm "$mock/mv"
run --components kitty --apply-config --yes > "$test_root/out"
assert 'lock is released after journal failure' test -f "$home/.config/kitty/kitty.conf"
printf 'Configure execution tests passed; fixture state stayed under %s.\n' "$test_root"
