# ARCLITH

ARCLITH is a modular, Arch Linux and Hyprland-focused system setup and management CLI. The command-line foundation, read-only hardware report, and profile discovery and validation are implemented; system-changing workflows remain planned.

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
```

Running `./arclith.sh` without a command opens the interactive menu.

`hardware` first reports detected system information, then prints compatibility guidance. Recommendation labels distinguish `Detected`, `Recommended`, `Optional`, `Consider`, `Warning`, `Not detected`, and `Unavailable`; they are informational only and do not guarantee compatibility or make changes.

`profile` (or `profile list`) lists the four expected profiles, their descriptions, and validation status. Validation checks the profile definition fields and referenced package-list files, reporting missing or malformed definitions and returning a failure status when a profile is invalid. This phase only reads repository files: it does not install packages, invoke package managers, require `sudo`, or modify system or user configuration.

## Package manifests and plans

Each profile definition in `profiles/<name>/profile.conf` lists its package category files through `PACKAGE_LISTS`. The existing files in `packages/` are the reusable manifests, with one package name per line and blank lines or `#` comments allowed:

- `base.txt` — core and system packages, shared by all profiles.
- `desktop.txt` — Hyprland desktop packages, used by `full`.
- `developer.txt` — development tools, used by `developer` and `full`.
- `cyber.txt` — cybersecurity tools, used by `cyber` and `full`.

Show a profile's plan with `./arclith.sh profile show <name>`, for example `./arclith.sh profile show cyber`. The planner checks package names and referenced files, reports malformed entries and duplicates, and de-duplicates repeated packages in its output. It prints the profile, package groups, unique package count, and manifest validity.

Example:

```text
Package plan: cyber
    Valid

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

Planning is read-only and works offline. It does not run `pacman`, `yay`, or `paru`, install or remove packages, require `sudo`, inspect hardware, or change system configuration. Hardware compatibility advice remains a separate read-only command; the planner does not add hardware-specific packages. Package installation is intentionally not implemented yet.

## Commands

| Command | Status | Description |
| --- | --- | --- |
| `install` | Planned | Install ARCLITH |
| `configure` | Planned | Configure ARCLITH modules |
| `hardware` | Implemented | Show read-only hardware information and compatibility recommendations |
| `profile`, `profile list` | Implemented | Discover and validate profile definitions and package lists |
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
install/          Planned installation, update, and uninstall workflows
config/           ARCLITH configuration
packages/         Package lists
profiles/         Minimal, developer, cyber, and full profiles
core/             Hyprland and supporting desktop configuration
docs/             Project documentation
```

## Planned next phases

- Profile application and management workflows
- Arch Linux / Hyprland installation and configuration workflows
- Package management, update, and uninstall support
