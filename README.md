# Litmus

Evidence-led mutation testing for Swift packages and Xcode projects, built in the style of `arcleak`, `deadwood`, `dolly`,
`fcheck`, `modeler` and `analyzerkit`, on **analyzerkit, aemi, AemiJSON and AemiProtobuf**.

**Status: 0.3.0-dev, not production-qualified, safety-certified or military-qualified.** Host Swift packages are
verified end to end on a real fixture; the Xcode path builds for the iOS Simulator but has not run tests on one yet.
The CLI needs macOS 15+ and Swift 6.4; a subject keeps its own settings.

## Build and test

```sh
swift build --build-tests -j 4
swift test --skip-build
./scripts/smoke.sh       # real mutation run: killed, crashed, timeout, survived, noCoverage and unviable verdicts
```

## Use

```sh
litmus plan /path/to/package --output plan.json            # syntax only; runs nothing
litmus run /path/to/package --trust-project --output /tmp/litmus-run-001
litmus analyze /path/to/package --results /tmp/litmus-run-001/run.pb --format json --strict
```

Xcode project or workspace (run from the repository root that holds every local package):

```sh
litmus run . --project App.xcodeproj --scheme AppTests \
  --destination 'platform=iOS Simulator,id=EXISTING-UDID' --trust-project --output /tmp/litmus-ios-001
```

An iOS-only package uses its Xcode scheme (omit `--project`), never host `swift test`.

`run` options: `--jobs N` (default CPUs − 1), `--timeout S` (cap of the derived deadline, 300), `--timeout-factor F`
(4), `--batch-size N` (64), `--harness automatic|swift-test`, `--no-fail-fast`, `--kill-confirmation targeted|full|none`
(targeted), `--keep-workspace`, `--swiftpm-build-system native|swiftbuild`, `--exclude-path GLOB`, `--only-path GLOB`
(mutate only matching files; `include` in `.litmus.json` or the `litmus` section of `.swift-analyzers.json`),
`--config FILE`, `--memory-limit MiB` (4096; past it, a crash), `--baseline-repetitions N` (3: flaky tests are found and
left out), `--suite-width N`, `--no-test-target-selection`, `--per-test-reach`, and `--background`. `--background`
runs builds and first passes at background priority, 2 to 15 times slower: a subject that builds with
`-warn-long-expression-type-checking` and warnings as errors may then fail its own time limits (the error is in the
message). SIGINT or SIGTERM ends a run cleanly: exit 128 + signal, children ended, an incomplete checkpoint written.

## How a run works

1. **Snapshot.** The subject is copied into a new run directory outside it (aemi `DirectoryWalk`, parallel SHA-256);
   a symbolic link is left out and listed in the run's notes (never followed), a special file refused. Only the copy is ever rewritten. This is not an OS sandbox: manifests, plugins,
   scripts and tests run with your rights. Use a disposable restricted runner for untrusted code.
2. **Plan.** Negated conditions, swapped ternaries and swapped `&&`/`||` (operands parenthesised), outside tests,
   previews, debug-only code, generated code, files no target compiles, and macro arguments; every exclusion is noted.
3. **Schema.** Each batch (64 sites, never nested ones) is rewritten once: every mutant gets a once-initialised
   `@usableFromInline nonisolated` activation that records a marker the first time its code runs, so a site may be in a
   view body, an initialiser, a public default argument or an `@inlinable` body. Mutants on the same expression share it.
4. **Build and isolate.** One build per batch. A failing build is split by the compiler's errors (then by halves);
   a mutant failing alone with an error on its own lines is `unviable`.
5. **Control.** The inactive schema must pass with the baseline's counts; it also records which mutants the tests
   reach. Unreached mutants are `noCoverage` and are not run.
6. **Mutants, in parallel.** Built bundles run directly (no `swift test`, no `.build` lock), each mutant in a fresh
   process with its own markers and `TMPDIR`; Swift Testing stops at the first failing issue of its event stream.
7. **Verdicts.** A failure counts only if the mutant's marker shows its code ran, and by default only if the failing
   tests, rerun alone, fail again and reach the mutant themselves and pass without it; each kill names its tests.
   Crashes and timeouts are rerun alone after the parallel pass. Workers are sized from the suite's own parallelism.
   Every verdict is journalled (`results.journal`, protobuf frames, synced).

| Verdict | Meaning | Score |
| --- | --- | --- |
| `killed`, `crashed`, `timeout` | Detected after the mutated code ran | detected |
| `survived` | Every test passed after the mutated code ran | undetected |
| `noCoverage` | No test reached the mutated code | undetected |
| `unviable` | Does not compile alone | excluded |
| `infrastructureError`, `notRun` | No trustworthy evidence | blocks the score and a green gate |

Score = detected ÷ (detected + undetected), as Stryker and swift-mutation-testing compute it.

## Reports and exit status

`analyze --results` reports historical evidence and re-hashes every input (tests, resources and settings included):
a changed input makes the report degraded and exit `70`, never green. Formats: `xcode`, `json` (family envelope v1,
score, policy, timings), `sarif` (2.1.0). `--only`/`--only-from` scope the report, not the run. `--strict` fails on
survivors and no-coverage mutants (warnings); `unviable` is a note.
Exit codes: `0` passed, `1` findings, `64` usage, `70` incomplete, stale or unresolved, `74` output, `78` configuration.

## Sizing new operators

`litmus census PATH` counts, from syntax alone, where 33 candidate operator kinds would apply in production code
(`docs/research/2026-11-02-mutation-extent-and-thoroughness.md`). It builds and runs nothing.

## Configuration and suppression

`.litmus.json`: `{ "exclude": ["**/Generated/**"] }`. `// @lm:accept:next swap-ternary -- reason` suppresses a site;
it stays listed in the plan. A `litmus` section in `.swift-analyzers.json` waits for analyzerkit (AK-5).

## Performance

Measured, one run each, same machine (`docs/performance.md`): on the 10-mutant fixture Litmus takes 30–38 s and
swift-mutation-testing 1.6.4 takes 136 s (3.6–4.5×), with the same 77.8% score. On the reference app's 4152 mutants Litmus needs
18–66 schema builds where swift-mutation-testing needs more than 1832. No tool can be "thousands of times" faster than
another one that runs the same tests: test time is the floor; the gains come from fewer builds and fewer, shorter runs.

## Engineering record

[White paper](development/WHITE-PAPER.md) · [ADRs](development/adr) · [Diary](development/diary) ·
[Verification](docs/verification.md) · [Performance](docs/performance.md) ·
[Upstream recommendations](docs/upstream-recommendations.md) · [Session review](docs/reviews/2026-11-02-session-review.md) ·
[Investigation](docs/investigation.md) · [Security](SECURITY.md)
