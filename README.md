# ARCLITH

**Modular Arch Linux Configuration Framework.**

ARCLITH is designed to provide a structured and automated way to install, configure, and manage an Arch Linux environment.

## Planned Features

- Automated installation
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

The ARCLITH command-line foundation is implemented in the executable `arclith.sh` entry point. The CLI provides the following command paths:

- `install`, `configure`, `profile`, `update`, and `uninstall` are available as planned command paths; their underlying functionality is not implemented yet.
- `hardware` performs the read-only hardware and system detection described below.
- `info`
- `help`
- `--help`
- `--version`

The interactive menu and invalid-command handling have been tested. Bash syntax validation has passed, and non-destructive command testing has been performed.

### Phase 2 — Hardware & System Detection ✅

ARCLITH now provides read-only detection for:

- System and OS information
- CPU model and logical CPU count
- Total and available memory
- Root filesystem storage usage
- Network interface names and operational states
- Display connectors, with resolution only when reliably available
- Laptop, desktop, virtual machine, or unknown device classification
- GPU vendor and model summaries, including multiple detected GPUs

Run the detector through the CLI:

```bash
./arclith.sh hardware
```

The `hardware` command is detection-only: it does not install packages or modify system, display, network, driver, or service configuration.

### Phase 4 — Profile Discovery & Validation ✅

Profiles live under `profiles/<name>/profile.conf`. Manifests use simple `key=value` fields (`name`, `description`, `version`, and comma-separated `packages` file references). Package contents remain in the shared, one-package-per-line files under `packages/`; manifests only describe and reference them.

Available profiles are `minimal`, `developer`, `cyber`, and `full`. Inspect them with:

```bash
./arclith.sh profile list
./arclith.sh profile validate
./arclith.sh profile validate cyber
./arclith.sh profile info cyber
```

Profile commands only read profile metadata and package lists. They do not install packages, require root access, or modify system or desktop configuration. Validation reports missing or malformed fields, mismatched profile names, invalid or duplicate package entries, and missing package references.

## Roadmap

- Phase 1 — CLI Foundation — ✅
- Phase 2 — Hardware Detection — ✅
- Phase 3 — Hardware Compatibility Recommendations — ✅
- Phase 4 — Profile Discovery & Validation — ✅
- Phase 5 — Package Management — ⏳
- Phase 6 — Hyprland Configuration — ⏳
- Phase 7 — Developer Profile — ⏳
- Phase 8 — Cybersecurity Profile — ⏳
- Phase 9 — Full Profile — ⏳
- Phase 10 — Backup & Restore — ⏳
- Phase 11 — Safe Uninstall — ⏳

## Development Status

ARCLITH is in active development. The CLI foundation, read-only hardware detection, and read-only profile discovery and validation are implemented. Package installation and configuration deployment remain future work.

## Philosophy

ARCLITH is guided by these principles:

- **Modular** — components can be developed, configured, and maintained independently.
- **Safe** — system changes should be deliberate and avoid unnecessary risk.
- **Transparent** — actions and configuration decisions should be easy to inspect.
- **Reproducible** — a system setup should be consistent and repeatable.
- **Arch-native** — workflows should respect Arch Linux tools and conventions.
- **Extensible** — the framework should support future modules and profiles.
