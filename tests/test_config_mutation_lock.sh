#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-mutation-lock-tests.XXXXXX")
first_pid=
cleanup() {
  if [[ -n $first_pid ]]; then
    kill -TERM "$first_pid" 2>/dev/null || true
    wait "$first_pid" 2>/dev/null || true
  fi
  rm -rf -- "$test_root"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source "$repo_root/core/config.sh"

fixture="$test_root/project"
home="$test_root/home"
mock_bin="$test_root/mock-bin"
mkdir -p "$fixture" "$home" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/packages" "$repo_root/profiles" "$fixture/"
real_mv=$(command -v mv)
cat > "$mock_bin/mv" <<'EOF'
#!/usr/bin/env bash
destination=${!#}
if [[ -n ${GATE_TARGET:-} && $destination == "$GATE_TARGET" ]]; then
  : > "$GATE_ENTERED"
  IFS= read -r _ < "$GATE_FIFO"
fi
if [[ -n ${FAIL_TARGET:-} && $destination == "$FAIL_TARGET" ]]; then
  exit 1
fi
exec "$REAL_MV" "$@"
EOF
chmod +x "$mock_bin/mv"
export PATH="$mock_bin:$PATH" REAL_MV="$real_mv"
kitty_target="$home/.config/kitty/kitty.conf"
mkdir -p "$(dirname -- "$kitty_target")"
printf 'user configuration before apply\n' > "$kitty_target"

assert() {
  local description=$1
  shift
  if "$@"; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}
contains() {
  local description=$1 expected=$2 output=$3
  if [[ $output == *"$expected"* ]]; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s (missing: %s)\n' "$description" "$expected" >&2; exit 1; fi
}

# A controlled flock failure must stop apply before it changes a target.
fail_bin="$test_root/fail-bin"
mkdir -p "$fail_bin"
cat > "$fail_bin/flock" <<'EOF'
#!/usr/bin/env bash
exit 76
EOF
chmod +x "$fail_bin/flock"
status=0
failure_output=$(HOME="$home" PATH="$fail_bin:$PATH" \
  "$fixture/arclith.sh" config apply kitty --yes 2>&1) || status=$?
assert 'lock acquisition failure is propagated' test "$status" -eq 1
contains 'lock acquisition failure is explicit' 'flock status 76' "$failure_output"
assert 'apply does not begin when lock acquisition fails' \
  test "$(<"$kitty_target")" = 'user configuration before apply'
assert 'failed acquisition does not write deployment state' test ! -e "$home/.local/state/arclith/deployments.v1"

# Dry-run remains read-only and does not create the operation lock.
dry_home="$test_root/dry-home"
mkdir -p "$dry_home"
HOME="$dry_home" "$fixture/arclith.sh" config apply-new kitty --dry-run > /dev/null
assert 'apply-new dry-run does not create the operation lock' \
  test ! -e "$dry_home/.local/state/arclith/operation.lock"

# Hold the first real apply at its target rename, then start a different
# mutation against the same HOME. The FIFO makes the overlap deterministic.
waybar_target="$home/.config/waybar/config.jsonc"
gate_fifo="$test_root/release.fifo"
gate_entered="$test_root/apply-at-rename"
mkfifo "$gate_fifo"
GATE_TARGET="$kitty_target" GATE_FIFO="$gate_fifo" GATE_ENTERED="$gate_entered" \
  HOME="$home" "$fixture/arclith.sh" config apply kitty --yes \
  > "$test_root/first.out" 2>&1 &
first_pid=$!
ready=no
for ((attempt=0; attempt<500; attempt++)); do
  if [[ -e $gate_entered ]]; then ready=yes; break; fi
  kill -0 "$first_pid" 2>/dev/null || break
  sleep 0.01
done
assert 'first apply reaches the synchronized mutation point' test "$ready" = yes
transaction_record=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' -print -quit)
transaction_id=${transaction_record##*/}
transaction_id=${transaction_id%.v1}
config_transaction_journal_read "$home" "$transaction_id"
assert 'locked in-flight apply journal is APPLYING' test "$CONFIG_TXN_JOURNAL_STATE" = APPLYING
config_transaction_target_read "$home" "$transaction_id" 000000
assert 'locked in-flight target is MUTATION_INTENT at the rename boundary' test "$CONFIG_TXN_TARGET_STATE" = MUTATION_INTENT
journal_count_before=$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)
second_status=0
second_output=$(HOME="$home" "$fixture/arclith.sh" config apply waybar --yes 2>&1) || second_status=$?
assert 'competing mutation returns the distinct busy status' test "$second_status" -eq 75
contains 'competing mutation reports the held operation lock' 'Another Arclith configuration operation holds the lock' "$second_output"
assert 'competing mutation does not create its target' test ! -e "$waybar_target"
assert 'competing mutation does not create a partial manifest' test ! -e "$home/.local/state/arclith/deployments.v1"
assert 'rejected competing mutation creates no transaction journal' \
  test "$(find "$home/.local/state/arclith/transactions" -maxdepth 1 -type f -name '*.v1' | wc -l)" -eq "$journal_count_before"
printf 'continue\n' > "$gate_fifo"
first_status=0
wait "$first_pid" || first_status=$?
first_pid=
assert 'first mutation succeeds after the gate is released' test "$first_status" -eq 0
assert 'first mutation installs its target' test -f "$kitty_target"
assert 'first mutation commits its manifest' test -f "$home/.local/state/arclith/deployments.v1"
backup_id=$(awk -F'|' '$1 == "B" { print $2; exit }' "$home/.local/state/arclith/deployments.v1")
assert 'apply records a restore backup for the prior user configuration' test -n "$backup_id"

# The same per-home acquisition boundary protects restore, uninstall, and
# prune before they inspect or alter deployment state.
restore_status=0
restore_output=$(HOME="$home" PATH="$fail_bin:$PATH" \
  "$fixture/arclith.sh" config restore "$backup_id" --yes 2>&1) || restore_status=$?
assert 'restore acquisition failure is propagated' test "$restore_status" -eq 1
contains 'restore acquisition failure is explicit' 'flock status 76' "$restore_output"
assert 'restore does not begin when lock acquisition fails' \
  test "$(sha256sum "$kitty_target" | cut -d' ' -f1)" = "$(sha256sum "$fixture/core/configs/kitty/kitty.conf" | cut -d' ' -f1)"

uninstall_status=0
uninstall_output=$(HOME="$home" PATH="$fail_bin:$PATH" \
  "$fixture/arclith.sh" config uninstall kitty --yes 2>&1) || uninstall_status=$?
assert 'uninstall acquisition failure is propagated' test "$uninstall_status" -eq 1
contains 'uninstall acquisition failure is explicit' 'flock status 76' "$uninstall_output"
assert 'uninstall does not begin when lock acquisition fails' test -f "$kitty_target"

prune_status=0
prune_output=$(HOME="$home" PATH="$fail_bin:$PATH" \
  "$fixture/arclith.sh" config prune kitty --yes 2>&1) || prune_status=$?
assert 'prune acquisition failure is propagated' test "$prune_status" -eq 1
contains 'prune acquisition failure is explicit' 'flock status 76' "$prune_output"
assert 'prune does not begin when lock acquisition fails' test -f "$kitty_target"

# The completed mutation released its lock; a subsequent mutation can update
# the same manifest and both ownership records remain valid.
HOME="$home" "$fixture/arclith.sh" config apply waybar --yes > "$test_root/sequential.out"
assert 'sequential mutation succeeds after release' test -f "$waybar_target"
status_output=$(HOME="$home" "$fixture/arclith.sh" config status)
contains 'manifest retains the first mutation' '.config/kitty/kitty.conf' "$status_output"
contains 'manifest records the sequential mutation' '.config/waybar/config.jsonc' "$status_output"

# An operation failure after acquisition must still release the lock.
rofi_target="$home/.config/rofi/config.rasi"
status=0
FAIL_TARGET="$rofi_target" HOME="$home" \
  "$fixture/arclith.sh" config apply rofi --yes > "$test_root/failed-apply.out" 2>&1 || status=$?
assert 'injected target mutation failure is reported' test "$status" -eq 1
assert 'failed mutation leaves its target absent' test ! -e "$rofi_target"
HOME="$home" "$fixture/arclith.sh" config apply rofi --yes > "$test_root/retry.out"
assert 'mutation can reacquire after an operation error' test -f "$rofi_target"
status_output=$(HOME="$home" "$fixture/arclith.sh" config status)
contains 'manifest remains valid after failed operation and retry' '.config/rofi/config.rasi' "$status_output"

printf 'Configuration mutation lock integration tests passed; all state paths were isolated under %s.\n' "$test_root"
