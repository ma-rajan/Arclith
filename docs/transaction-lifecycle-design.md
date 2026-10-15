# Configuration transaction lifecycle design

This document records the Phase 40 audit of the existing configuration lifecycle and later lock and journal work. Phase 41 added the lock helper, Phase 42 integrated it around apply/apply-new, restore, uninstall, and prune transactions, Phase 43 added journal primitives, and Phase 44 integrated transaction and target checkpoints with apply/apply-new. Restore, uninstall, and prune remain journal-unintegrated. Arclith does not implement automatic recovery after process termination or power loss.

Each mutating transaction acquires the per-home helper lock before entering its implementation and retains it through state reads, target changes, manifest writes, rollback, and return cleanup. The lower-level `config_state_save` function does not acquire a nested lock; its current mutation callers are inside these locked transactions. Read-only and dry-run commands remain unlocked. The helper serializes cooperating Arclith processes only; the baseline line references and lifecycle observations below remain tied to Phase 40.

The managed deployment state remains `~/.local/state/arclith/deployments.v1` (`ARCLITH_STATE|1`, mode 600 in a mode 700 directory). Its existing M/B records remain the authority for which files Arclith manages and which backups it trusts. The transaction journal described below records only a transaction summary; it is not authorization to modify a target or artifact.

## Existing lifecycle map

Line references below refer to `core/config.sh` and `arclith.sh` at the audited Phase 40 baseline (`b9f066d`). Error paths described as rollback are best-effort: each destination rename is atomic, but a sequence of destinations and the manifest is not one atomic transaction.

| Command / function | Validation and ordered writes | Failure, rollback, artifacts, concurrency |
|---|---|---|
| `config apply` and `config apply-new` → `config_apply` | The mutating path enters through `config_lock_execute` before registry/state and target precondition reads, then validates source files, relative paths, target ancestors and existing ownership/managed-file status. `apply-new --dry-run` remains unlocked and returns before writes. After confirmation, it writes the transaction and planned-target records before creating target directories, backups, or staged files. Each target records its original presence, backup ID when applicable, staging, mutation intent, applied, and rollback outcome around the existing mutations. | `COMMITTING` precedes the manifest save; `COMPLETE` follows it. The lock remains held during staging, checkpoints, manifest writes, rollback, and cleanup. Existing rollback remains best-effort. Journal write failure is reported; the last successful checkpoint may be stale. Other processes that do not use the helper can still race checks and writes. |
| `config restore` → `config_restore_backup` (`core/config.sh:1259-1398`; dispatch `1804-1811`) | The mutating path acquires the lock before loading state, then validates the backup ID/hash/mode and target before staging and replacement. It updates managed hash and backup state afterward. | The lock covers target mutation, manifest save, rollback, and cleanup. Existing rollback is best-effort, and no process-termination recovery is provided. Other processes that do not use the helper can still race checks and writes. |
| `config uninstall` and `config prune` → `config_uninstall_component` (`core/config.sh:1037-1257`; dispatch `1813-1835`) | Mutating execution acquires the lock before reading deployment state and target preconditions. Prune validates its source and selects stale records; uninstall validates the component and manifest. Dry-run remains unlocked. Mutating execution creates recovery copies, saves manifest state, removes verified unchanged targets, and saves the updated state. | The lock remains held through rollback and cleanup. Existing rollback is best-effort, and no process-termination recovery is provided. Other processes that do not use the helper can still race checks and writes. |
| `config_state_save` (`core/config.sh:597-654`) | Validates the state path and manifest ownership/mode, creates the private state directory, writes a mode 600 temp manifest, and atomically renames it. When replacing a manifest it first copies the old manifest to `.deployments-old.*`. | If rename reports failure it attempts old-manifest restoration and checks for a completed replacement. On unresolved rollback it retains and reports the old manifest path. It is called from other flows and has no independent lock. It does not fsync data or directory entries and therefore is not a power-loss durability guarantee. |
| `profile set-default` → `set_default_profile` (`arclith.sh:335-420`; dispatch around `510`) | Validates profile and `config/arclith.conf`, checks owner and path, asks for confirmation, stages a rewritten settings file, preserves mode/group, rechecks source hash, then backs up and replaces settings. Dry-run exits before writes. | This repository-file mutation is intentionally outside the per-home deployment lock because that lock protects `$HOME/.local/state/arclith`, not a project checkout. It remains unprotected from a second set-default writer; a separately scoped repository lock can be designed if needed. |

Other config commands (`list`, `validate`, `doctor`, `info`, `preview`, `status`, `updates`, `backups`, and `artifacts`) do not intentionally mutate deployment targets or state. `config artifacts` is read-only and scans a bounded set of validated target-adjacent and state-temp names (`core/config.sh:694-803`). It validates the existing manifest, never prints artifact contents, and does not enumerate or interpret transaction and target journals. Its scan is incomplete for historical targets absent from both the manifest and current sources. Existing `config artifacts` tests snapshot filesystem metadata/content and repeat the command (`tests/test_config_artifacts.sh`).

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

Phase 43 alone added no production lifecycle journal writes. Phase 44 adds the target checkpoint model and integrates it into apply/apply-new only; it adds no enumeration command, automatic recovery, replay, or journal cleanup. A journal state is descriptive metadata, not proof that a target should be overwritten, restored, or deleted.

## Phase 44 target checkpoints

The Phase 43 transaction record remains unchanged. Each selected apply/apply-new destination has one atomic mode-600 record in `transactions/<transaction-id>.targets/<six-digit-index>.v1`, beneath a mode-700 directory. The version 1 target record contains:

```text
ARCLITH_TARGET|1
TRANSACTION|<32 lowercase hex characters>
OPERATION|<apply|apply-new>
COMPONENT|<lowercase component identifier>
INDEX|<six decimal digits>
TARGET|<validated home-relative registered target>
ORIGINAL|<yes|no>
BACKUP|<8-character backup ID|->
STATE|<target lifecycle state>
UPDATED_UTC|<YYYY-MM-DDTHH:MM:SSZ>
```

The transaction ID and numeric index alone form the checkpoint path. The target path must pass the existing safe-relative-path and registered-component target checks. A backup reference is only an opaque validated Arclith backup ID; it does not grant authority to restore that artifact. The existing backup file, file checks, and rollback implementation remain authoritative.

Target states and allowed transitions are `PLANNED -> STAGED -> MUTATION_INTENT -> APPLIED`. `PLANNED` and `STAGED` can reach `NOT_MUTATED` or `UNCERTAIN`; `MUTATION_INTENT` can reach `APPLIED`, `ROLLBACK_INTENT`, `NOT_MUTATED`, or `UNCERTAIN`; `APPLIED` can reach `ROLLBACK_INTENT` or `UNCERTAIN`; and `ROLLBACK_INTENT` can reach `ROLLED_BACK` or `UNCERTAIN`. `ROLLED_BACK`, `NOT_MUTATED`, and `UNCERTAIN` are terminal states. `NOT_MUTATED` means Arclith did not confirm performing the target replacement; it is not a statement about changes by non-cooperating processes. A `MUTATION_INTENT` left on disk can mean the rename did or did not happen. Target records must agree with their transaction's ID, operation, and component and are updated under the existing per-home lock.

For apply/apply-new, the transaction and all `PLANNED` target records are written before target parent creation, staging, or backup creation. A verified existing-target backup ID is attached while still `PLANNED`. After source staging, the target becomes `STAGED`. The transaction advances to `PREPARED` and `APPLYING`; each `MUTATION_INTENT` is persisted before its destination rename, and `APPLIED` only after the rename reports success. `COMMITTING` is written after every target is confirmed applied and before the deployment manifest update; `COMPLETE` is written only after that manifest save succeeds.

On a failure before any replacement, staged records are marked `NOT_MUTATED` where those writes succeed. After partial replacement, existing rollback runs in reverse order. It writes `ROLLBACK_INTENT` before restoring/removing a target and `ROLLED_BACK` only after the existing rollback path confirms success. A rollback failure, checkpoint write failure, or unclear outcome leaves `UNCERTAIN` when that update can be persisted. If journal storage itself is unavailable, the last saved checkpoint can remain stale; the command reports the failure and does not claim a later checkpoint succeeded. A process kill can occur between any filesystem action and checkpoint, so neither target records nor the transaction record constitute a recovery protocol.

Only apply/apply-new are integrated because they share an established all-target staging and reverse-order rollback flow. Restore, uninstall, and prune have distinct state/target ordering and remain unjournaled. Preview and dry-run return before journal creation. The existing lock remains held through transaction checkpoints, manifest writes, and rollback. The focused tests inject failures before mutation, during target completion and transaction completion writes, and during rollback; they also cover multi-target success and apply-new. These are command-level tests, not process-kill or power-loss simulations.

## Locking and concurrent operations

The helper uses Linux `flock` from util-linux as a kernel-held advisory lock. It fails closed if `flock` is unavailable. The minimum supported environment should be documented; never fall back to an unlocked mutation.

- Acquire one exclusive lock for the canonical `$HOME` deployment state before reading deployment state or target preconditions, and retain it through journal checkpoints, target and manifest changes, rollback, and final journal outcome. Mutating paths are `config apply`, `config apply-new` execution, `config restore`, `config uninstall`, and `config prune`. Dry-run/preview paths need no exclusive lock because they write nothing; their output is an observation that can become stale immediately.
- A writer should validate/create the mode 700 state directory, open a stable mode 600 regular lock file without following symlinks, then request a nonblocking exclusive `flock`. Contention returns a clear “another configuration operation is running” failure before target/state mutation. Lock acquisition errors, unsafe lock paths, and unavailable `flock` fail closed.
- Never unlink or replace the lock file: processes locking different inodes at the same pathname would no longer exclude one another. Kernel lock ownership, not file existence, PID, or age, determines whether a cooperating process currently holds it. A crash releases the OS lock but leaves journal/artifact state uncertain; it does not establish that rollback is safe. Explicit unlock failure is reported; closing the descriptor/process releases the kernel lock, while the journal outcome remains the source of operation status.
- The profile defaults writer is a separate repository-file operation, not a home deployment transaction. Keep it outside this lock unless a later design explicitly defines a repository-level lock.

`config artifacts` must not create a lock or journal. A possible read-only implementation can open an already existing regular lock file read-only and hold a nonblocking shared `flock` while it reads the journal and scans, without writing lock-file bytes; if an exclusive writer holds the lock, it reports “operation active; inventory deferred/incomplete” and does not race the scan. If no lock file exists, the path is unsafe, or shared locking is unavailable, it reports liveness as unknown and must not call a journal interrupted/abandoned. Before adopting even a transient shared lock, verify that the exact `flock`/FD behavior does not create or alter persistent state; the Phase 39 inventory currently has no lock interaction. If strict no-lock inventory semantics are retained instead, it can only report a potentially inconsistent snapshot and must label journal outcomes uncertain. Inventory output never authorizes cleanup or recovery.

## Lifecycle coverage and current evidence

| Proposed scenario | Existing evidence in repository | Audit finding / current gap |
|---|---|---|
| Two simultaneous config mutations | Apply/apply-new, restore, uninstall, and prune share one per-home transaction lock. | `tests/test_config_mutation_lock.sh` pauses one real apply at target installation and verifies a competing mutation fails before target or manifest changes. This does not cover non-cooperating processes or `profile set-default`. |
| Lock acquisition failure | Protected mutation wrappers fail before entering their operation when acquisition fails. | `tests/test_config_mutation_lock.sh` injects `flock` failure for apply, restore, uninstall, and prune; helper-level acquisition and release errors remain covered by `tests/test_config_lock.sh`. |
| Failure before first target mutation | Apply staging failure and cleanup are injected in `tests/test_config_deploy.sh`; target rename and mutation-intent failures are injected in `tests/test_config_transaction_checkpoints.sh`. | Isolated tests confirm no target is claimed applied before its rename and retain the last persisted checkpoint on journal failure. |
| Failure after target mutation / mixed target result | Apply rollback tests inject a later rename failure; target-completion checkpoint failure and rollback failure are injected in `tests/test_config_transaction_checkpoints.sh`. | The selected apply/apply-new path records APPLIED only after the rename reports success; other lifecycle paths remain unjournaled. |
| Manifest-write / atomic replacement failure | Existing deployment, restore, and uninstall tests wrap `mv` to fail before/after replacement and inspect targets and manifest. | Existing isolated command-level tests run. Atomic rename is not equivalent to durable storage. |
| Partial rollback / rollback failure | Existing apply tests inject incomplete rollback; restore and prune test rollback paths. | Existing isolated tests exercise specific failures, not every rollback operation or a real storage fault. |
| Process termination between lifecycle steps | Apply/apply-new write transaction and per-target checkpoints, but no startup recovery mechanism exists. | Not simulated; checkpoints can lag a filesystem action and do not establish crash-safe rollback. |
| Missing/unsafe artifact and malformed metadata | Existing artifact/deploy tests cover missing or symlinked backups, malformed manifest, traversal and symlinks. | Journal parser cases are covered by `tests/test_config_journal.sh`; lifecycle artifact inventory remains journal-unaware. |
| Repeated operation / ID collision | Journal foundation generates 128-bit IDs and refuses existing IDs while holding the per-home lock. | `tests/test_config_journal.sh` covers sequential records and updates; production lifecycle integration remains future work. |
| Backward compatibility | Existing tests consume `ARCLITH_STATE|1` and tracked backup records. | Existing tests run unchanged; proposed journal must remain separate and must not alter this format. |
| Read-only inventory | `tests/test_config_artifacts.sh` compares snapshots, repeats output, and tests malformed/inaccessible state and symlink candidates. | Existing tests run; inventory remains journal-unaware and bounded. |

The current tests use temporary fixture homes and controlled command wrappers. Permission-denial assertions only run when the test process genuinely lacks traversal access; the local suite reported that access-denial case as available on this host. No desktop applications are needed for transaction tests.

## Recommended implementation sequence

1. Completed in Phase 43: define and test the versioned transaction summary record, state transitions, private storage, and atomic replacement behavior. Keep `deployments.v1` unchanged.
2. Completed in Phase 44: add target checkpoint records and integrate apply/apply-new with their existing staging and rollback protocol.
3. In a later phase, design checkpoint ordering separately for restore, uninstall, and prune before integrating those mutation paths.
4. Extend `config artifacts` to validate and display journal metadata while retaining bounded scans, no content reads, no cleanup, and no authority to mutate. Test concurrent writer behavior and byte-for-byte state/filesystem immutability.
5. Define recovery policy only after journal integration is complete; process-kill and power-loss guarantees remain limited, and the current records do not authorize replay or cleanup.
