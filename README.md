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

## Commands

| Command | Status | Description |
| --- | --- | --- |
| `install` | Planned | Install ARCLITH |
| `configure` | Planned | Configure ARCLITH modules |
| `hardware` | Implemented | Show read-only hardware information and compatibility recommendations |
| `profile`, `profile list` | Implemented | Discover and validate profile definitions and package lists |
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
