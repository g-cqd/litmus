# Verification and assurance case

**This document records scope, not certification.** Assertions below require actual passing evidence in the diary.
The package is new local work on `main`; no upstream merge/rebase applies and no existing consumer APIs are modified.

## Requirements-to-evidence map

| Requirement | Verification mechanism | Residual gap |
| --- | --- | --- |
| R-01 Original source preservation | Snapshot integration tests; real smoke source SHA comparison | No OS sandbox; adversarial local filesystem races and malicious scripts outside contract |
| R-02 Honest verdicts | Process-status/count classifier; malformed XML and xcresult tests | Assertion identity/repeated identical failure signatures need stronger matching |
| R-03 Baseline validity | Failed baseline checkpoint test; inactive-schema run | Actual Xcode simulator baseline unverified |
| R-04 Activation evidence | Injected runner: kill needs the marker; failure without it rerun and kept unresolved; crash and timeout reruns with doubled deadline; real fixture asserts each verdict | Flaky failures that coincide with activation count unless `--confirm-kills` |
| R-05 Explicit uncertainty | Missing/zero tests, process failure, incomplete artifact tests; exit70 policy | Process timeout/fault-injection matrix not exhaustive |
| R-06 Reconciliation | IDs/ranges/hashes/overlap tests; artifact model reconciliation | Independent proof or exhaustive model checking not performed |
| R-07 Bounds | Bounded reader/wire/XML/process APIs; malformed/truncated/duplicate wire tests | Fuzz campaign and all resource-limit boundary tests still required |
| R-08 Provenance | Full snapshot inventory, SHA-256, source-staleness smoke | External environment/dependencies not embedded; no signatures; historical evidence only |
| R-09 Process supervision | analyzerkit BoundedProcess; no shell argv; explicit trust flag | Simulator services outside process group; credentials/VM isolation is operator responsibility |
| R-10 Determinism | Repeated discovery and UTF8 byte-range tests | Cross-toolchain/host determinism not established |
| R-11 Observed coverage only | Unreached-in-control mutants are `noCoverage` without a run (unit and real fixture) | Coverage observed in one control run: nondeterministic reachability is not modelled |
| R-12 Honest denominator | No equivalent/static-dead/clone pruning; explicit unresolved outcomes | No score policy qualification; semantic equivalent mutants remain |

## Not yet qualified

- Actual iOS simulator run (both package and app-hosted XCTest/Swift Testing).
- Real `.xctestrun` variants including multi-config plans, UI test runners and unusual paths.
- macOS/iOS SwiftUI builders and effects/typed-throws/ownership fixture matrix beyond the inherited probe.
- Custom operator overloads, default actor isolation and target-specific strict build flags.
- Reference app's SwiftLint/localization/plugin path assumptions in a copied tree.
- Independent review, sustained fuzz/fault-injection, race/sanitizer testing and a reproducible signed release.
- Release PR event audit and weekly runtime budgets on an actual CI runner.

The saved investigation simulator failures prevent claiming a successful app benchmark; they do not establish that a new
engine's simulator driver is correct. A high-criticality deployment must close these gaps or explicitly constrain operation.

## Verified in this checkout (2026-11-02)

- `swift build --build-tests -j 4`: final debug build succeeded under Swift 6.4 strict concurrency,
  strict memory safety and warnings-as-errors. No release performance build was run.
- `swift test --skip-build --xunit-output /tmp/litmus-final-tests.xml`: **22 tests passed**; Swift Testing emitted
  `/tmp/litmus-final-tests-swift-testing.xml`. Checked the actual report (tests=22, failures=0, errors=0).
- Real mixed XCTest/Swift Testing fixture: **3 mutants, 2 killed, 1 survived**, original-source SHA unchanged,
  both framework XML reports consumed, inactive/confirmation controls passed.
- JSON/protobuf result round trip; JSON envelope v1; SARIF 2.1.0 successful invocation; strict survivor gate exit1;
  modifying only a test file made the report stale and exit70. Smoke repeated successfully after final runtime changes.
- `docs/evidence` contains unit XML/log and the final smoke log. Complete smoke artifacts are preserved in
  `~/Public/Litmus-Implementation-Evidence` with a SHA-256 manifest, not a signature.
- Markdown links and `git diff --check` were checked. No app/family source or CI workflow was modified.

Build accounting: 13 package debug-build invocations in the initial bootstrap/verification work, including two placeholder
red-contract builds an explicit SwiftPM evidence-regression red build and one final build after adopting the family formatting configuration. Additional tiny SUBJECT fixture builds were
performed by the smoke/probes. This exceeds the usual four-build budget: package relocation caused a cold rebuild; Swift's
batch compiler exposed successive strict-memory-safety diagnostics; real boundary probes exposed the canonical path and
split-framework XML issues. No release build or multi-configuration matrix was run. This is an explanation, not a
recommendation for future edit/build loops.

### Final style and Xcode package checks

The family `.swift-format` configuration was adopted in a separate formatting-only pass. `swift-format lint --strict`
passed; the package was rebuilt once, all **22 tests** passed again, and the real mixed-framework smoke passed again.
The retained full smoke in Public precedes this formatting-only delta; `docs/evidence` contains the post-format results.

`xcodebuild -list -json` recognized the fixture package's `Example` scheme. **Actual iOS Simulator build-for-testing
succeeded** for `generic/platform=iOS Simulator`, producing a real `.xctestrun`; a copy is in `docs/evidence` and the
full build log is in Public evidence. This validates package discovery and the Xcode build stage, **not simulator test
execution**, active-ID forwarding or app-hosted testing. No simulator was booted for these checks.

## Verified for 0.2.0-dev (2026-11-02)

- Debug build with strict concurrency, strict memory safety and warnings as errors; **39 tests passed**
  (`docs/evidence` is from 0.1; the 0.2 report is in `~/Public/Litmus-Implementation-Evidence/v0.2-2026-11-02`).
- `scripts/smoke.sh` on the real fixture asserts **killed, crashed, timeout, survived, noCoverage and unviable**
  verdicts by site, the direct harness, a 77.78% score, the strict gate, SARIF, protobuf and stale-test refusal.
- Release build: fixture runs and read-only app planning as in `docs/performance.md`; the app worktree stayed clean.
- Not verified: simulator execution (task t5), a full app run, `--confirm-kills` on real code.
