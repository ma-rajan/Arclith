# Configuration transaction lifecycle design

This document records the Phase 40 audit of the existing configuration lifecycle and the later lock and journal work. Phase 41 added the lock helper, Phase 42 integrated it around configuration apply/apply-new, restore, uninstall, and prune transactions, and Phase 43 added journal storage and validation primitives. Production lifecycle mutations do not create or update journal records. Arclith does not implement automatic recovery after process termination or power loss.

Each mutating transaction acquires the per-home helper lock before entering its implementation and retains it through state reads, target changes, manifest writes, rollback, and return cleanup. The lower-level `config_state_save` function does not acquire a nested lock; its current mutation callers are inside these locked transactions. Read-only and dry-run commands remain unlocked. The helper serializes cooperating Arclith processes only; the baseline line references and lifecycle observations below remain tied to Phase 40.

The managed deployment state remains `~/.local/state/arclith/deployments.v1` (`ARCLITH_STATE|1`, mode 600 in a mode 700 directory). Its existing M/B records remain the authority for which files Arclith manages and which backups it trusts. The transaction journal described below records only a transaction summary; it is not authorization to modify a target or artifact.

## Existing lifecycle map

Line references below refer to `core/config.sh` and `arclith.sh` at the audited Phase 40 baseline (`b9f066d`). Error paths described as rollback are best-effort: each destination rename is atomic, but a sequence of destinations and the manifest is not one atomic transaction.

| Command / function | Validation and ordered writes | Failure, rollback, artifacts, concurrency |
|---|---|---|
| `config apply` and `config apply-new` → `config_apply` (`core/config.sh:1400-1753`; dispatch `1755-1775`) | The mutating path enters through `config_lock_execute` before registry/state and target precondition reads, then validates source files, relative paths, target ancestors and existing ownership/managed-file status. `apply-new --dry-run` remains unlocked and returns before writes. After confirmation, it creates missing target directories, copies existing targets to restrictive `.arclith-backup.*` files, stages sources as `.arclith-new.*`, installs targets, and updates the deployment manifest. | The lock remains held during staging, writes, rollback, and cleanup. Existing failure paths still provide best-effort rollback and may retain artifacts on incomplete cleanup/rollback. `config_state_save` is protected transitively by this transaction wrapper and does not acquire a nested lock. Other processes that do not use the helper can still race checks and writes. |
| `config restore` → `config_restore_backup` (`core/config.sh:1259-1398`; dispatch `1804-1811`) | The mutating path acquires the lock before loading state, then validates the backup ID/hash/mode and target before staging and replacement. It updates managed hash and backup state afterward. | The lock covers target mutation, manifest save, rollback, and cleanup. Existing rollback is best-effort, and no process-termination recovery is provided. Other processes that do not use the helper can still race checks and writes. |
| `config uninstall` and `config prune` → `config_uninstall_component` (`core/config.sh:1037-1257`; dispatch `1813-1835`) | Mutating execution acquires the lock before reading deployment state and target preconditions. Prune validates its source and selects stale records; uninstall validates the component and manifest. Dry-run remains unlocked. Mutating execution creates recovery copies, saves manifest state, removes verified unchanged targets, and saves the updated state. | The lock remains held through rollback and cleanup. Existing rollback is best-effort, and no process-termination recovery is provided. Other processes that do not use the helper can still race checks and writes. |
| `config_state_save` (`core/config.sh:597-654`) | Validates the state path and manifest ownership/mode, creates the private state directory, writes a mode 600 temp manifest, and atomically renames it. When replacing a manifest it first copies the old manifest to `.deployments-old.*`. | If rename reports failure it attempts old-manifest restoration and checks for a completed replacement. On unresolved rollback it retains and reports the old manifest path. It is called from other flows and has no independent lock. It does not fsync data or directory entries and therefore is not a power-loss durability guarantee. |
| `profile set-default` → `set_default_profile` (`arclith.sh:335-420`; dispatch around `510`) | Validates profile and `config/arclith.conf`, checks owner and path, asks for confirmation, stages a rewritten settings file, preserves mode/group, rechecks source hash, then backs up and replaces settings. Dry-run exits before writes. | This repository-file mutation is intentionally outside the per-home deployment lock because that lock protects `$HOME/.local/state/arclith`, not a project checkout. It remains unprotected from a second set-default writer; a separately scoped repository lock can be designed if needed. |

Other config commands (`list`, `validate`, `doctor`, `info`, `preview`, `status`, `updates`, `backups`, and `artifacts`) do not intentionally mutate deployment targets or state. `config artifacts` is read-only and scans a bounded set of validated target-adjacent and state-temp names (`core/config.sh:694-803`). It validates the existing manifest, never prints artifact contents, and is not integrated with the Phase 43 journal store; its current liveness message describes the absence of production journal integration. Its scan is incomplete for historical targets absent from both the manifest and current sources. Existing `config artifacts` tests snapshot filesystem metadata/content and repeat the command (`tests/test_config_artifacts.sh`).

## Phase 43 journal foundation

The deployment manifest format remains unchanged. Journal records are stored beneath `~/.local/state/arclith/transactions/<id>.v1`, one record per transaction, in a mode-700 directory. The identifier is 32 lowercase hexadecimal characters generated from 16 bytes of `/dev/urandom`; collisions are refused. Each mode-600 record has exactly seven ordered lines:

```text
ARCLITH_TXN|1
ID|<32 lowercase hex characters>
OPERATION|<apply|apply-new|restore|uninstall|prune>
COMPONENT|<lowercase component identifier>
STATE|<lifecycle state>
CREATED_UTC|<YYYY-MM-DDTHH:MM:SSZ>
UPDATED_UTC|<YYYY-MM-DDTHH:MM:SSZ>
```

The parser requires the exact line count and field order; validates the version, operation, component, identifier, state, canonical UTC timestamps, owner, mode, link count, file type, and a 1 KiB record-size limit; and rejects binary, malformed, or unsupported records. It parses data only and never evaluates or sources journal contents. It stores no paths, target contents, credentials, or free-form diagnostics. Invalid records are not repaired or deleted. Journal create and transition calls require the current Bash process to hold the existing per-home lock for the same canonical home. A single-record read validates one atomic snapshot and may be stale if a writer updates it concurrently; readers needing a consistent set of records must use the same lock.

### State machine

```text
PREPARING -> PREPARED -> APPLYING -> COMMITTING -> COMPLETE
     |           |          |          |
     +-----------+----------+----------+-> ROLLING_BACK -> ROLLED_BACK
     |           |          |          |                    |
     +-----------+----------+----------+--------------------+-> UNCERTAIN
```

Valid transitions are `PREPARING -> PREPARED`, `PREPARED -> APPLYING`, `APPLYING -> COMMITTING`, and `COMMITTING -> COMPLETE`. Each of those four nonterminal states may also transition to `ROLLING_BACK` or `UNCERTAIN`; `ROLLING_BACK` may transition to `ROLLED_BACK` or `UNCERTAIN`. `COMPLETE`, `ROLLED_BACK`, and `UNCERTAIN` are terminal. The primitives enforce these transitions but do not assert that operations actually completed or that rollback is safe.

Journal writes use a restrictive temporary file in the same transaction directory, validate the serialized temporary record, then call `mv -fT` to atomically replace the destination on the same filesystem. A failed serialization or rename removes only that write's temporary file and leaves the prior valid record in place. This relies on local Linux/GNU utility behavior and the existing cooperative per-home lock; it is not a defense against non-cooperating same-user filesystem races. No file or directory `fsync` is performed, so rename atomicity is not power-loss durability.

This phase adds no production lifecycle journal writes, target-level checkpoints, enumeration command, automatic recovery, replay, or journal cleanup. A journal state is descriptive metadata, not proof that a target should be overwritten, restored, or deleted. Production integration and recovery policy require later phases.

## Locking and concurrent operations

The helper uses Linux `flock` from util-linux as a kernel-held advisory lock. It fails closed if `flock` is unavailable. The minimum supported environment should be documented; never fall back to an unlocked mutation.

- Acquire one exclusive lock for the canonical `$HOME` deployment state before reading deployment state or target preconditions, and retain it through journal checkpoints, target and manifest changes, rollback, and final journal outcome. Mutating paths are `config apply`, `config apply-new` execution, `config restore`, `config uninstall`, and `config prune`. Dry-run/preview paths need no exclusive lock because they write nothing; their output is an observation that can become stale immediately.
- A writer should validate/create the mode 700 state directory, open a stable mode 600 regular lock file without following symlinks, then request a nonblocking exclusive `flock`. Contention returns a clear “another configuration operation is running” failure before target/state mutation. Lock acquisition errors, unsafe lock paths, and unavailable `flock` fail closed.
- Never unlink or replace the lock file: processes locking different inodes at the same pathname would no longer exclude one another. Kernel lock ownership, not file existence, PID, or age, determines whether a cooperating process currently holds it. A crash releases the OS lock but leaves journal/artifact state uncertain; it does not establish that rollback is safe. Explicit unlock failure is reported; closing the descriptor/process releases the kernel lock, while the journal outcome remains the source of operation status.
- The profile defaults writer is a separate repository-file operation, not a home deployment transaction. Keep it outside this lock unless a later design explicitly defines a repository-level lock.

`config artifacts` must not create a lock or journal. A possible read-only implementation can open an already existing regular lock file read-only and hold a nonblocking shared `flock` while it reads the journal and scans, without writing lock-file bytes; if an exclusive writer holds the lock, it reports “operation active; inventory deferred/incomplete” and does not race the scan. If no lock file exists, the path is unsafe, or shared locking is unavailable, it reports liveness as unknown and must not call a journal interrupted/abandoned. Before adopting even a transient shared lock, verify that the exact `flock`/FD behavior does not create or alter persistent state; the Phase 39 inventory currently has no lock interaction. If strict no-lock inventory semantics are retained instead, it can only report a potentially inconsistent snapshot and must label journal outcomes uncertain. Inventory output never authorizes cleanup or recovery.

## Lifecycle coverage and current evidence

| Proposed scenario | Existing evidence in repository | Phase 40 execution / gap |
|---|---|---|
| Two simultaneous config mutations | Apply/apply-new, restore, uninstall, and prune share one per-home transaction lock. | `tests/test_config_mutation_lock.sh` pauses one real apply at target installation and verifies a competing mutation fails before target or manifest changes. This does not cover non-cooperating processes or `profile set-default`. |
| Lock acquisition failure | Protected mutation wrappers fail before entering their operation when acquisition fails. | `tests/test_config_mutation_lock.sh` injects `flock` failure for apply, restore, uninstall, and prune; helper-level acquisition and release errors remain covered by `tests/test_config_lock.sh`. |
| Failure before first target mutation | Apply staging failure and cleanup are injected in `tests/test_config_deploy.sh`; state-manifest failure is tested after target installation and rollback. | Existing isolated command-level tests run; no journal exists to test checkpoint failure. |
| Failure after each target mutation / mixed target result | Existing apply rollback tests inject a later rename failure; prune tests inject a removal error after unlink. | Existing tests cover representative partial success, not every checkpoint or arbitrary kill timing. |
| Manifest-write / atomic replacement failure | Existing deployment, restore, and uninstall tests wrap `mv` to fail before/after replacement and inspect targets and manifest. | Existing isolated command-level tests run. Atomic rename is not equivalent to durable storage. |
| Partial rollback / rollback failure | Existing apply tests inject incomplete rollback; restore and prune test rollback paths. | Existing isolated tests exercise specific failures, not every rollback operation or a real storage fault. |
| Process termination between lifecycle steps | No journal or startup recovery mechanism exists. | Not simulated in Phase 40; function wrappers are not process-termination tests. |
| Missing/unsafe artifact and malformed metadata | Existing artifact/deploy tests cover missing or symlinked backups, malformed manifest, traversal and symlinks. | Journal parser cases are covered by `tests/test_config_journal.sh`; lifecycle artifact inventory remains journal-unaware. |
| Repeated operation / ID collision | Journal foundation generates 128-bit IDs and refuses existing IDs while holding the per-home lock. | `tests/test_config_journal.sh` covers sequential records and updates; production lifecycle integration remains future work. |
| Backward compatibility | Existing tests consume `ARCLITH_STATE|1` and tracked backup records. | Existing tests run unchanged; proposed journal must remain separate and must not alter this format. |
| Read-only inventory | `tests/test_config_artifacts.sh` compares snapshots, repeats output, and tests malformed/inaccessible state and symlink candidates. | Existing tests run; inventory remains journal-unaware and bounded. |

The current tests use temporary fixture homes and controlled command wrappers. Permission-denial assertions only run when the test process genuinely lacks traversal access; the local suite reported that access-denial case as available on this host. No desktop applications are needed for transaction tests.

## Recommended implementation sequence

1. Completed in Phase 43: define and test the versioned transaction summary record, state transitions, private storage, and atomic replacement behavior. Keep `deployments.v1` unchanged.
2. Add per-target checkpoint fields and a transaction protocol only when a later phase is ready to integrate journal updates with mutation and rollback behavior.
3. Integrate one-target apply first, then multi-target apply/apply-new, restore, and finally uninstall/prune, with failure injection at each checkpoint and explicit uncertainty reporting.
4. Extend `config artifacts` to validate and display journal metadata while retaining bounded scans, no content reads, no cleanup, and no authority to mutate. Test concurrent writer behavior and byte-for-byte state/filesystem immutability.
5. Run the full suite and compare legacy manifest/backup operations against current behavior. Document that process-kill and power-loss guarantees remain limited to verified journal state, not a claim of crash-safe rollback.
