# ADR 0006 — Supervision through analyzerkit, flaky-test exclusion and test-target selection

Status: accepted (refines ADR 0005)
Date: 2026-11-02

## Context

Litmus carried its own process reaper (a `/bin/sh` trampoline recording a session id, `DYLD_*` variables renamed through
the SIP-protected shell, `sysctl` scans), its own `RUSAGE_CHILDREN` reading, CryptoKit digests, hand-written journal
frames and a fail-fast race that cancelled a task to stop a child. Two orphaned test helpers had kept two cores busy for
2.5 hours; an interrupted Litmus left `xcodebuild` running. The fcheck pilot showed a timing test making kills, and that
oversubscription is slower than fewer workers. The upstream changes (docs/upstream-recommendations.md) make the family's
own primitives cover all of this.

## Decision

1. **One executor.** `BoundedExecutor` is analyzerkit's `BoundedProcess` with session cleanup and the run's token
   (`LITMUS_PROCESS_TOKEN`, passed on to simulator hosts by the `.xctestrun`), a fail-fast monitor, termination signals,
   sampled usage, a memory limit (`--memory-limit`, 4096 MiB: past it a crash) and optional background priority
   (`--background`: builds and first runs only; reruns, which decide timeouts, at normal priority, since background
   stretches wall time 2 to 15 times).
2. **Interruption is cancellation.** The run is under `TerminationSignals.run`: SIGINT/SIGTERM end it with 128 plus the
   signal, its children ended and an incomplete checkpoint written; a second signal exits at once.
3. **Flaky tests are found, not suffered.** With the direct harness the unmutated suite also runs with
   `--repetitions 3`; a test failing in any repetition is left out of every run (`--skip`), the baseline re-measured
   without it, and both are recorded (`RunPolicy.flakyTests`). The fcheck timing test would have been found this way.
4. **Test-target selection.** Each mutant runs only the test modules that can reach its file
   (analyzerkit `testTargets(covering:)`, from manifests, without building); a passing run is checked against those
   modules' baseline counts. A file no target claims runs every module.
5. **Suite width is opt-in.** `--suite-width` caps Swift Testing's parallelism and sizes workers from it. Measured on
   fcheck (152 tests, 26–28 s of CPU): unbounded 7.7 s, width 4 16–18 s, 2 38–44 s, 1 73–113 s. Fewer workers is the
   better lever; width is for suites that oversubscribe memory.
6. **Execution policy v3** (`activation-markers/no-coverage/unviable-isolation/v3`): records memory limit, priority,
   repetitions, flaky tests, width and selection. Journals are version 2 (native protobuf records); version 1 is read.

## Consequences

A run costs one more baseline-sized suite run (the repetitions; three repetitions inside one process). A mutant whose
test modules are selected cannot be killed by a test of another module that happens to reach it at run time through a
dependency the manifests do not show; activation markers still guard every verdict, and such a mutant ends as no
coverage rather than as a false kill.

The session cleanup first killed a stranger: a reused session id led a new `swift build` (status 137). analyzerkit now
skips a session whose id is a live pid again (`selectLeftovers`); a kernel gives out no pid still used as a session id.
