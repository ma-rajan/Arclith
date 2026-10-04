# ARCLITH

**Modular Arch Linux Configuration Framework.**

ARCLITH is designed to provide a structured and automated way to install, configure, and manage an Arch Linux environment.

## Planned Features

- Automated installation
- Hardware detection
- Modular configurations
- Hyprland desktop environment
- Multiple system profiles
- Developer profile
- Cybersecurity profile
- Full profile
- Package management
- Update and uninstall support
- Safe and modular system management

## Current Progress

### Phase 1 — CLI Foundation ✅

The ARCLITH command-line foundation is implemented in the executable `arclith.sh` entry point. The following command paths have been implemented and tested:

- `install`
- `configure`
- `hardware`
- `profile`
- `update`
- `uninstall`
- `info`
- `help`
- `--help`
- `--version`

The interactive menu and invalid-command handling have been tested. Bash syntax validation has passed, and non-destructive command testing has been performed.

### Phase 2 — Hardware & System Detection 🚧

The next phase will add structured detection for:

- CPU
- GPU
- RAM
- Storage
- Network interfaces
- Displays
- Laptop or desktop systems
- Virtual machines
- System and kernel information

## Roadmap

- Phase 1 — CLI Foundation — ✅
- Phase 2 — Hardware Detection — 🚧
- Phase 3 — System Configuration — ⏳
- Phase 4 — Profile System — ⏳
- Phase 5 — Package Management — ⏳
- Phase 6 — Hyprland Configuration — ⏳
- Phase 7 — Developer Profile — ⏳
- Phase 8 — Cybersecurity Profile — ⏳
- Phase 9 — Full Profile — ⏳
- Phase 10 — Backup & Restore — ⏳
- Phase 11 — Safe Uninstall — ⏳

## Development Status

ARCLITH is in active development. The CLI foundation is implemented and tested, and Hardware & System Detection is the next phase.

## Philosophy

ARCLITH is guided by these principles:

- **Modular** — components can be developed, configured, and maintained independently.
- **Safe** — system changes should be deliberate and avoid unnecessary risk.
- **Transparent** — actions and configuration decisions should be easy to inspect.
- **Reproducible** — a system setup should be consistent and repeatable.
- **Arch-native** — workflows should respect Arch Linux tools and conventions.
- **Extensible** — the framework should support future modules and profiles.
