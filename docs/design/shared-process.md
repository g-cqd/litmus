# Design: shared-process execution (Phase D1.2–D1.5, target v0.5.0)

Status: proposed. This note refines the Phase D specification (§D1.2–D1.5) with a spike's measurements and the soundness rules the spec leaves open. Nothing described here is implemented yet.

## Why

Most of a mutant's test time is the process start, not the tests. With per-test reach, a mutant on `mutation-test-ios-app` runs 2–6 ms of tests inside a `simctl spawn` or `swiftpm-testing-helper` process that costs about 300–400 ms to start (dyld, SwiftUI/UIKit, the app's debug dylib, Swift Testing discovery). For 83 runs, that start-up adds up to 24 s of the run's 44 s.

## Spike (macOS, Swift 6.4.2, 2026-11-27)

A 60-line helper `dlopen`s a SwiftPM `.xctest` bundle and calls Swift Testing's `swt_abiv0_getEntryPoint` entry point 55 times in one process. Between calls it flips a mutant switch through an exported setter (a stand-in for the control page).

| Measure | Result |
| --- | --- |
| `dlopen` of the bundle (XCTest and Testing from the platform's developer frameworks) | 47–70 ms, once |
| one filtered in-process run (1 test) | median 0.46 ms, max 0.90 ms |
| two consecutive full runs | identical events (suite `init` runs again for each test, parameterized cases expand again) |
| 25 runs with the mutant on, alternating with 25 with it off | 25 failed with 1 issue each; 25 passed with 0 issues |

So the entry point can be called again and again, filters apply per call, and an issue recorded in one call does not leak into the next. That is the premise of §D1.4. The simulator helper already calls the same entry point; only its loop and its command channel are new.

Not covered by the spike: XCTest repeated in-process; app-hosted bundles on the simulator; Swift Testing's `.serialized` and `@MainActor` suites across calls; and the control page in the schema runtime itself.

## Decisions

1. **Scope.** Shared mode runs Swift Testing only, with filters from per-test reach. XCTest cases and XCTest-only bundles keep today's one process per mutant. `XCTestSuite.default.run()` twice in one process is not a supported pattern, and the spike did not try it.
2. **Control page** (§D1.2, adopted as written). The page lives at `LITMUS_SHARED_MAP_<token>` and holds `activeSlot`, `activeHits`, `modeFlags` and per-slot counters. It is `mmap`ed by the import-free runtime through `@_silgen_name`. When the variable is unset, the runtime takes exactly today's `LITMUS_ACTIVE_ID` path, so the isolated mode is unchanged and stays the oracle. Simulator processes share the host kernel, so `MAP_SHARED` on a host file reaches them too; this needs its own check.
3. **Command channel** (§D1.4, adopted). Two FIFOs, `cmd` and `rep`, in the worker's slot directory, named by environment variables. Standard descriptors 0, 1 and 2 stay the subject's. One JSON line per request and per reply.
4. **Process-lifetime switches** (§D1.3, adopted). Before running any mutant, a worker takes three counter snapshots: after load, after an unmutated pass, and after a second unmutated pass. A slot evaluated during load, or evaluated a different number of times in the two passes, is `processCached` and always runs in a fresh process. This covers `static let`, `lazy`, memoised singletons, and nondeterministic paths.
5. **Kills.** Two checks before a shared kill is accepted:
   - `activeHits > 0` and a recorded issue.
   - The failing tests, rerun unmutated in the same process, pass.

   If the unmutated rerun fails, the process is dirty: the worker is replaced and the mutant is decided in a fresh process.
6. **Survivors are never decided in a shared process.** Every shared survivor is confirmed in a fresh process, as `recheckSurvivors` does today, so shared mode cannot create a false survivor.
7. **Dirt left by a survivor** (not covered by the spec). A surviving mutant can leave state behind, for example a cache filled while it was on, without failing anything. The next mutant could then be killed by that state rather than by its own change. Decision 5's unmutated rerun catches this whenever the state alone fails the test. It misses the case where the next mutant and the leftover state fail only together. Mitigations:
   - (a) After each shared survivor, run the worker's covering tests unmutated once more. If they fail, replace the worker.
   - (b) The equivalence oracle (below) measures whether any false kill remains.

   If (b) ever finds one, the fallback is to replace the worker after every survivor. That still keeps the gain, since 85–95 % of covered mutants are killed.
8. **Crashes and timeouts.** A trap or hang ends the worker. The judge records the verdict through today's rerun policy and starts a new worker for the rest of the queue. One crash costs one start-up, as it does today.
9. **`--shared-process auto|on|off`** (§D1.5, adopted). Default `auto`, using the spec's break-even rule: at least 8 covered mutants, and `mutants × t_spawn > workers × (2 × t_suite + t_spawn)`. `t_spawn` comes from the existing probe; `t_suite` comes from the baseline.

## Acceptance

- **Equivalence oracle.** `--shared-process on` and `off` give the same verdict for every mutant on:
  - `ExampleApp`, the operator fixture, and `mutation-test-ios-app@51952be`;
  - a new fixture with four cases: a `static let` from a mutated expression, a `lazy var` on a singleton, a mutant that corrupts a global before failing, and a mutant that traps.
- **Performance.** The 19-operator run on `mutation-test-ios-app` takes at most 25 s (44.3 s in 0.4.13). An `--only-id` inner loop takes at most 3 s on macOS and at most 6 s on the simulator.
- Everything in the Phase D gates (format, quality, debug and release tests, the three smoke scripts).

## Order of work

1. Runtime control page in `SchemaWriter`, with unit tests rendering both paths. The isolated path's output must stay byte-identical when the variable is unset.
2. macOS helper (`MacOSHelperSource.swift`) with the command loop, behind `--shared-process on`, for `SwiftPMDirectHarness`. Then the snapshot classification and the kill and survivor rules.
3. Oracle fixture and test. Then `auto`.
4. Simulator helper loop. Then the benchmark on `mutation-test-ios-app`.
5. Docs (`README.md`, `docs/usage.md`, `docs/execution.md`, `docs/ci.md`) and the v0.5.0 release notes.
