# Performance — measured, 2026-11-02

Machine: Apple M3, 8 cores (4 performance), 16 GB, macOS 27.0.1, Xcode 27.2 (27B52), Swift 6.4.2. The machine was
shared with other builds during every measurement (load average 11–35 on 8 cores, recorded with each run), so runs
were interleaved between tools. Every number is one run unless a range is given. Litmus numbers are from the
release build (`swift build -c release`) unless marked debug.

## The fixture (`Tests/Fixtures/Example`): 10 mutants, 3 + 5 Swift Testing and 1 XCTest tests

| Run | Wall | Score | Verdicts | Load (1 min) |
| --- | --- | --- | --- | --- |
| Litmus 0.2.0-dev, release, defaults | **34.3 s** | 77.78 % | 5 killed, 1 crashed, 1 timeout, 1 survived, 1 no coverage, 1 unviable | 15.3 |
| swift-mutation-testing 1.6.4, `--no-cache`, defaults | **135.7 s** | 77.8 % | 6 killed, 1 timeout, 1 survived, 1 no coverage, 2 unviable | 27.7 |
| Litmus 0.2.0-dev, release, defaults | **37.6 s** | 77.78 % | as above | 20.8 |
| Litmus, `--harness swift-test --jobs 1 --no-fail-fast` | 56.7 s | 77.78 % | as above | 11.8 |
| Litmus, `--swiftpm-build-system native` | 38.3 s | 77.78 % | as above | 11.2 |
| Litmus, release, defaults | **30.4 s** | 77.78 % | as above | 9.0 |
| Litmus, `--swiftpm-build-system native` | 34.7 s | 77.78 % | as above | 13.5 |
| swift-mutation-testing 1.6.4 (earlier, debug-Litmus comparison) | 168.3 s | 77.8 % | as above | not recorded |

Litmus with defaults takes 30.4–37.6 s (3 runs): **3.6–4.5× faster** than swift-mutation-testing's 135.7 s on this
fixture, with the same score. The native build system rebuilds faster incrementally but its cold baseline build costs
more, so it brings **no end-to-end gain** here (34.7–38.3 s); it stays an opt-in. (SMT reports one more
unviable mutant: it also mutates the `&&` in the operator's declaration. It counts the crash as a kill.)

Where Litmus' 34.3 s go (`run.json` timings): builds 22.7 s (one cold baseline build, one schema build that fails,
one remainder build, one failing build of the unviable mutant alone, one build of the nested batch), tests 9.5 s, test
discovery 1.9 s, snapshot and plan under 0.1 s. Of the tests, **9.07 s is the timeout mutant** (3 s deadline, then a
6 s rerun); the other eight mutants that ran took 0.09–0.25 s each.

Effect of the direct harness: per-mutant test time 0.09–0.25 s with bundles run directly, 1.36–1.82 s with
`swift test` (which recompiles the manifest on every call, measured at 2.2 s per invocation against 0.06–0.1 s for the
bundle itself). Fail-fast and the 7 workers matter more on suites longer than this fixture's.

Caveat added later the same day: these fixture timings predate targeted kill confirmation (now the default), which
adds two short runs per kill. The debug fixture run's test phase went from 9.5 s to 13.4 s with it; the release
comparison against swift-mutation-testing was not repeated.

## The reference app (`example/app`, read-only planning)

| | Litmus 0.2.0-dev | swift-mutation-testing 1.6.4 |
| --- | --- | --- |
| Mutants (default operators, same exclusions) | 4152 (31 preview/debug sites, 1 macro site, 1 file no target compiles excluded with notes) | 4176 |
| Planning time, 3 runs | **0.77–0.80 s** (release; 45 s debug) | 1.21–1.39 s |
| Builds for the whole corpus | **66** schema builds at `--batch-size 64`, **18** at 256 (greedy, overlapping sites split) | 1832 incompatible mutants each build alone, plus its schema batches |

On the app a build costs minutes (the CI unit-test step, incremental build plus tests, takes 170–240 s), so the
build count decides a weekly run's length: Litmus needs **28–100× fewer builds** (1832 ÷ 66 to 1832 ÷ 18), before
unviable isolation adds its splits. This is a projection from the plan: the Xcode path has not run on a simulator
yet, and neither tool has completed a run of the app (SMT's baseline build fails in its sandbox).

## "Thousands of times faster" is not achievable, and why

Every tool must, for each covered mutant, run the tests that reach it. With *T* the suite time and *C* the covered
mutants, any tool spends at least about *C × T_min* / workers, where *T_min* is the time to the first failing test or the
whole suite for a survivor. The ratios available are:

- **Builds:** 1832+ → 18–66 on the app (28–100×), the dominant term there.
- **Process overhead:** `swift test` 2.2 s → 0.06–0.1 s per invocation (20–35×), the dominant term on small suites.
- **Uncovered mutants:** zero runs instead of one full suite each.
- **Workers:** up to CPUs − 1 for host packages (7 here); one simulator for Xcode until simulator clones are measured.

Their product can reach two to three orders of magnitude against a naive tool (one build and one `swift test` per
mutant), not against swift-mutation-testing, which already batches, stops early and runs workers. Measured against it:
**3.6–4.5×** on the fixture.

## Next measured levers (not done)

| Lever | Expected effect | Evidence so far |
| --- | --- | --- |
| A persistent build directory between runs (weekly runs) | Removes the cold baseline build (18 s debug-fixture, minutes on the app) | Not implemented: needs a stable workspace path and unchanged-file preservation |
| Larger default batches | 64 → 256 cuts app builds from 66 to 18 | Plan only; compile-time growth of large SwiftUI schemas unmeasured |
| Per-test selection from activation markers per test | Run only the tests that reached a mutant | Needs per-test identity in the subject process (ADR 0005 keeps whole suites) |
| Simulator clones for Xcode workers | Parallel app tests | Not measured; simulator hangs seen on this machine |

## A real package: fcheck (206 mutants, 152 tests), 2026-11-02

Debug Litmus, shared machine. See `docs/research/2026-11-02-mutation-extent-and-thoroughness.md` for the verdicts.

| Run | Workers | Wall | Builds | Tests | Load |
| --- | --- | --- | --- | --- | --- |
| 1: reruns among workers | 7 | 1384 s | 171 s | 1208 s | ~10 |
| 2: serial reruns | 7 | 1564 s | 173 s | 1387 s | ~10 |
| 3: workers from suite parallelism 3.88 | 2 | **650 s** | 183 s | 462 s | ~12 |
| 4: targeted kill confirmation, parallelism 2.34 | 3 | 1119 s | 261 s | 850 s | 15–34 |

Seven workers were 2.4× slower than two on a suite that parallelises itself. swift-mutation-testing defaults to
CPUs − 1 workers too; it was not run on fcheck here.
