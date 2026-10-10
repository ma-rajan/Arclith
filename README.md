# ARCLITH

ARCLITH is a modular, Arch Linux and Hyprland-focused system setup and management CLI. It includes the command-line foundation, read-only hardware reporting, validated profiles and package plans, confirmed profile package installation, read-only configuration discovery and preview, and guarded deployment of a bundled Kitty configuration.

## Current features

- Interactive and command-based CLI entry point
- Version, help, and project information commands
- Read-only system and hardware report with conservative compatibility recommendations
  - Operating system, kernel, architecture, and hostname
  - CPU, memory, GPU, and physical storage disks
  - Active desktop/compositor and connected displays when safely available
  - Arch Linux / Arch-based environment, Wayland, Hyprland, GPU, display, and tool observations
- Graceful `Unavailable` fallbacks when an optional detection tool or value is absent
- Read-only discovery and validation of the minimal, developer, cyber, and full profile definitions
- Validated package installation for a selected profile, with dry-run and explicit confirmation
- Configuration component discovery, metadata/source validation, information, and read-only file preview
- Explicit, backed-up deployment of the bundled Kitty configuration
- Modular directories for hardware, installation, packages, profiles, configuration, and desktop components

Hardware detection and compatibility recommendations never install or remove packages, change configuration or system settings, make network requests, or reboot/shut down the machine. Package observations use only local command availability and, when available, read-only `pacman -Qq` queries.

## Usage

Run from the project root:

```bash
./arclith.sh help
./arclith.sh --version
./arclith.sh info
./arclith.sh hardware
./arclith.sh profile
./arclith.sh profile show cyber
./arclith.sh install cyber --dry-run
./arclith.sh install cyber
```

Running `./arclith.sh` without a command opens the interactive menu.

`hardware` first reports detected system information, then prints compatibility guidance. Recommendation labels distinguish `Detected`, `Recommended`, `Optional`, `Consider`, `Warning`, `Not detected`, and `Unavailable`; they are informational only and do not guarantee compatibility or make changes.

`profile` (or `profile list`) lists the four expected profiles, their descriptions, and validation status. Validation checks the profile definition fields and referenced package-list files, reporting missing or malformed definitions and returning a failure status when a profile is invalid. This phase only reads repository files: it does not install packages, invoke package managers, require `sudo`, or modify system or user configuration.

Run `./arclith.sh profile validate` to validate every discovered profile, or add a profile name to validate just that profile. Use `./arclith.sh profile info cyber` to inspect its metadata and package-list references. The package plan remains available through `./arclith.sh profile show cyber`.

## Package manifests and plans

Each profile definition in `profiles/<name>/profile.conf` lists its package category files through `PACKAGE_LISTS`. The existing files in `packages/` are the reusable manifests, with one package name per line and blank lines or `#` comments allowed:

- `base.txt` — core and system packages, shared by all profiles.
- `desktop.txt` — Hyprland desktop packages, used by `full`.
- `developer.txt` — development tools, used by `developer` and `full`.
- `cyber.txt` — cybersecurity tools, used by `cyber` and `full`.

Show a profile's plan with `./arclith.sh profile show <name>`, for example `./arclith.sh profile show cyber`. The planner checks profile metadata, package names, and referenced files. Malformed entries and duplicate package names make the profile invalid. A valid plan shows the package groups, package count, and manifest status.

Example:

```text
Package plan: cyber

Core / system:
  - base-devel
  - git
  - curl
Cybersecurity:
  - nmap
  - wireshark-qt

Total packages: 5
Manifest status: valid
```

Planning is read-only and works offline. It does not run `pacman`, `yay`, or `paru`, install or remove packages, require `sudo`, inspect hardware, or change system configuration. Hardware compatibility advice remains a separate read-only command; the planner does not add hardware-specific packages.

## Phase 5 — Package installation ✅

Install packages from a validated profile with:

```bash
./arclith.sh install cyber --dry-run
./arclith.sh install cyber
./arclith.sh install cyber --yes
```

`install <profile>` validates the profile, resolves the same package plan used by `profile show`, checks installed packages with read-only `pacman -Qq`, and separates installed packages from packages to add. `--dry-run` prints that summary and never invokes pacman's install operation. A normal install asks `Continue? [y/N]:` and proceeds only for `y` or `yes`; the default is no. Use `--yes` only when explicitly authorizing an unattended install.

Installation checks for pacman and an Arch Linux or Arch-based system. It runs `pacman -S --needed` only for missing packages, using `sudo` only when the CLI is not already running as root. Pacman's output is shown directly, and a failed command returns a failure status. Profile listing, validation, inspection, and package planning remain read-only and do not invoke sudo.

Profile planning describes package selections. Package installation changes installed packages only after a `y`/`yes` response or the explicit `--yes` flag. The separate configuration command described below is the only configuration deployment path. Package removal is not implemented.

## Phases 6–7 — Configuration discovery and guarded deployment

Configuration component metadata lives in the data-only `config/components.conf` registry. `core/config.sh` reads and validates this registry without sourcing it or executing configuration files. Registered targets are fixed home-relative component paths. Symlinked sources and unsafe target-parent paths are rejected during preview and apply.

These commands only inspect or preview. They never deploy files:

```bash
./arclith.sh config list
./arclith.sh config validate
./arclith.sh config info hyprland
./arclith.sh config preview hyprland
```

The supported component names are `hyprland`, `waybar`, `rofi`, `kitty`, `zsh`, and `wallust`. This checkout includes one real source, `core/configs/kitty/kitty.conf`, targeting `~/.config/kitty/kitty.conf`. The other components have no bundled sources and remain unavailable; no placeholder configurations are included. Preview reports whether the target is new, occupied, or unsafe and never creates directories, copies files, changes permissions, or edits source or home configuration.

Deploy the registered Kitty file explicitly:

```bash
./arclith.sh config apply kitty
```

Apply stages a text source beside its target, installs it with owner-only permissions, and creates any missing registered target directories with owner-only permissions. If a target file already exists, apply asks before replacing it. It refuses targets not owned by the current user. A confirmed replacement preserves the prior contents in a collision-safe `*.arclith-backup.*` file with mode `600`; declining leaves the target unchanged. `--yes` is an explicit confirmation for unattended use. Apply rejects missing, empty, binary, or unsafe sources; symlink targets and parents; and directories where files are expected. If a later rename fails, it attempts to restore files already replaced and retains backups. Shell path checks recheck destinations immediately before rename but cannot prevent another process from racing those checks. No automatic update or uninstall operation is implemented.

## Commands

| Command | Status | Description |
| --- | --- | --- |
| `install <profile> [--dry-run|--yes]` | Implemented | Install validated profile packages with dry-run and confirmation guards |
| `configure` | Planned | Configure ARCLITH modules |
| `config list` | Implemented | Discover supported configuration components and source availability |
| `config validate` | Implemented | Validate registry metadata and source directories (returns failure when sources are missing) |
| `config info <component>` | Implemented | Show one component's metadata and source status |
| `config preview <component>` | Implemented | Read-only source-to-target file and conflict preview |
| `config apply <component> [--yes]` | Implemented | Explicit deployment with overwrite confirmation, restrictive backups, and rollback |
| `hardware` | Implemented | Show read-only hardware information and compatibility recommendations |
| `profile`, `profile list`, `profile validate [name]`, `profile info <name>` | Implemented | Discover, inspect, and validate profile definitions and package lists |
| `profile show <name>` | Implemented | Show a read-only, de-duplicated package plan |
| `update` | Planned | Update ARCLITH-managed components |
| `uninstall` | Planned | Remove ARCLITH-managed components |
| `info` | Implemented | Show project information |
| `help`, `--help`, `-h` | Implemented | Show CLI usage |
| `--version`, `-v` | Implemented | Show the ARCLITH version |

## Project structure

```text
arclith.sh        Main CLI entry point
hardware/         Read-only hardware detection, recommendations, and vendor modules
install/          Confirmed package installation; bootstrap, update, and uninstall placeholders
config/           ARCLITH configuration
packages/         Package lists
profiles/         Minimal, developer, cyber, and full profiles
core/             Shared Bash modules and the bundled Kitty configuration source
docs/             Project documentation
```

## Planned next phases

- Profile application and management workflows
- Arch Linux / Hyprland installation and configuration workflows
- Safe deployment support for additional components after their real configuration sources are reviewed
