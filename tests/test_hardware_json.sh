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

cat > "$mock_bin/lspci" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$mock_bin/lsblk" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
cat > "$mock_bin/hostname" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$mock_bin/hostname" "$mock_bin/lspci" "$mock_bin/lsblk"
unavailable_output=$(env -u HYPRLAND_INSTANCE_SIGNATURE -u XDG_CURRENT_DESKTOP -u DESKTOP_SESSION -u WAYLAND_DISPLAY -u DISPLAY PATH="$mock_bin:$PATH" "$fixture/arclith.sh" hardware --json)
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

human_output=$("$fixture/arclith.sh" hardware)
case $human_output in
  *'ARCLITH Hardware Report (read-only)'*'Compatibility Recommendations (read-only)'*)
    printf 'ok - human-readable hardware report remains available\n' ;;
  *) printf 'not ok - human-readable report format changed unexpectedly\n' >&2; exit 1 ;;
esac

printf 'All hardware JSON tests passed.\n'
