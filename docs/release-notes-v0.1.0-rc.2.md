# Arclith v0.1.0-rc.2 — Release notes

## Capabilities

Arclith provides a command-line interface for Arch Linux setup and configuration management. Current capabilities include read-only hardware reporting, validated profile and package planning, explicitly confirmed package installation, configuration discovery and preview, guarded configuration deployment, backups, restore and managed removal, transaction journals, and read-only recovery diagnostics. `configure` can plan changes or, when explicitly requested, install packages and/or deploy selected configuration with confirmation.

Most capabilities listed above predate RC2. Since RC1, work has added the top-level `configure` planning workflow and guarded execution through the separately authorized `--apply-config` and `--install-packages` options. This summary describes the candidate's current scope; it does not present every listed capability as newly implemented. `update` and top-level `uninstall` remain unimplemented.

## Bundled configuration sources

The bundled sources available for deployment are Kitty, Rofi, and Waybar. Hyprland, Zsh, and Wallust are registered components, but their configuration sources are not bundled and cannot currently be deployed. Selecting an unavailable component fails closed.

## Safety behavior and limitations

- Package installation is explicitly requested and uses the package manager's `--needed` behavior for packages not already installed. A package manager can install some packages and then report failure. Those package changes may remain; Arclith does not automatically roll them back.
- Configuration deployment uses a per-home advisory lock, backups, transaction journals, validation, and guarded rollback. These mechanisms do not provide a single atomic transaction across packages or multiple configuration components.
- `tests/test_config_staged_rename_race.sh` deterministically changes staged bytes or replaces the staged inode after its final check and before rename. Post-rename identity and content verification detects the injected mismatch, but the changed file has already reached the target; the operation fails, preserves the conflicting target and recovery copy, and records uncertainty. This test does not cover a separate destination race: a non-cooperating same-user process can change the target after Arclith's final target check and before ordinary `mv`, which can replace that intervening data without a mismatch in the staged file. The lock coordinates cooperating Arclith operations only. Neither race is fully eliminated, and Arclith is not race-free against non-cooperating writers.
- Arclith does not provide automatic crash recovery or guarantee power-loss durability. Journal records are diagnostic evidence of the last state Arclith confirmed; they do not guarantee that recovery is possible. Non-cooperating writers are not serialized by the advisory lock.

These notes summarize current behavior and documented limits; they do not claim production readiness.
