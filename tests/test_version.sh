#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/arclith-version-tests.XXXXXX")
trap 'rm -rf -- "$test_root"' EXIT

mapfile -t version_values < <(sed -n 's/^readonly ARCLITH_VERSION="\([^"]*\)"$/\1/p' "$repo_root/arclith.sh")
if [[ ${#version_values[@]} -ne 1 || -z ${version_values[0]} ]]; then
  printf 'not ok - expected exactly one non-empty ARCLITH_VERSION in arclith.sh\n' >&2
  exit 1
fi
printf 'ARCLITH %s\n' "${version_values[0]}" > "$test_root/expected.out"

check_version_output() {
  local label=$1 script=$2 flag=$3 workdir=${4:-$repo_root} output="$test_root/$1.out"
  if ! (
    cd -- "$workdir"
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR
    GIT_CEILING_DIRECTORIES=$test_root "$script" "$flag"
  ) > "$output" 2>&1; then
    printf 'not ok - %s returned failure for %s\n' "$label" "$flag" >&2
    cat "$output" >&2
    return 1
  fi
  if [[ $(grep -Fxc -- "ARCLITH ${version_values[0]}" "$output") -ne 1 ]] \
    || ! tail -n 1 "$output" | cmp -s -- "$test_root/expected.out" -; then
    printf 'not ok - %s version line for %s did not exactly match the source version\n' "$label" "$flag" >&2
    diff -u --label expected "$test_root/expected.out" --label actual <(tail -n 1 "$output") >&2 || true
    return 1
  fi
  printf 'ok - %s %s reports the source-controlled version line exactly\n' "$label" "$flag"
}

check_version_output 'checkout' "$repo_root/arclith.sh" --version
check_version_output 'checkout' "$repo_root/arclith.sh" -v

standalone_dir="$test_root/standalone"
mkdir -- "$standalone_dir"
cp -- "$repo_root/arclith.sh" "$standalone_dir/arclith.sh"
chmod +x -- "$standalone_dir/arclith.sh"
if [[ -e $standalone_dir/.git || $(find "$standalone_dir" -mindepth 1 -maxdepth 1 | wc -l) -ne 1 ]]; then
  printf 'not ok - standalone fixture contains files other than arclith.sh\n' >&2
  exit 1
fi
check_version_output 'standalone copy' "$standalone_dir/arclith.sh" --version "$standalone_dir"
check_version_output 'standalone copy' "$standalone_dir/arclith.sh" -v "$standalone_dir"
