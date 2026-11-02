# ADR 0005 — Activation evidence, unviable isolation and parallel direct execution

Status: accepted (refines ADR 0003 and ADR 0004)
Date: 2026-11-02

## Context

The session review (`docs/reviews/2026-11-02-session-review.md`) confirmed eight defects in 0.1.0-dev: a precedence
error in logical replacements (D1); a `private` selector that a public default argument or an `@inlinable` body cannot
read (D2); a crash in top-level code (D3); a failing schema poisoning its whole batch (D4); crashes and timeouts never
resolved (D5, D6); uncompiled or unreached code reported as surviving (D7); serial `swift test` per mutant (D8).
swift-mutation-testing 1.6.4 already had activation markers, crash kills, unviable isolation, timeouts as detected,
fail-fast and direct parallel bundles.

## Decision

1. **Activation.** Each mutant gets `@usableFromInline nonisolated internal let __litmus_<file>_<id>: Bool`, initialised
   once per process. Its initialiser creates `<LITMUS_COVERAGE_DIR>/<id>` and compares `LITMUS_ACTIVE_ID`. The site reads
   `(m1 ? (r1) : m2 ? (r2) : (original))`; mutants on the same range share one replacement and one batch. In a file
   with top-level code the declarations precede the code. Operands of a replaced logical operator are parenthesised.
2. **Coverage is observed, never inferred.** A mutant whose marker the batch's inactive control did not write is
   `noCoverage` and is not run. A failure counts only when the mutant's own marker exists in that run; otherwise it is
   rerun and stays an infrastructure error if it repeats (SMT's "integrity warning", stricter: never a kill).
3. **Verdicts.** `killed`, `crashed` (a crash after activation, reproduced once), `timeout` (after activation, again
   with twice the deadline when rerun alone) are detected. `survived` and `noCoverage` are undetected. `unviable` is outside
   the score. `infrastructureError` and `notRun` block a successful execution and suppress the score. The score is
   Stryker's: detected ÷ (detected + undetected).
4. **Deadline** = max(3 s, baseline duration × 4 + 2 s), at most `--timeout` (300 s). Rerun deadline: twice that.
5. **Unviable isolation.** A failing schema build is split by the compiler's errors: the mutants whose replacement lines
   carry an error form one group, the rest another; with no attributable error, halves. A mutant is `unviable` only
   when it fails alone **and** an error points at its own lines; any other lone failure is an infrastructure error, so a
   broken build environment cannot manufacture unviable verdicts. Diagnostics are read after removing terminal escape
   sequences (compilers colour them even into pipes).
6. **Direct execution.** For a host package, the built bundles run without `swift test`: Swift Testing through the
   toolchain's `swiftpm-testing-helper` (event stream and xUnit), XCTest through `xctest -XCTest <classes>` (its exit
   status is its structured result, as SwiftPM reads it). No manifest evaluation per run and no `.build` lock, so mutants
   run on `CPUs − 1` workers from aemi's `ResourcePool`, each with its own markers and `TMPDIR`. An unknown layout falls
   back to `swift test` with one worker and a run note. Xcode stays at one worker.
7. **Fail-fast.** A mutant's Swift Testing run stops at the first failing issue of the event stream (a known issue or a
   warning does not count). XCTest has no structured stream and runs to the end.
8. **Kill confirmation is optional** (`--confirm-kills`). By default a kill needs: a passing unmutated baseline, a
   passing inactive control of the same build with identical counts, a structured failure, and the mutant's own
   activation marker. The 0.1 policy (control plus a second active run around every kill) tripled the cost of every kill
   to guard against flaky tests, which activation evidence and the control already constrain.
9. **Journal.** Every verdict is appended to `results.journal` (protobuf frames, synced with an ordering barrier);
   `run.json` is rewritten once per batch instead of once per mutant (it was O(*n*²) bytes over a run).

## Consequences

- Verdicts on the real fixture: the 10 mutants receive the intended killed, crashed, timeout, survived, noCoverage and
  unviable outcomes (`scripts/smoke.sh` asserts each).
- The XCTest counts of a passing direct run come from `swift test list`, not from an observed report; Swift Testing's
  come from its xUnit. A failure or a crash needs no count.
- Flaky-test protection is weaker by default than in 0.1; `--confirm-kills` restores it. A flaky failure that happens
  to coincide with activation can be counted as a kill; the integrity rule only removes failures without activation.
- Markers are files: a subject whose tests delete the marker directory or run in a sandbox without access to it shows
  `noCoverage` everywhere; the control catches the first case only if it passes. The Xcode path is not yet
  validated on a live simulator (task t5).

## Amendment (2026-11-02, after the fcheck pilot)

The first real-package run (fcheck, 206 mutants) found two defects in this decision's implementation:

- **Reruns were not alone.** Item 3 said crashes and timeouts are "rerun alone"; the rerun ran inside the parallel
  pass, competing with six workers, so 39 mutants timed out twice before reaching their code (infrastructure errors).
  Reruns now form a serial pass after each batch's parallel pass. A first run among more than one worker gets twice
  the derived deadline (`RunPolicy.parallelDeadline`), as swift-mutation-testing allows; the rerun, alone, gets the
  same twice-the-deadline allowance without contention.
- **The scratch directory was outside the package.** fcheck's command-line tests run `<package>/.build/debug/fcheck`,
  a common SwiftPM pattern; with Litmus' scratch directory elsewhere the unmutated suite failed and the run correctly
  stopped. SwiftPM now builds in the copied workspace's own `.build`, which the snapshot neither copies nor verifies.
- **Contention made false timeouts.** With reruns in the parallel pass, 25 fcheck mutants were reported `timeout`
  (detected): rerun alone, they were 9 kills and 16 survivors. A tool that counts parallel-pass timeouts as detected
  overstates the score. Workers are now sized from the suite's own parallelism, measured as child CPU over wall time
  during the baseline (`RunPolicy.suiteParallelism`): `workers = ⌊cores ÷ parallelism⌋`, at most `--jobs`.
- **Flow errors are reported away from the mutant.** Negating `while true` makes the compiler report "missing return"
  at the end of the function. A lone mutant is now unviable when an error is in its own file, the only file that build
  changed; with no error, or errors only in other files, it stays an infrastructure error.
- **Activation is per process, not per test; decision 8 is superseded.** In the third fcheck run, 10 of 180 kills rested
  only on `CallSiteScalingTests` ("four times the chain costs about four times the time"), a timing test that fails
  under load whatever the mutant; the mutant's code had run in the same process, in other tests. Kills are now
  confirmed by default (`--kill-confirmation targeted`): the failing tests (from the Swift Testing event stream) rerun
  alone with the mutant active (they must fail and write its marker themselves, which attributes the kill to a test
  that reaches it) and inactive (they must pass). A failure not reproduced that way gets one whole-suite run alone.
  Harnesses without test identities (XCTest, `swift test`, Xcode) rerun the whole suite alone. `none` restores the
  first-failure rule; `full` keeps the 0.1 whole-suite control and second run. Each kill names its killing tests.
  In run 4 the timing test killed nothing: 5 of those 10 mutants survived and 5 were killed by other tests.
  Swift Testing's `--filter` matches identifiers that may carry `/File.swift:line:column`: the pattern ends at `/` or
  the end (`$` alone matched nothing, exit 69).
