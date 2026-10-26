# Release validation checklist

Run this checklist from the repository root for each release candidate or release. Keep the command output and test log location with the release review. A failed or unavailable check is not a pass.

## Source and branch

- [ ] Confirm the intended branch and a clean worktree:

  ```bash
  git status --short --branch
  git branch --show-current
  git diff --check
  git diff --cached --check
  ```

- [ ] Record the intended commit. Fetch the remote and confirm the fetch exit status before relying on remote-tracking refs. Compare local and remote history; investigate any divergence before proceeding:

  ```bash
  git fetch origin
  git rev-parse HEAD
  git rev-parse origin/main
  git rev-list --left-right --count origin/main...HEAD
  ```

  If fetch fails or remote access is unavailable, report remote synchronization as unverified. Do not treat a prior `origin/main` value as current confirmation.

## Syntax and tests

- [ ] Run the shell syntax check:

  ```bash
  bash -n arclith.sh tests/*.sh
  ```

- [ ] Run every shell test script and record script-level pass/fail counts. Preserve the per-script logs and inspect failure output:

  ```bash
  log_dir=$(mktemp -d /tmp/arclith-release-tests.XXXXXX)
  passed=0
  failed=0
  for test_file in tests/*.sh; do
      log_file="$log_dir/$(basename "$test_file").log"
      if bash "$test_file" >"$log_file" 2>&1; then
          printf 'PASS %s\n' "$test_file"
          passed=$((passed + 1))
      else
          rc=$?
          printf 'FAIL %s (exit %s)\n' "$test_file" "$rc"
          tail -n 60 "$log_file"
          failed=$((failed + 1))
      fi
  done
  printf 'Passed: %s\nFailed: %s\nLogs: %s\n' "$passed" "$failed" "$log_dir"
  test "$failed" -eq 0
  ```

- [ ] Re-run `git diff --check` after final edits. Review the complete diff and confirm every changed file is intended.

## Version and release content

- [ ] Record the observed CLI version:

  ```bash
  ./arclith.sh --version
  ```

  The current implementation prints the hard-coded base version `0.1.0`; it does not read Git tags or add an `rc.N` suffix. A prerelease tag such as `v0.1.0-rc.2` therefore does not change the CLI output. The source establishes this behavior, but does not document whether omitting a prerelease suffix is intentional policy. Confirm the displayed version and proposed tag are appropriate for this release; handle any version-policy change separately from release documentation.

- [ ] Review release notes against implemented commands and tests. Label planned or unavailable work accurately; do not describe existing capabilities as newly implemented unless they are new in this release.
- [ ] Review transaction documentation for the current threat model: the lock coordinates cooperating Arclith processes; private metadata permissions restrict other UIDs subject to checked ownership and modes; checks can detect some external changes; non-cooperating same-UID writers can still race writable destinations. Post-mutation verification and `UNCERTAIN` journals are evidence, not proof that displaced data was preserved.
- [ ] Retain the disclosures that Arclith has no automatic crash recovery and performs no `fsync`-based durability guarantee for power loss. Do not claim stronger race prevention, recovery, or durability than the implementation and tests support.

## Tag and publication checks

- [ ] Before creating a tag, verify the exact intended commit and inspect its diff and release notes. Do not tag a moving branch name without resolving it to the reviewed commit:

  ```bash
  git show --stat --oneline "$intended_commit"
  git show "$intended_commit:$release_notes"
  ```

- [ ] Check both the local and published tag. Never move, recreate, or force-push an existing published tag. If it already exists, confirm that its peeled commit is the intended commit; if it differs, stop and resolve the release plan rather than changing the tag.

  ```bash
  git show --no-patch --format='%H %D' "$release_tag"
  git ls-remote --tags origin "refs/tags/$release_tag" "refs/tags/$release_tag^{}"
  ```

- [ ] Only after approval and commit verification, create a new annotated tag on the exact intended commit and push it without force. Verify the published tag resolves to that commit with `git ls-remote --tags origin` (including its peeled `^{}` line for annotated tags). Do not alter previously published tags.
- [ ] Verify tag publication separately from GitHub Release creation. A pushed Git tag does not itself establish that a GitHub Release exists. Create a GitHub Release only as a separate, explicitly authorized step after verifying the tag and release notes.
- [ ] Record final commit, tag, remote verification result, test counts, and any unavailable checks. Do not claim publication succeeded unless the command exit status and remote verification confirm it.
