# Upstream amendments to aemi, AemiJSON, AemiProtobuf and analyzerkit: status

Litmus 0.2.0-dev first worked around 21 gaps in its dependencies. On 2026-11-02 they were implemented upstream and
adopted here (ADR 0006). Revisions now pinned:

| Package | Revision | Record |
| --- | --- | --- |
| aemi | `6ed7fb7` | aemi ADR 0028, diary 2026-11-02-01 |
| AemiRegex | `cc7deea` | pin only |
| AemiJSON | `25f59b9` | diary 2026-11-02-01 |
| AemiProtobuf | `edede35` | pin only |
| analyzerkit | `f339e8f` | analyzerkit ADR-0030, ADR-0031, diary 2026-11-02-01 |

The six family analyzers (arcleak, deadwood, dolly, fcheck, modeler, swift-search) were built and tested against these
revisions without a source change.

## aemi

| Id | Change | Litmus now |
| --- | --- | --- |
| AE-1 | `PosixFile.write(_:at:)`, `read(at:count:)` over `[UInt8]` | the journal has no `unsafe` |
| AE-2 | `PosixFile(creatingExclusively:)`, `AtomicFile.replace` (sync, rename, directory sync) | journal created with `O_EXCL`; checkpoints durable |
| AE-3 | `FileCopy.copy` (`clonefile`, else read and write) | snapshots clone on APFS (through `TreeSnapshot`) |
| AE-4 | `DirectoryWalk.cancellableWalk`; `isCancelled` documented as off-task | uses `TreeSnapshot` |
| AE-5 | `forEachConcurrently` (results in completion order, on the caller's task) | each first-run verdict journalled as it comes |
| AE-6 | `ResourcePool` over any `Sendable`, factory init, `async acquire()` | worker slots from a factory; runs wait for one |
| AE-7 | `ProcessProbe.childrenCPUNanos()` | `ChildUsage` delegates to it |
| AE-8 | `ContentDigest.sha256` (CommonCrypto, or portable FIPS 180-4) | no CryptoKit |
| AE-9 | `AemiProcess.ProcessTable` (sessions, start times, environments, live usage) | used by analyzerkit's cleanup and watchdog |

## AemiJSON and AemiProtobuf

| Id | Change | Litmus now |
| --- | --- | --- |
| AJ-1 | `ndjsonCompleteLines` keeps a growing file's partial last line | its own event scanner already kept it; unchanged |
| AP-1 | none needed: `FrameEncoder`/`FrameDecoder` existed (earlier claim withdrawn) | journal frames through them |
| AP-2 | none needed: `@ProtoMessage` covers these shapes (earlier claim withdrawn) | journal records are native messages (version 2; version 1 read) |

## analyzerkit

| Id | Change | Litmus now |
| --- | --- | --- |
| AK-1 | `run(…, monitor:)` with `ProcessControl.stop(reason:)` | fail-fast is a monitor, not a task race |
| AK-2 | `Result.terminationSignal` | a crash is a signal, not a status ≥ 128 |
| AK-3 | `EnvironmentPolicy` (`.toolchain`) | `DEVELOPER_DIR` kept by policy |
| AK-4 | sampled session usage and a memory limit; exact per-child usage waits on swift-subprocess#226 | `--memory-limit` (4096 MiB) |
| AK-5 | `litmus` known; unknown tools' sections accepted and listed | reads its section of `.swift-analyzers.json` |
| AK-6 | `formatChecked` throws | (Litmus already rendered with a throwing encoder) |
| AK-7 | `Fingerprint.anchored`, beside the first in SARIF | mutant ids are anchored the same way; SARIF carries `litmus/anchored/v1`; baselines hold it |
| AK-8 | `testTargets(covering:)`, `XcodeSchemeReader` | per-mutant test-target selection |
| AK-9 | `ModuleAwareBuildConfiguration`, `sdkModules`, `CompilerConfiguration.read` | not yet used for planning |
| AK-10 | `TreeSnapshot` | `WorkspaceSnapshot` is built on it |
| AK-11 | `RegionSpan.bytes`, `region(atByte:line:in:)` | not yet used for planning |
| AK-12 | cleanup of the child's session and token holders, pid reuse handled | trampoline and `ProcessReaper` removed |
| AK-13 | `TerminationSignals.run` | SIGINT/SIGTERM end a run cleanly (exit 128 + signal) |
| AK-14 | deadlines on the suspending clock | a sleeping machine does not time tests out |
| AK-15 | session-only spawn documented (avoids swift-subprocess#382) | — |
| new | `Options.priority` (Darwin quality of service) | `--background` |
| AK-16 | `ChangedLines`: new-side changed lines of a unified diff (ADR-0031) | `--diff`, `--diff-base`, change-scoped reports |
| AK-17 | `ProjectClassification.packageClosure(containing:)` (ADR-0031) | the sound reuse key's closure |

## Proposed (2026-11-02, pull-request runs, ADR 0007): implemented natively in Litmus meanwhile

| Id | Proposal | Litmus now |
| --- | --- | --- |
| AE-10 | A verified, size-bounded content-addressed store in aemi: records keyed by a digest, written atomically, checked on read (digest or HMAC), evicted least recently used past a bound, a read-only mode | `ResultStore` (Litmus task t57); bumping aemi means a train through analyzerkit and the six analyzers, so it waits for the next one |
| AE-11 | An advisory exclusive lock in aemi (`flock`, non-blocking, released with its descriptor) | `WorkspaceLock`, on `PosixFile`'s descriptor |
| AK-18 | `SourcePath.canonical` spells a path that does not exist yet differently from the same path once it does: Foundation drops `/private` only for existing paths. A run directory under `/private/tmp` was refused, and an "outside the root" check could compare two spellings of one directory | `canonicalNew` (deepest existing ancestor, then the rest) for every directory Litmus creates |
| AK-19 | `--only-diff`-style changed-line scope in the analyzers, on `ChangedLines` | Litmus only |

## Used as designed

- Swift Testing's ABI entry point (`swt_abiv0_getEntryPoint`, configuration as JSON, records as JSON lines) runs
  hostless test bundles on the simulator through Litmus's helper (t58), the interface swift-testing exposes for tools.

## Waiting on swift-subprocess

- **#226** (open): `ExecutionResult.resourceUsage`, exact per-child usage. Meanwhile usage is sampled every 100 ms
  (1.3 ms per sample, no measurable cost on a 1.5–2.5 s child).
- **#371** (open): a stopped child read as exited on macOS 26/27. Not reproduced here (macOS 27.0.1); the session
  cleanup ends such a child regardless.
- **#382** (open): descriptors leak on the fork fallback, which a session alone never takes.

## Not used yet

AK-9 (skip clauses no target compiles) and AK-11 (byte-exact preview exclusion) are available and planned (task t35).
