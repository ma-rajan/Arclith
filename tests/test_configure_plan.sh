#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/fixture"
home="$test_root/home"
mock_bin="$test_root/bin"
mkdir -p -- "$fixture" "$home" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/core" "$repo_root/config" \
  "$repo_root/hardware" "$repo_root/install" "$repo_root/packages" "$repo_root/profiles" "$fixture/"

assert() {
  local description=$1
  shift
  if "$@"; then printf 'ok - %s\n' "$description"; else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}
contains() {
  local description=$1 expected=$2 actual=$3
  if [[ $actual == *"$expected"* ]]; then printf 'ok - %s\n' "$description"; else
    printf 'not ok - %s (missing: %s)\n' "$description" "$expected" >&2
    printf '%s\n' "$actual" >&2
    exit 1
  fi
}
run() { HOME="$home" PATH="$mock_bin:$PATH" "$fixture/arclith.sh" configure "$@"; }
expect_status() {
  local expected=$1 description=$2
  shift 2
  local status=0
  if HOME="$home" PATH="$mock_bin:$PATH" "$fixture/arclith.sh" configure "$@" >"$test_root/case.out" 2>&1; then status=0; else status=$?; fi
  assert "$description (status $expected)" test "$status" -eq "$expected"
}
home_inventory() { find "$home" -mindepth 1 -printf '%P|%y|%s\n' | LC_ALL=C sort; }
config_inventory() { find "$fixture/config" -type f -exec sha256sum {} + | LC_ALL=C sort; }

cat > "$mock_bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >> "$MOCK_CALLS"
exit 0
EOF
cat > "$mock_bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >> "$MOCK_CALLS"
exit 0
EOF
chmod +x "$mock_bin/pacman" "$mock_bin/sudo"
export MOCK_CALLS="$test_root/mock-calls"

help_output=$(HOME="$home" "$fixture/arclith.sh" configure --help)
contains 'configure help identifies planning-only behavior' 'planning-only' "$help_output"
contains 'configure help documents component selection' '--components all|name,...' "$help_output"

settings_before=$(sha256sum "$fixture/config/arclith.conf")
home_before=$(home_inventory)
config_before=$(config_inventory)
default_output=$(run)
contains 'no-argument configure resolves configured default' 'Configured default profile: minimal' "$default_output"
contains 'no-argument configure labels selected profile separately' 'Selected profile for this invocation: minimal' "$default_output"
contains 'package planning uses the profile package plan' 'Package plan (3 package(s)' "$default_output"
contains 'default selection previews Kitty' 'Configuration preview: kitty' "$default_output"
contains 'default selection previews Rofi' 'Configuration preview: rofi' "$default_output"
contains 'default selection previews Waybar' 'Configuration preview: waybar' "$default_output"
contains 'registered missing sources are called not deployable' 'hyprland: unavailable' "$default_output"
contains 'Zsh source is reported unavailable' 'zsh: unavailable' "$default_output"
contains 'Wallust source is reported unavailable' 'wallust: unavailable' "$default_output"
contains 'planning makes no execution claim' 'no packages were installed and no configuration was applied' "$default_output"
assert 'default planning leaves fixture home inventory unchanged' test "$(home_inventory)" = "$home_before"

cp "$fixture/config/arclith.conf" "$test_root/arclith.conf"
printf 'PROFILE=missing\nINSTALL_AUR_HELPER=false\nBACKUP_EXISTING_CONFIG=true\n' > "$fixture/config/arclith.conf"
expect_status 1 'missing configured default profile fails planning'
contains 'missing configured default diagnostic is clear' 'Configured default profile is missing or invalid: missing' "$(<"$test_root/case.out")"
mv "$test_root/arclith.conf" "$fixture/config/arclith.conf"

explicit_output=$(run developer --components kitty,waybar)
contains 'explicit profile is selected for this invocation' 'Selected profile for this invocation: developer' "$explicit_output"
contains 'explicit selection leaves default unchanged in report' 'Configured default profile: minimal' "$explicit_output"
contains 'selected available components are previewed' 'Configuration preview: kitty' "$explicit_output"
contains 'selected available components include Waybar' 'Configuration preview: waybar' "$explicit_output"
assert 'explicit profile selection does not rewrite configured defaults' test "$(sha256sum "$fixture/config/arclith.conf")" = "$settings_before"

all_output=$(run --components all)
contains 'all selects bundled Kitty' 'Configuration preview: kitty' "$all_output"
contains 'all selects bundled Rofi' 'Configuration preview: rofi' "$all_output"
contains 'all selects bundled Waybar' 'Configuration preview: waybar' "$all_output"

kitty_only=$(run --components kitty --dry-run)
contains 'explicit single component selection succeeds' 'Configuration preview: kitty' "$kitty_only"
assert 'single component selection omits Rofi preview' bash -c '[[ "$1" != *"Configuration preview: rofi"* ]]' _ "$kitty_only"
contains 'dry-run is labeled while remaining planning-only' 'read-only, dry-run' "$kitty_only"

expect_status 2 'unknown option is rejected' --bogus
contains 'unknown option diagnostic is specific' 'Unsupported configure option: --bogus' "$(<"$test_root/case.out")"
expect_status 2 'unexpected positional argument is rejected' minimal developer
expect_status 2 'duplicate dry-run is rejected' --dry-run --dry-run
expect_status 2 'duplicate component option is rejected' --components kitty --components rofi
expect_status 2 'missing component option value is rejected' --components
expect_status 2 'leading comma in component list is rejected' --components ,kitty
expect_status 2 'trailing comma in component list is rejected' --components kitty,
expect_status 2 'empty component in list is rejected' --components kitty,,rofi
expect_status 2 'component whitespace is rejected' --components 'kitty, rofi'
expect_status 2 'unknown component is rejected' --components nonexistent
expect_status 2 'duplicate component is rejected' --components kitty,kitty
expect_status 2 'unknown profile is rejected' nonexistent
contains 'unknown profile diagnostic is meaningful' 'Unknown profile: nonexistent' "$(<"$test_root/case.out")"
expect_status 2 'malformed profile name is rejected' ../minimal
expect_status 1 'explicit registered unavailable component fails closed' --components hyprland
contains 'unavailable component diagnostic identifies status' 'source status: unavailable' "$(<"$test_root/case.out")"

cp "$fixture/profiles/developer/profile.conf" "$test_root/developer.conf"
printf 'NAME=developer\nDESCRIPTION=Broken fixture\nVERSION=1.0.0\nPACKAGE_LISTS=missing.txt\n' > "$fixture/profiles/developer/profile.conf"
expect_status 1 'invalid profile manifest fails planning' developer
contains 'invalid profile diagnostic is useful' "Profile 'developer' is invalid" "$(<"$test_root/case.out")"
mv "$test_root/developer.conf" "$fixture/profiles/developer/profile.conf"

mkdir -p "$home/.config/kitty"
printf 'user kitty settings\n' > "$home/.config/kitty/kitty.conf"
before_preview=$(home_inventory)
conflict_output=$(run --components kitty)
contains 'preview clearly reports existing target conflict' 'CONFLICT' "$conflict_output"
assert 'ordinary planning leaves conflicting target unchanged' test "$(<"$home/.config/kitty/kitty.conf")" = 'user kitty settings'
assert 'ordinary planning creates no lock, journal, backup, or recovery artifact' test ! -e "$home/.local/state/arclith"
assert 'ordinary planning preserves complete fixture home inventory' test "$(home_inventory)" = "$before_preview"

dry_before=$(home_inventory)
dry_output=$(run --components kitty --dry-run)
contains 'dry-run still creates a preview' 'Configuration preview: kitty' "$dry_output"
assert 'dry-run preserves complete fixture home inventory' test "$(home_inventory)" = "$dry_before"
assert 'dry-run creates no state directory or lock' test ! -e "$home/.local/state/arclith"
assert 'configured default file remains unchanged after all planning' test "$(sha256sum "$fixture/config/arclith.conf")" = "$settings_before"
assert 'configuration registry and defaults remain unchanged after planning' test "$(config_inventory)" = "$config_before"
assert 'mock package manager and sudo were never invoked' test ! -e "$MOCK_CALLS"

mv "$fixture/core/configs/kitty" "$fixture/core/configs/kitty.saved"
ln -s "$test_root/outside-source" "$fixture/core/configs/kitty"
expect_status 1 'unsafe registered source fails closed' --components kitty
contains 'unsafe source diagnostic identifies symlink' 'source status: unsafe-symlink' "$(<"$test_root/case.out")"
assert 'unsafe source planning creates no config state' test ! -e "$home/.local/state/arclith"
rm "$fixture/core/configs/kitty"
mv "$fixture/core/configs/kitty.saved" "$fixture/core/configs/kitty"

cp "$fixture/core/configs/waybar/config.jsonc" "$test_root/waybar.jsonc"
: > "$fixture/core/configs/waybar/config.jsonc"
expect_status 1 'empty selected source file fails validation' --components waybar
contains 'empty source file diagnostic is specific' 'source file must be non-empty text' "$(<"$test_root/case.out")"
assert 'invalid source file creates no config state' test ! -e "$home/.local/state/arclith"
mv "$test_root/waybar.jsonc" "$fixture/core/configs/waybar/config.jsonc"

assert 'package manager mock remains untouched at test end' test ! -e "$MOCK_CALLS"
printf 'Configure planning tests passed; all fixture state stayed under %s.\n' "$test_root"
