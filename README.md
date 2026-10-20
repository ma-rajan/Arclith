# ARCLITH

ARCLITH is a modular Arch Linux setup and configuration management CLI. It provides read-only hardware reporting, validated profile and package planning, confirmed profile package installation, and configuration discovery, previews, guarded deployment, backups, and recovery diagnostics.

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
- Read-only comparison of validated profile package selections
- Validated package installation for a selected profile, with dry-run and explicit confirmation
- Configuration component discovery, metadata/source validation, information, and read-only file preview
- Guarded deployment of bundled Kitty, Rofi, and Waybar configurations, with backups and recovery diagnostics
- Versioned deployment state, managed-file status, and verified backup recovery
- Modular directories for hardware, installation, packages, profiles, configuration, and desktop components

Hardware detection and compatibility recommendations never install or remove packages, change configuration or system settings, make network requests, or reboot/shut down the machine. Package observations use only local command availability and, when available, read-only `pacman -Qq` queries.

## Usage

Run from the project root:

```bash
./arclith.sh help
./arclith.sh --version
./arclith.sh info
./arclith.sh hardware
./arclith.sh hardware --json
./arclith.sh profile
./arclith.sh profile show cyber
./arclith.sh profile default
./arclith.sh install cyber --dry-run
./arclith.sh install default --dry-run
./arclith.sh install cyber
```

Running `./arclith.sh` without a command opens the interactive menu.

`hardware` first reports detected system information, then prints compatibility guidance. Recommendation labels distinguish `Detected`, `Recommended`, `Optional`, `Consider`, `Warning`, `Not detected`, and `Unavailable`; they are informational only and do not guarantee compatibility or make changes.

Use `./arclith.sh hardware --json` for a machine-readable version of the same report. Its top-level keys are `system`, `hardware`, and `recommendations`; the first two contain the report fields, and each recommendation contains `status` and `message`. A detected value is a JSON string, while unavailable values are JSON `null`. For example:

```json
{
  "system": {
    "operating_system": "Arch Linux",
    "kernel": "6.12.1-arch1-1",
    "architecture": "x86_64",
    "hostname": "workstation"
  },
  "hardware": {
    "cpu": "Example CPU",
    "memory": "31.2 GiB",
    "gpu": null,
    "storage_disks": "nvme0n1 1T Example disk",
    "desktop_compositor": "Hyprland",
    "displays": "DP-1"
  },
  "recommendations": [
    {"status": "Detected", "message": "x86_64 architecture"},
    {"status": "Unavailable", "message": "GPU information could not be detected"}
  ]
}
```

JSON mode writes only the JSON document to stdout; command errors and usage diagnostics go to stderr. Missing optional utilities, absent display sessions, and successful probes with no matching information remain ordinary `Unavailable` values and do not by themselves fail the command. If an available probe fails, cannot access its input, or times out, ARCLITH discards any partial result, reports the failure on stderr, renders the report with the affected value unavailable, and exits nonzero. JSON keeps the schema shown above: unavailable or failed values are `null`, with probe failure conveyed through stderr and the exit status. Hardware reporting remains read-only; it does not install packages or change system or user configuration.

When `pacman` is available, compatibility recommendations use one read-only `pacman -Qq` snapshot for package presence. A successful query that omits a package means it is not detected. If the query fails, package-based recommendations are `Unavailable`, the report remains rendered, a diagnostic goes to stderr, and the command exits nonzero. If pacman is absent, package status remains `Unavailable` without failing the report.

`profile` (or `profile list`) lists the four expected profiles, their descriptions, and validation status. Validation checks the profile definition fields and referenced package-list files, reporting missing or malformed definitions and returning a failure status when a profile is invalid. This phase only reads repository files: it does not install packages, invoke package managers, require `sudo`, or modify system or user configuration.

Run `./arclith.sh profile validate` to validate every discovered profile, or add a profile name to validate just that profile. Use `./arclith.sh profile info cyber` to inspect its metadata and package-list references. The package plan remains available through `./arclith.sh profile show cyber`.

## Phase 15 — Read-only profile comparison

Compare two validated profile package plans with `./arclith.sh profile compare minimal developer`. The output separates shared packages from packages unique to each profile. Comparison reads only local profile and package manifests; it does not inspect installed packages or make system changes. Profile package application is already provided by `install <profile>` with dry-run and confirmation safeguards.

## Phase 16 — Configured profile defaults

`./arclith.sh profile default` reports the validated `PROFILE` selection from `config/arclith.conf`. Pass the reserved selector `default` to the existing installer to use that profile, such as `./arclith.sh install default --dry-run`. Defaults are parsed as data and never executed. Reading the default is read-only; installation keeps its existing dry-run and confirmation safeguards.

## Phase 17 — Safe default profile updates

Preview a default profile change with `./arclith.sh profile set-default developer --dry-run`. Without `--dry-run`, the command displays the old and new profile and asks for confirmation; `--yes` explicitly confirms unattended use. The selected profile must validate. On success, the command changes only the `PROFILE` setting, saves a collision-safe recovery copy beside `config/arclith.conf`, and atomically replaces the settings file. It refuses missing, symlinked, unreadable, or unowned defaults files.

## Phase 18 — Read-only configuration update detection

`./arclith.sh config updates [component]` compares tracked deployed files with their bundled sources. It reports available updates, local target edits, missing optional sources, and unsafe paths without changing configuration or deployment state. Apply remains an explicit, reviewed action through `config apply <component>`.

## Phase 19 — Discover newly bundled configuration files

`config updates [component]` also scans available component source trees for files without deployment records. A safe destination that does not exist is reported as `NEW FILE AVAILABLE`; an existing unmanaged destination is reported as `WARN UNMANAGED CONFLICT` and preserved. Symlinks, unsafe destination parents, and invalid source files are failures. The check never deploys files; use `config apply <component>` to review and explicitly confirm the component deployment.

## Phase 20 — Apply only newly bundled files

Use `config apply-new <component> --dry-run` to preview bundled files that have no deployment record and no destination file. `config apply-new <component>` asks for confirmation before installing eligible files; `--yes` confirms unattended use. Tracked files are preserved, with locally edited files identified; existing unmanaged targets are reported and preserved. Unsafe paths and invalid sources stop the operation before deployment. The existing `config apply <component>` workflow remains available for an explicitly confirmed full component deployment.

## Phase 21 — Prune stale managed files safely

When a tracked file has been removed from an available bundled source, use `config prune <component> --dry-run` to preview it. `config prune <component>` asks before removal, and `--yes` confirms unattended use. Only source-missing files recorded as managed are candidates. Unchanged targets receive verified recovery backups before removal; locally modified or unsafe targets are preserved. Pruning refuses to infer stale files when the component source is missing or unsafe. A target that cannot be inspected is preserved with its ownership record. `config uninstall` continues to remove a whole component.

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

Install packages from a validated profile, or use the configured default profile, with:

```bash
./arclith.sh install cyber --dry-run
./arclith.sh install default --dry-run
./arclith.sh install cyber
./arclith.sh install cyber --yes
```

`install <profile>` validates the profile, resolves the same package plan used by `profile show`, checks installed packages with read-only `pacman -Qq`, and separates installed packages from packages to add. `install default` resolves the same validated profile named by `PROFILE` in `config/arclith.conf`. `--dry-run` prints that summary and never invokes pacman's install operation. A normal install asks `Continue? [y/N]:` and proceeds only for `y` or `yes`; the default is no. Use `--yes` only when explicitly authorizing an unattended install.

Installation checks for pacman and an Arch Linux or Arch-based system. It runs `pacman -S --needed` only for missing packages, using `sudo` only when the CLI is not already running as root. Pacman's output is shown directly, and a failed command returns a failure status. If the package manager reports failure after installing some packages, those packages may remain installed; Arclith does not promise to roll back partial package-manager changes. Profile listing, validation, inspection, and package planning remain read-only and do not invoke sudo.

Profile planning describes package selections. Package installation changes installed packages only after a `y`/`yes` response or the explicit `--yes` flag. The separate configuration command described below is the only configuration deployment path. Package removal is not implemented.

## Configure planning and guarded execution

`configure` combines a validated profile package plan with read-only previews of bundled configuration sources:

```bash
./arclith.sh configure --help
./arclith.sh configure
./arclith.sh configure developer --components kitty,waybar --dry-run
./arclith.sh configure --components kitty --apply-config
./arclith.sh configure developer --install-packages --yes
./arclith.sh configure --components all --apply-config --install-packages
```

An omitted profile uses `PROFILE` from `config/arclith.conf`; an explicitly selected profile applies only to that invocation and never changes the configured default. The default component selection is Kitty, Rofi, and Waybar. Hyprland, Zsh, and Wallust are registered but their bundled sources are unavailable, so they are reported as not deployable; explicitly selecting one fails closed.

Without `--apply-config` or `--install-packages`, `configure` remains planning-only. `--apply-config` explicitly authorizes adding missing files with the configuration engine's preserving `new-only` policy; tracked files, local edits, and unmanaged conflicts are preserved. `--install-packages` separately authorizes installation of pending profile packages. One confirmation covers all requested actions unless `--yes` is supplied. `--dry-run` may be combined with either or both execution flags and never mutates. Package state is queried only when package installation is requested. Configuration deployment uses the existing per-home lock and transaction journals; a package operation and multiple component transactions cannot be rolled back atomically. Package managers may install some packages before reporting failure; Arclith stops configuration work but does not roll back those package changes. A failure stops later work and reports completed, failed, and unattempted operations.

## Phases 6–8 — Configuration discovery, guarded deployment, and recovery

Configuration component metadata lives in the data-only `config/components.conf` registry. `core/config.sh` reads and validates this registry without sourcing it or executing configuration files. Registered targets are fixed home-relative component paths. Symlinked sources and unsafe target-parent paths are rejected during preview and apply.

These commands only inspect or preview. They never deploy files:

```bash
./arclith.sh config list
./arclith.sh config validate
./arclith.sh config doctor
./arclith.sh config info hyprland
./arclith.sh config preview hyprland
```

The supported component names are `hyprland`, `waybar`, `rofi`, `kitty`, `zsh`, and `wallust`. This checkout bundles Waybar, Rofi, and Kitty sources:

| Component | Bundled source | Destination | Assumptions and limitations |
| --- | --- | --- | --- |
| Waybar | `core/configs/waybar/config.jsonc` | `~/.config/waybar/config.jsonc` | A small top bar using Waybar's built-in clock module. It does not assume Hyprland or external modules. |
| Rofi | `core/configs/rofi/config.rasi` | `~/.config/rofi/config.rasi` | Generic `drun` and `run` modes, without a theme, font, icon, or terminal override. |
| Kitty | `core/configs/kitty/kitty.conf` | `~/.config/kitty/kitty.conf` | Basic terminal defaults. |

Hyprland, Zsh, and Wallust remain registered but unavailable because this checkout has no bundled source for them. Preview reports whether the target is new, occupied, or unsafe and never creates directories, copies files, changes permissions, or edits source or home configuration.

`config validate` checks registry metadata, source directory safety, and that bundled source files are readable non-empty text. Its `source available` result does not certify component syntax. `tests/test_config_runtime.sh` runs static Waybar JSON checks and probes documented native checks in temporary fixture homes. Waybar has no documented parse-only CLI, so it is not started. The installed Kitty CLI has no documented noninteractive configuration parser, so Kitty is not started and its check is reported unavailable. Rofi's `-dump-config` is used only for safe inspection; it is not treated as syntax validation. The test probes `-rasi-validate` against valid and malformed fixtures and reports it unavailable if absent, crashing, or accepting malformed input. No desktop application is launched, and runtime rendering or behavior in a user's session remains unverified.

`config doctor` is a read-only environment check. It validates `config/arclith.conf`, the selected profile reference, component registry/source safety, and expected destination path safety and write access. Missing optional component sources are warnings; invalid references, unsafe sources, or blocked destination paths are failures. Exit status is zero when there are no failures (warnings may remain), one for detected errors, and two for usage errors. It never creates destination directories or changes files or permissions.

Deploy a bundled component explicitly, for example:

```bash
./arclith.sh config apply waybar
./arclith.sh config apply rofi
./arclith.sh config apply kitty
./arclith.sh config apply-new kitty --dry-run
./arclith.sh config apply-new kitty
./arclith.sh config prune kitty --dry-run
```

Apply stages a text source beside its target, installs it with owner-only permissions, and creates any missing registered target directories with owner-only permissions. If a target file already exists, apply asks before replacing it. It refuses targets not owned by the current user. A confirmed replacement preserves the prior contents in a collision-safe *.arclith-backup.* file with mode 600; declining leaves the target unchanged. --yes is an explicit confirmation for unattended use. Apply rejects missing, empty, binary, or unsafe sources; symlink targets and parents; and directories where files are expected. If a later rename fails, it attempts to restore files already replaced and retains backups. When rollback is incomplete, diagnostics identify surviving target paths and retained recovery backups. These safeguards handle reported operation failures; they do not guarantee recovery after abrupt process or system interruption. Shell path checks recheck destinations immediately before rename but cannot prevent another process from racing those checks.

Successful deployments are recorded in the versioned data-only manifest at ~/.local/state/arclith/deployments.v1. Its directory is mode 700, the manifest is mode 600, and it stores registered component names, home-relative target paths, content hashes, backup IDs, and recovery metadata. State is validated before use. config status reports each tracked file as unchanged, modified, missing, inaccessible, or unsafe. Only backup IDs present in valid state can be selected; the target path is derived from the registered component and manifest. Backup listing checks the saved hash and file safety.

`config updates [component]` compares tracked, unchanged targets with their corresponding bundled sources, and reports untracked files found in available component source trees. It reports current files and available source updates, warns when targets have local edits, unmanaged conflicts exist, or an optional source is unavailable, and fails on unsafe paths, inaccessible targets, or invalid sources. The command is read-only; it does not deploy, repair, or rewrite state. Review the report, then run the existing `config apply <component>` command to preview and confirm deployment. Warnings and detected updates return status zero; unsafe files or invalid state return one, and usage errors return two.

For example:

```bash
./arclith.sh config updates
./arclith.sh config updates kitty
```

Use these commands:

    ./arclith.sh config status
    ./arclith.sh config updates [component]
    ./arclith.sh config backups [component]
    ./arclith.sh config artifacts [component]
    ./arclith.sh config transactions
    ./arclith.sh config transactions 0123456789abcdef0123456789abcdef
    ./arclith.sh config restore <backup-id>

Restore prints the selected backup and target before changing anything. It asks before replacing a present target, saves that current target as another tracked backup, and keeps the selected backup in history. --yes explicitly confirms overwrite for unattended use. Backup history is never deleted automatically. Backups created before Phase 8 state tracking are not imported or trusted and therefore do not appear in this list.

`config artifacts [component]` is read-only. It validates deployment state, verifies tracked backup metadata, and checks for recognized staging, restore, rollback, and state-temporary names beside targets recorded in deployment state or present in currently available bundled sources. Symlinks are reported without following them; file contents are never printed. Untracked matches are uncertain candidates: they may belong to an active or interrupted operation, and their purpose cannot be established from the current state format. The command never removes, moves, restores, or records artifacts. Its bounded scan can miss artifacts for historical targets absent from both the manifest and current bundled sources. Phase 44 writes transaction and per-target journal records for `config apply` and mutating `config apply-new`, but this inventory does not enumerate or interpret those records and does not provide crash recovery or identify active operations conclusively.

`config transactions [transaction-id]` lists transaction IDs or inspects one transaction and its target checkpoint states. It validates transaction schema v1 and target schemas v1/v2, and reports `COMPLETE`, `IN_PROGRESS`, `UNCERTAIN`, `MALFORMED`, or `INCONSISTENT`. Findings include stable `reason=` codes: `UNSUPPORTED_SCHEMA`, `MALFORMED_RECORD`, `INVALID_IDENTIFIER`, `INVALID_TIMESTAMP`, `INVALID_TARGET_STATE`, `INVALID_TARGET_PATH`, `IDENTITY_MISMATCH`, `INCOMPATIBLE_STATES`, `INCONSISTENT_CHECKPOINTS`, `RECORD_NOT_FOUND`, `RECORD_INACCESSIBLE`, and `UNSAFE_STORAGE`. The code identifies the validation check that failed; it does not imply backup content or filesystem verification. Detail output reports journal timestamps, target state/original-presence/schema/update time, and `JOURNAL_ONLY`, `NOT_PERFORMED`, and `UNVERIFIED_LOCK_FREE` evidence labels. Target paths, backup IDs, and contents remain omitted. Exit status is 0 for a view without validation findings, 1 for malformed/inconsistent or missing records, 2 for invalid arguments, and 3 for inaccessible or unsafe journal storage. Inspection is read-only and lock-free; while a writer is active it may see a mixed snapshot. It does not inspect target or manifest contents, prove a mutation happened, or establish power-loss durability. The report states: “Target enumeration is incomplete by design: this report validates only records found; it cannot prove every target in the original operation was recorded.” A clean result applies only to recorded entries; the original target set may be incomplete.

The [transaction lifecycle audit](docs/transaction-lifecycle-design.md) documents the current write and rollback paths, the proposed journal state model, and known failure limits. `core/config.sh` provides an internal `config_lock_acquire <home>` / `config_lock_release` helper. It uses Linux `flock` from util-linux and `/proc` to verify the open lock inode at `~/.local/state/arclith/operation.lock`, validates the private state path, returns status 75 when another process holds the lock, and fails closed for unavailable `flock`, unavailable descriptor verification, or unsafe paths. The helper wraps configuration apply, apply-new execution, restore, uninstall, and prune transactions, including their deployment manifest writes and rollback. Dry-run/preview paths remain unlocked. The lock is released after each operation returns or when its owning process exits. A mutator must run in the same Bash process that acquired the lock; the helper checks ownership at release. Acquisition may create the private state directory and an empty mode-600 lock file; the file is never removed and its existence or contents do not indicate a held lock. `profile set-default` edits a repository file outside this per-home lock. The lock serializes cooperating Arclith commands only; it does not provide multi-file atomicity or crash recovery, and non-cooperating processes can still race filesystem changes.

Phase 43 added internal journal primitives, Phase 44 added v1 per-target checkpoints for `config apply` and mutating `config apply-new`, Phase 46 added v2 target checkpoints for `config restore`, and Phase 47 added v1 checkpoints for `config uninstall` and `config prune`. Version 1 records retain the historical `BACKUP` meaning; uninstall and prune use it for verified recovery copies. Their `ALREADY_ABSENT` outcome distinguishes an ownership entry whose target was already missing from a target actually deleted by the operation. Restore records keep selected source-backup IDs separate from rollback-backup IDs. Transaction and target records are stored under `~/.local/state/arclith/transactions/`, and journal writes require the matching per-home lock. A checkpoint describes the last state Arclith confirmed; it is not proof of recoverability. There is no automatic recovery or cleanup. Same-filesystem rename is atomic for a record replacement where supported, but no `fsync` is performed and power-loss durability is not guaranteed. `tests/test_config_journal.sh`, `tests/test_config_transaction_checkpoints.sh`, `tests/test_config_restore_checkpoints.sh`, and `tests/test_config_uninstall_prune_checkpoints.sh` exercise the schema and lifecycle boundaries in temporary homes.

Safely remove a deployed component with:

```bash
./arclith.sh config uninstall kitty --dry-run
./arclith.sh config uninstall kitty
./arclith.sh config uninstall kitty --yes
```

Uninstall is component-scoped and can remove only files with a valid managed-file record for that registered component. It checks each target against its recorded deployment hash immediately before removal. Modified files are preserved and remain tracked; missing files are reported and their stale ownership records are cleared. The normal command previews its actions and asks for confirmation; `--yes` explicitly confirms unattended removal. `--dry-run` performs no writes. Before deleting an unchanged file, ARCLITH saves a restrictive, state-tracked recovery backup. Existing backups are never removed. Uninstall does not remove directories. It refuses operation when trusted ownership state is absent or invalid. As with apply and restore, shell path checks cannot prevent a concurrent process from racing the final filesystem operation.

## Commands

| Command | Status | Description |
| --- | --- | --- |
| `install <profile|default> [--dry-run|--yes]` | Implemented | Install a validated named or configured default profile with confirmation guards |
| `configure [profile|default] [--components all|name,...] [--apply-config] [--install-packages] [--dry-run] [--yes]` | Implemented | Plan changes by default; execute only the explicitly requested package and/or preserving configuration actions |
| `config list` | Implemented | Discover supported configuration components and source availability |
| `config validate` | Implemented | Validate registry metadata and source directories (returns failure when sources are missing) |
| `config doctor` | Implemented | Read-only diagnostics for defaults, references, component sources, and destination paths |
| `config info <component>` | Implemented | Show one component's metadata and source status |
| `config preview <component>` | Implemented | Read-only source-to-target file and conflict preview |
| `config apply <component> [--yes]` | Implemented | Explicit deployment with overwrite confirmation, restrictive backups, and rollback |
| `config apply-new <component> [--dry-run|--yes]` | Implemented | Deploy only untracked bundled files to absent targets; preserves tracked and unmanaged files |
| `config prune <component> [--dry-run|--yes]` | Implemented | Remove only unchanged, tracked files no longer present in a valid bundled source; retain recovery backups |
| `config status [component]` | Implemented | Compare tracked target hashes and report unchanged, modified, missing, or unsafe |
| `config updates [component]` | Implemented | Read-only comparison of tracked targets and discovery of new bundled files; reports edits and conflicts |
| `config backups [component]` | Implemented | List state-verified recovery backups |
| `config artifacts [component]` | Implemented | Read-only bounded inventory of tracked backups and recognized untracked artifact candidates |
| `config transactions [transaction-id]` | Implemented | Read-only validation and inspection of transaction and target journals |
| `config restore <backup-id> [--yes]` | Implemented | Preview and restore a trusted backup, preserving a present target |
| `config uninstall <component> [--dry-run|--yes]` | Implemented | Remove only hash-verified managed files after preview/confirmation, retaining recovery backups |
| `hardware` | Implemented | Show read-only hardware information and compatibility recommendations |
| `profile`, `profile list`, `profile validate [name]`, `profile info <name>` | Implemented | Discover, inspect, and validate profile definitions and package lists |
| `profile show <name>` | Implemented | Show a read-only, de-duplicated package plan |
| `profile compare <left> <right>` | Implemented | Compare shared and profile-specific packages from validated plans |
| `profile default` | Implemented | Display the validated profile selected in ARCLITH defaults |
| `profile set-default <name> [--dry-run|--yes]` | Implemented | Preview or confirm a validated default profile update with recovery copy |
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

- Additional profile management workflows
- Arch Linux / Hyprland installation and configuration workflows
- Safe deployment support for additional components after their real configuration sources are reviewed
