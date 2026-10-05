# ARCLITH

ARCLITH is a modular, Arch Linux and Hyprland-focused system setup and management CLI. It is in early development: the command-line foundation and a read-only hardware report are implemented, while system-changing workflows remain planned.

## Current features

- Interactive and command-based CLI entry point
- Version, help, and project information commands
- Read-only system and hardware report with conservative compatibility recommendations
  - Operating system, kernel, architecture, and hostname
  - CPU, memory, GPU, and physical storage disks
  - Active desktop/compositor and connected displays when safely available
  - Arch Linux / Arch-based environment, Wayland, Hyprland, GPU, display, and tool observations
- Graceful `Unavailable` fallbacks when an optional detection tool or value is absent
- Modular directories for hardware, installation, packages, profiles, configuration, and desktop components

Hardware detection and compatibility recommendations never install or remove packages, change configuration or system settings, make network requests, or reboot/shut down the machine. Package observations use only local command availability and, when available, read-only `pacman -Qq` queries.

## Usage

Run from the project root:

```bash
./arclith.sh help
./arclith.sh --version
./arclith.sh info
./arclith.sh hardware
```

Running `./arclith.sh` without a command opens the interactive menu.

`hardware` first reports detected system information, then prints compatibility guidance. Recommendation labels distinguish `Detected`, `Recommended`, `Optional`, `Consider`, `Warning`, `Not detected`, and `Unavailable`; they are informational only and do not guarantee compatibility or make changes.

## Commands

| Command | Status | Description |
| --- | --- | --- |
| `install` | Planned | Install ARCLITH |
| `configure` | Planned | Configure ARCLITH modules |
| `hardware` | Implemented | Show read-only hardware information and compatibility recommendations |
| `profile` | Planned | Manage ARCLITH profiles |
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

- Profile management
- Arch Linux / Hyprland installation and configuration workflows
- Package management, update, and uninstall support
