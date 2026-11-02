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
