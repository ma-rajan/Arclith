# Proposed release notes: Arclith v0.1.0-rc.2

**Status:** Proposed notes only. This document does not mean that `v0.1.0-rc.2` has been published.

## Capabilities

Arclith provides a command-line interface for Arch Linux setup and configuration management. Current capabilities include read-only hardware reporting, validated profile and package planning, explicitly confirmed package installation, configuration discovery and preview, guarded configuration deployment, backups, restore and managed removal, transaction journals, and read-only recovery diagnostics. `configure` can plan changes or, when explicitly requested, install packages and/or deploy selected configuration with confirmation.

Most capabilities listed above predate RC2. Since RC1, work has added the top-level `configure` planning workflow and guarded execution through the separately authorized `--apply-config` and `--install-packages` options. This summary describes the candidate's current scope; it does not present every listed capability as newly implemented. `update` and top-level `uninstall` remain unimplemented.

## Bundled configuration sources

The bundled sources available for deployment are Kitty, Rofi, and Waybar. Hyprland, Zsh, and Wallust are registered components, but their configuration sources are not bundled and cannot currently be deployed. Selecting an unavailable component fails closed.

## Safety behavior and limitations

- Package installation is explicitly requested and uses the package manager's `--needed` behavior for packages not already installed. A package manager can install some packages and then report failure. Those package changes may remain; Arclith does not automatically roll them back.
- Configuration deployment uses a per-home advisory lock, backups, transaction journals, validation, and guarded rollback. These mechanisms do not provide a single atomic transaction across packages or multiple configuration components.
- A non-cooperating process running as the same user can modify a staged configuration file after Arclith's final hash check and before the file is renamed into place. The lock coordinates cooperating Arclith operations only. This race is not eliminated, and Arclith is not race-free against non-cooperating writers.
- Arclith does not provide automatic crash recovery or guarantee power-loss durability. Journal records are diagnostic evidence of the last state Arclith confirmed; they do not guarantee that recovery is possible. Non-cooperating writers are not serialized by the advisory lock.

These notes summarize current behavior and its documented limits; they do not claim production readiness or imply that a release has been published.
