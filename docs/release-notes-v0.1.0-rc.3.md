# Arclith v0.1.0-rc.3 — Release candidate notes

This is a release candidate for review and validation, not a stable release. These notes describe the current candidate scope and changes since RC2; they do not claim that all listed capabilities are new in RC3.

## Changes since RC2

- The application version is explicitly set to `0.1.0-rc.3`. The version command reports the source-controlled value and does not derive it from Git tags.
- Added regression coverage for `--version` and `-v`, including execution of a standalone copy without project files or Git metadata.
- Expanded release validation guidance and clarified the documented filesystem threat model, including the unresolved same-UID destination race.

No new configuration deployment or package-management capability is claimed for RC3.

## Supported scope

Arclith is a Bash command-line tool for Arch Linux and Arch-based systems. It provides read-only hardware reporting, profile validation and package planning, explicitly confirmed profile package installation through pacman, and configuration discovery, preview, guarded deployment, backup, restore, managed removal, and read-only transaction diagnostics. The bundled deployable configuration sources are Kitty, Rofi, and Waybar. The project is used from its source checkout; the profile `install` command installs selected packages and is not an installer for the Arclith application itself.

The top-level `update` and `uninstall` commands remain unimplemented. Bootstrap, update, and uninstall scripts under `install/` remain placeholders. Hyprland, Zsh, and Wallust are registered components, but their configuration sources are not bundled and cannot currently be deployed.

## Safety and durability limitations

- The per-home advisory lock coordinates cooperating Arclith processes only. Checks can detect some external changes, but a non-cooperating process with the same UID can change a writable destination between validation and mutation. Arclith does not guarantee race-free mutation or preservation of data displaced in that window.
- Staged-file identity and content checks, post-mutation verification, rollback checks, and `UNCERTAIN` journals provide detection or evidence at their verification points. They do not prove that unexpected data was preserved or that a transaction can be recovered.
- Arclith has no automatic crash recovery and makes no `fsync`-based power-loss durability guarantee. Package-manager failures can leave packages partially installed; Arclith does not automatically roll those changes back.
- Configuration operations are not one atomic transaction across multiple files, components, or package changes.

## Candidate validation

The RC3 source was checked with `bash -n arclith.sh tests/*.sh`; both version flags were checked against `ARCLITH 0.1.0-rc.3`; `tests/test_version.sh` passed; all 23 shell test scripts passed; and `git diff --check` passed. This candidate is published as the GitHub pre-release `v0.1.0-rc.3`; the checks above record validation performed during its preparation.
