#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-hardware-json.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT
fixture="$test_root/project"
mock_bin="$test_root/mock-bin"
mkdir -p "$fixture" "$mock_bin"
cp -R "$repo_root/arclith.sh" "$repo_root/hardware" "$fixture/"

assert() {
  local description=$1; shift
  if "$@"; then printf 'ok - %s\n' "$description"
  else printf 'not ok - %s\n' "$description" >&2; exit 1; fi
}

cat > "$mock_bin/hostname" <<'EOF'
#!/usr/bin/env bash
printf '%s' $'host "quoted" \\tab\tname\nsecond line\n'
EOF
cat > "$mock_bin/lspci" <<'EOF'
#!/usr/bin/env bash
printf '%s' $'0000:00:02.0 VGA compatible controller: GPU "quoted" \\tab\tline\nsecond line\n'
EOF
cat > "$mock_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
printf 'nvme0n1 1T \"quoted\"\tmodel disk\n'
EOF
chmod +x "$mock_bin/hostname" "$mock_bin/lspci" "$mock_bin/lsblk"

json_output=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY PATH="$mock_bin:$PATH" XDG_CURRENT_DESKTOP=$'Desk "one"\\tab\tline\nnext' "$fixture/arclith.sh" hardware --json 2>"$test_root/stderr")
assert 'JSON mode writes no diagnostics to stderr on success' test ! -s "$test_root/stderr"
printf '%s\n' "$json_output" > "$test_root/report.json"

if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/report.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert set(report) == {"system", "hardware", "recommendations"}
assert set(report["system"]) == {"operating_system", "kernel", "architecture", "hostname"}
assert set(report["hardware"]) == {
    "cpu", "memory", "gpu", "storage_disks", "desktop_compositor", "displays"
}
assert report["system"]["hostname"] == 'host "quoted" \tab\tname\nsecond line', repr(report["system"]["hostname"])
assert report["hardware"]["desktop_compositor"] == 'Desk "one"\tab\tline\nnext', repr(report["hardware"]["desktop_compositor"])
assert isinstance(report["recommendations"], list) and report["recommendations"]
assert all(set(item) == {"status", "message"} for item in report["recommendations"])
assert any(item["status"] == "Detected" for item in report["recommendations"])
print("ok - JSON parses and schema, present values, escaping, and recommendations are valid")
PY
else
  printf 'skip - Python 3 unavailable for JSON parsing\n'
fi

minimal_bin="$test_root/minimal-bin"
mkdir -p "$minimal_bin"
for utility in bash dirname awk uname cat; do ln -s "$(type -P "$utility")" "$minimal_bin/$utility"; done
unavailable_output=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY PATH="$minimal_bin" "$fixture/arclith.sh" hardware --json 2>"$test_root/unavailable.err")
assert 'missing optional utilities do not cause a failure status' test "$?" -eq 0
assert 'missing optional utilities do not emit failure diagnostics' test ! -s "$test_root/unavailable.err"
printf '%s\n' "$unavailable_output" > "$test_root/unavailable.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/unavailable.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert report["system"]["hostname"] is None
for name in ("gpu", "storage_disks", "desktop_compositor", "displays"):
    assert report["hardware"][name] is None, (name, report["hardware"][name])
print("ok - unavailable values are represented as JSON null")
PY
fi

cat > "$mock_bin/lspci" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$mock_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$mock_bin/lspci" "$mock_bin/lsblk" "$mock_bin/hyprctl"
empty_output=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture PATH="$mock_bin:$PATH" "$fixture/arclith.sh" hardware --json 2>"$test_root/empty.err")
assert 'successful empty probes do not fail' test "$?" -eq 0
assert 'successful empty probes do not emit failure diagnostics' test ! -s "$test_root/empty.err"
printf '%s\n' "$empty_output" > "$test_root/empty.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/empty.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert report["hardware"]["gpu"] is None
assert report["hardware"]["storage_disks"] is None
assert report["hardware"]["displays"] is None
print("ok - successful empty and unrecognized probe output remains unavailable")
PY
fi

probe_bin="$test_root/probe-bin"
probe_dir="$test_root/probe-counts"
mkdir -p "$probe_bin" "$probe_dir"
cat > "$probe_bin/lspci" <<'EOF'
#!/usr/bin/env bash
count_file="$PROBE_DIR/lspci"
count=0
[[ ! -f $count_file ]] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if (( count == 1 )); then
  printf '0000:01:00.0 VGA compatible controller: Advanced Micro Devices, Inc. [AMD/ATI] Radeon fixture\n'
else
  printf '0000:01:00.0 VGA compatible controller: NVIDIA fixture\n'
fi
EOF
cat > "$probe_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
count_file="$PROBE_DIR/lsblk"
count=0
[[ ! -f $count_file ]] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf 'nvme0n1 1T fixture disk\n'
EOF
cat > "$probe_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
count_file="$PROBE_DIR/hyprctl"
count=0
[[ ! -f $count_file ]] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
if (( count == 1 )); then printf 'Monitor DP-1 (fixture)\n'; else printf 'Monitor HDMI-A-1 (fixture)\n'; fi
EOF
cat > "$probe_bin/uname" <<'EOF'
#!/usr/bin/env bash
case ${1-} in
  -r) key=uname-kernel; value=fixture-kernel ;;
  -m) key=uname-architecture; value=x86_64 ;;
  *) exit 2 ;;
esac
count_file="$PROBE_DIR/$key"
count=0
[[ ! -f $count_file ]] || read -r count < "$count_file"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
printf '%s\n' "$value"
EOF
chmod +x "$probe_bin/lspci" "$probe_bin/lsblk" "$probe_bin/hyprctl" "$probe_bin/uname"

snapshot_json=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture PROBE_DIR="$probe_dir" PATH="$probe_bin:$PATH" \
  "$fixture/arclith.sh" hardware --json)
assert 'JSON snapshot invokes GPU, disk, and display probes once' \
  bash -c '[[ $(cat "$1/lspci") == 1 && $(cat "$1/lsblk") == 1 && $(cat "$1/hyprctl") == 1 && $(cat "$1/uname-kernel") == 1 && $(cat "$1/uname-architecture") == 1 ]]' _ "$probe_dir"
printf '%s\n' "$snapshot_json" > "$test_root/snapshot.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/snapshot.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert "AMD" in report["hardware"]["gpu"]
assert report["hardware"]["displays"] == "DP-1"
messages = [item["message"] for item in report["recommendations"]]
assert any("AMD" in message for message in messages)
assert "1 display output(s): DP-1" in messages
assert not any("NVIDIA detected" in message for message in messages)
print("ok - JSON recommendations use the reported first-probe snapshot")
PY
fi

rm -f "$probe_dir"/*
snapshot_human=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture PROBE_DIR="$probe_dir" PATH="$probe_bin:$PATH" \
  "$fixture/arclith.sh" hardware)
assert 'human report invokes GPU, disk, and display probes once' \
  bash -c '[[ $(cat "$1/lspci") == 1 && $(cat "$1/lsblk") == 1 && $(cat "$1/hyprctl") == 1 && $(cat "$1/uname-kernel") == 1 && $(cat "$1/uname-architecture") == 1 ]]' _ "$probe_dir"
case $snapshot_human in
  *'AMD/ATI'*'DP-1'*'AMD detected'*'1 display output(s): DP-1'*)
    printf 'ok - human recommendations use the reported first-probe snapshot\n' ;;
  *) printf 'not ok - human report and recommendations disagree with the snapshot\n' >&2; exit 1 ;;
esac

os_bin="$test_root/os-bin"
os_probe_count="$test_root/os-probe-count"
mkdir -p "$os_bin"
real_awk=$(type -P awk)
cat > "$os_bin/awk" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == /etc/os-release ]]; then
    if [[ ${OS_PROBE_FAIL:-false} == true ]]; then
      printf 'Partial operating-system metadata\n'
      exit 9
    fi
    count=0
    [[ ! -f $OS_PROBE_COUNT ]] || read -r count < "$OS_PROBE_COUNT"
    count=$((count + 1))
    printf '%s\n' "$count" > "$OS_PROBE_COUNT"
    if (( count == 1 )); then
      printf '%s\t%s\t%s\n' "$OS_FIRST_NAME" "$OS_FIRST_ID" "$OS_FIRST_LIKE"
    else
      printf '%s\t%s\t%s\n' 'Changed distribution' "$OS_SECOND_ID" ''
    fi
    exit 0
  fi
done
exec "$REAL_AWK" "$@"
EOF
chmod +x "$os_bin/awk"

os_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$os_bin:$PATH" REAL_AWK="$real_awk" OS_PROBE_COUNT="$os_probe_count" \
  OS_FIRST_NAME='Fixture Arch' OS_FIRST_ID=arch OS_FIRST_LIKE='' OS_SECOND_ID=debian \
  "$fixture/arclith.sh" hardware --json)
assert 'OS metadata source is read once for a JSON report' test "$(<"$os_probe_count")" = 1
printf '%s\n' "$os_json" > "$test_root/os-arch.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/os-arch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert report["system"]["operating_system"] == "Fixture Arch"
messages = [item["message"] for item in report["recommendations"]]
assert "Arch Linux or an Arch-based environment" in messages
assert not any("non-Arch environment" in message for message in messages)
print("ok - JSON recommendation uses captured Arch metadata despite a changed second response")
PY
fi

rm -f "$os_probe_count"
os_human=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$os_bin:$PATH" REAL_AWK="$real_awk" OS_PROBE_COUNT="$os_probe_count" \
  OS_FIRST_NAME='Fixture Debian' OS_FIRST_ID=debian OS_FIRST_LIKE='' OS_SECOND_ID=arch \
  "$fixture/arclith.sh" hardware)
assert 'OS metadata source is read once for a human report' test "$(<"$os_probe_count")" = 1
case $os_human in
  *'Operating system:'*'Fixture Debian'*'A non-Arch environment was detected'* )
    printf 'ok - human recommendations preserve non-Arch behavior from the snapshot\n' ;;
  *) printf 'not ok - non-Arch human recommendation did not use the captured metadata\n' >&2; exit 1 ;;
esac

rm -f "$os_probe_count"
os_like_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$os_bin:$PATH" REAL_AWK="$real_awk" OS_PROBE_COUNT="$os_probe_count" \
  OS_FIRST_NAME='Fixture derivative' OS_FIRST_ID=fixtureos OS_FIRST_LIKE=arch OS_SECOND_ID=debian \
  "$fixture/arclith.sh" hardware --json)
printf '%s\n' "$os_like_json" > "$test_root/os-like.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/os-like.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
messages = [item["message"] for item in report["recommendations"]]
assert "Arch Linux or an Arch-based environment" in messages
print("ok - ID_LIKE Arch distributions retain Arch-based recommendation behavior")
PY
fi

os_failure_status=0
os_failure_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$os_bin:$PATH" REAL_AWK="$real_awk" OS_PROBE_COUNT="$os_probe_count" OS_PROBE_FAIL=true \
  "$fixture/arclith.sh" hardware --json 2>"$test_root/os-failure.err") || os_failure_status=$?
assert 'failed OS metadata probe returns nonzero after rendering' test "$os_failure_status" -eq 1
assert 'failed OS metadata probe reports its diagnostic' grep -Fq 'could not parse /etc/os-release with awk' "$test_root/os-failure.err"
printf '%s\n' "$os_failure_json" > "$test_root/os-failure.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/os-failure.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert report["system"]["operating_system"] is None
messages = [item["message"] for item in report["recommendations"]]
assert "Operating-system compatibility could not be determined because its probe failed" in messages
print("ok - failed OS snapshot is sanitized for compatibility recommendations")
PY
fi

package_bin="$test_root/package-bin"
package_no_pacman_bin="$test_root/package-no-pacman-bin"
package_count="$test_root/package-query-count"
package_list_file="$test_root/installed-packages"
mkdir -p "$package_bin" "$package_no_pacman_bin"
for utility in bash dirname uname cat; do
  ln -s "$(type -P "$utility")" "$package_bin/$utility"
  ln -s "$(type -P "$utility")" "$package_no_pacman_bin/$utility"
done
real_awk=$(type -P awk)
for bin in "$package_bin" "$package_no_pacman_bin"; do
  cat > "$bin/awk" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == /etc/os-release ]]; then
    printf 'Fixture OS\t%s\t\n' "${OS_FIXTURE_ID:-arch}"
    exit 0
  fi
done
exec "$REAL_AWK" "$@"
EOF
  chmod +x "$bin/awk"
done
cat > "$package_bin/pacman" <<'EOF'
#!/usr/bin/env bash
count=0
[[ ! -f $PACKAGE_QUERY_COUNT ]] || read -r count < "$PACKAGE_QUERY_COUNT"
count=$((count + 1))
printf '%s\n' "$count" > "$PACKAGE_QUERY_COUNT"
if [[ ${PACKAGE_QUERY_MODE:-success} == failure ]]; then
  printf 'waybar\n'
  exit 42
fi
cat "$PACKAGE_LIST_FILE"
EOF
chmod +x "$package_bin/pacman"

printf 'git\nwaybar\nrofi-extra\nhyprland\n' > "$package_list_file"
package_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$package_bin" REAL_AWK="$real_awk" PACKAGE_QUERY_COUNT="$package_count" \
  PACKAGE_LIST_FILE="$package_list_file" "$fixture/arclith.sh" hardware --json)
assert 'successful package list is queried once for multiple recommendations' test "$(<"$package_count")" = 1
printf '%s\n' "$package_json" > "$test_root/package-success.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/package-success.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert set(report) == {"system", "hardware", "recommendations"}
messages = [(item["status"], item["message"]) for item in report["recommendations"]]
assert ("Detected", "git package is installed") in messages
assert ("Detected", "waybar package is installed") in messages
assert ("Detected", "Hyprland package is installed") in messages
assert ("Optional", "rofi is not detected") in messages
assert not any("rofi package is installed" in message for _, message in messages)
assert ("Recommended", "Hyprland is not detected for a Hyprland-focused setup") not in messages
print("ok - present and absent package recommendations use exact package names")
PY
fi

rm -f "$package_count"
package_human=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$package_bin" REAL_AWK="$real_awk" PACKAGE_QUERY_COUNT="$package_count" \
  PACKAGE_LIST_FILE="$package_list_file" "$fixture/arclith.sh" hardware)
assert 'human report also performs one package-list query' test "$(<"$package_count")" = 1
case $package_human in
  *'[Detected   ] git package is installed'*'[Optional   ] rofi is not detected'*)
    printf 'ok - successful human package recommendations retain their existing text\n' ;;
  *) printf 'not ok - successful human package recommendations changed unexpectedly\n' >&2; exit 1 ;;
esac

rm -f "$package_count"
package_failure_status=0
package_failure_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$package_bin" REAL_AWK="$real_awk" PACKAGE_QUERY_COUNT="$package_count" \
  PACKAGE_LIST_FILE="$package_list_file" PACKAGE_QUERY_MODE=failure \
  "$fixture/arclith.sh" hardware --json 2>"$test_root/package-failure.err") || package_failure_status=$?
assert 'failed package query returns nonzero after rendering JSON' test "$package_failure_status" -eq 1
assert 'failed package query emits one useful diagnostic' grep -Fq 'pacman -Qq failed with status 42' "$test_root/package-failure.err"
assert 'failed package query happens once' test "$(<"$package_count")" = 1
printf '%s\n' "$package_failure_json" > "$test_root/package-failure.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/package-failure.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert set(report) == {"system", "hardware", "recommendations"}
messages = [(item["status"], item["message"]) for item in report["recommendations"]]
assert ("Unavailable", "git package status could not be checked because the pacman query failed") in messages
assert ("Unavailable", "Hyprland package status could not be checked because the pacman query failed") in messages
assert not any("is not detected" in message for _, message in messages)
assert not any("Hyprland is not detected" in message for _, message in messages)
print("ok - failed query partial output is discarded and JSON schema remains unchanged")
PY
fi
assert 'package query diagnostic stays off JSON stdout' bash -c '[[ "$1" != *"Hardware probe failed"* ]]' _ "$package_failure_json"

package_no_pacman_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$package_no_pacman_bin" REAL_AWK="$real_awk" "$fixture/arclith.sh" hardware --json 2>"$test_root/no-pacman.err")
assert 'missing pacman does not fail the hardware report' test "$?" -eq 0
assert 'missing pacman emits no failure diagnostic' test ! -s "$test_root/no-pacman.err"
printf '%s\n' "$package_no_pacman_json" > "$test_root/no-pacman.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/no-pacman.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
messages = [(item["status"], item["message"]) for item in report["recommendations"]]
assert ("Unavailable", "Cannot check git without pacman") in messages
assert ("Unavailable", "Hyprland package status cannot be checked without pacman") in messages
print("ok - missing pacman leaves package observations unavailable without failing")
PY
fi

non_arch_json=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  PATH="$package_bin" REAL_AWK="$real_awk" PACKAGE_QUERY_COUNT="$package_count" \
  PACKAGE_LIST_FILE="$package_list_file" OS_FIXTURE_ID=debian "$fixture/arclith.sh" hardware --json)
printf '%s\n' "$non_arch_json" > "$test_root/non-arch-packages.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/non-arch-packages.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
messages = [item["message"] for item in report["recommendations"]]
assert "A non-Arch environment was detected; ARCLITH targets Arch Linux" in messages
print("ok - non-Arch compatibility guidance is unchanged")
PY
fi

failure_bin="$test_root/failure-bin"
mkdir -p "$failure_bin"
cat > "$failure_bin/lspci" <<'EOF'
#!/usr/bin/env bash
printf '0000:01:00.0 VGA compatible controller: AMD partial result\n'
exit 42
EOF
cat > "$failure_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
printf 'nvme0n1 1T partial disk\n'
exit 126
EOF
cat > "$failure_bin/timeout" <<'EOF'
#!/usr/bin/env bash
printf 'Monitor DP-9 (partial timed-out result)\n'
exit 124
EOF
cat > "$failure_bin/hostname" <<'EOF'
#!/usr/bin/env bash
exit 13
EOF
chmod +x "$failure_bin/lspci" "$failure_bin/lsblk" "$failure_bin/timeout" "$failure_bin/hostname"

failure_status=0
failure_json=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture PATH="$failure_bin:$PATH" \
  "$fixture/arclith.sh" hardware --json 2>"$test_root/failure.err") || failure_status=$?
assert 'multiple failed probes return nonzero after JSON rendering' test "$failure_status" -eq 1
if ! grep -Fq 'lspci exited with status 42' "$test_root/failure.err" || \
   ! grep -Fq 'lsblk exited with status 126' "$test_root/failure.err" || \
   ! grep -Fq 'hyprctl display probe timed out' "$test_root/failure.err" || \
   ! grep -Fq 'hostname failed with status 13' "$test_root/failure.err"; then
  printf 'not ok - diagnostics for all failed probes were not emitted\n' >&2; exit 1
fi
printf 'ok - multiple failures each produce a stderr diagnostic\n'
printf '%s\n' "$failure_json" > "$test_root/failure.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/failure.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert set(report) == {"system", "hardware", "recommendations"}
assert report["system"]["hostname"] is None
for field in ("gpu", "storage_disks", "displays"):
    assert report["hardware"][field] is None, (field, report["hardware"][field])
messages = [item["message"] for item in report["recommendations"]]
assert "GPU information could not be detected" in messages
assert "Display details are not available in this session" in messages
assert not any("AMD detected" in message for message in messages)
assert not any("display output(s): DP-9" in message for message in messages)
print("ok - failed and timed-out partial data is discarded; JSON schema is unchanged")
PY
fi

human_failure_status=0
human_failure=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture PATH="$failure_bin:$PATH" \
  "$fixture/arclith.sh" hardware 2>"$test_root/human-failure.err") || human_failure_status=$?
assert 'human report returns nonzero after rendering failed probes' test "$human_failure_status" -eq 1
case $human_failure in
  *'ARCLITH Hardware Report (read-only)'*'GPU:'*'Unavailable'*'Compatibility Recommendations (read-only)'*'GPU information could not be detected'*)
    printf 'ok - human report layout remains intact during probe failures\n' ;;
  *) printf 'not ok - human report was not rendered with sanitized values\n' >&2; exit 1 ;;
esac
assert 'human report keeps diagnostics off stdout' bash -c '[[ "$1" != *"[WARN] Hardware probe failed"* ]]' _ "$human_failure"

format_bin="$test_root/recommendation-format-bin"
mkdir -p "$format_bin"
real_awk=$(type -P awk)
cat > "$format_bin/awk" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  if [[ $arg == 'NF { count++ } END { print count + 0 }' ]] && \
     [[ ${FAIL_DISPLAY_COUNT:-false} == true ]]; then
    printf 'mock: display-count formatting failed\n' >&2
    exit 71
  fi
  if [[ $arg == /etc/os-release ]]; then
    printf 'Fixture OS\tarch\t\n'
    exit 0
  fi
done
exec "$REAL_AWK" "$@"
EOF
cat > "$format_bin/lspci" <<'EOF'
#!/usr/bin/env bash
printf '0000:01:00.0 VGA compatible controller: AMD fixture GPU\n'
EOF
cat > "$format_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
printf 'nvme0n1 1T fixture disk\n'
EOF
cat > "$format_bin/hyprctl" <<'EOF'
#!/usr/bin/env bash
printf 'Monitor DP-1 (fixture)\n'
EOF
cat > "$format_bin/hostname" <<'EOF'
#!/usr/bin/env bash
printf 'fixture-host\n'
EOF
cat > "$format_bin/uname" <<'EOF'
#!/usr/bin/env bash
case ${1-} in
  -r) printf 'fixture-kernel\n' ;;
  -m) printf 'x86_64\n' ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$format_bin/awk" "$format_bin/lspci" "$format_bin/lsblk" \
  "$format_bin/hyprctl" "$format_bin/hostname" "$format_bin/uname"

format_success_json=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture PATH="$format_bin:$PATH" REAL_AWK="$real_awk" \
  "$fixture/arclith.sh" hardware --json)
assert 'successful display-count formatting retains its recommendation' \
  bash -c '[[ "$1" == *"1 display output(s): DP-1"* ]]' _ "$format_success_json"

format_failure_status=0
format_failure_json=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture FAIL_DISPLAY_COUNT=true PATH="$format_bin:$PATH" \
  REAL_AWK="$real_awk" "$fixture/arclith.sh" hardware --json \
  2>"$test_root/recommendation-format-json.err") || format_failure_status=$?
assert 'display-count formatting failure returns a nonzero report status' \
  test "$format_failure_status" -eq 1
assert 'display-count formatting failure is diagnosed on stderr' \
  grep -Fq 'Hardware recommendation failed: could not count detected displays with awk (status 71)' \
    "$test_root/recommendation-format-json.err"
assert 'display-count formatter stderr is replaced by an actionable diagnostic' \
  bash -c '[[ $(wc -l < "$1") -eq 1 ]]' _ "$test_root/recommendation-format-json.err"
printf '%s\n' "$format_failure_json" > "$test_root/recommendation-format-failure.json"
if command -v python3 >/dev/null 2>&1; then
  python3 - "$test_root/recommendation-format-failure.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    report = json.load(source)
assert set(report) == {"system", "hardware", "recommendations"}
assert set(report["system"]) == {"operating_system", "kernel", "architecture", "hostname"}
assert set(report["hardware"]) == {
    "cpu", "memory", "gpu", "storage_disks", "desktop_compositor", "displays"
}
assert all(value is None or isinstance(value, str)
           for group in (report["system"], report["hardware"])
           for value in group.values())
assert all(set(item) == {"status", "message"}
           and isinstance(item["status"], str)
           and isinstance(item["message"], str)
           for item in report["recommendations"])
messages = [item["message"] for item in report["recommendations"]]
assert "Display count could not be determined because the recommendation formatter failed" in messages
assert "1 display output(s): DP-1" not in messages
assert any("curl" in message for message in messages), messages
print("ok - formatter failure still emits complete JSON with the unchanged schema and types")
PY
fi

format_human_status=0
format_failure_human=$(env -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY \
  HYPRLAND_INSTANCE_SIGNATURE=fixture FAIL_DISPLAY_COUNT=true PATH="$format_bin:$PATH" \
  REAL_AWK="$real_awk" "$fixture/arclith.sh" hardware \
  2>"$test_root/recommendation-format-human.err") || format_human_status=$?
assert 'human report retains nonzero status for display recommendation failure' \
  test "$format_human_status" -eq 1
case $format_failure_human in
  *'ARCLITH Hardware Report (read-only)'*'[Display]'*'Display count could not be determined'*'[Tools]'*'curl'*)
    printf 'ok - human report continues through later recommendation sections after formatter failure\n' ;;
  *) printf 'not ok - human report stopped before completing recommendation sections\n' >&2; exit 1 ;;
esac
assert 'human formatter diagnostics stay off stdout' \
  bash -c '[[ "$1" != *"Hardware recommendation failed"* ]]' _ "$format_failure_human"

if "$fixture/arclith.sh" hardware --bogus >"$test_root/invalid.out" 2>"$test_root/invalid.err"; then
  printf 'not ok - invalid hardware option was accepted\n' >&2; exit 1
fi
status=0
"$fixture/arclith.sh" hardware --bogus >/dev/null 2>"$test_root/invalid.err" || status=$?
assert 'invalid hardware option returns usage status 2' test "$status" -eq 2
if ! grep -Fq 'Unsupported hardware option' "$test_root/invalid.err"; then
  printf 'not ok - invalid option diagnostic is missing\n' >&2; exit 1
fi
printf 'ok - invalid option has a useful stderr diagnostic\n'

human_output=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION \
  -u WAYLAND_DISPLAY -u DISPLAY PATH="$minimal_bin" "$fixture/arclith.sh" hardware)
case $human_output in
  *'ARCLITH Hardware Report (read-only)'*'Compatibility Recommendations (read-only)'*)
    printf 'ok - human-readable hardware report remains available\n' ;;
  *) printf 'not ok - human-readable report format changed unexpectedly\n' >&2; exit 1 ;;
esac

printf 'All hardware JSON tests passed.\n'
