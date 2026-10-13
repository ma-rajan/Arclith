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
