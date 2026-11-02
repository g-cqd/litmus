# Mutation-analyzer investigation — evidence and feasibility

> **Errata (2026-11-02, session review).** Re-checked against the GitHub API and the saved evidence:
> - No PR had a head or base of `release/*` or `merge_release/*` since 2026-06-15. #1509 was merged into `develop`; `release/23.0.1`
>   holds a cherry-pick of it plus two direct commits. Release branches are created by a push, so a release report needs a `push` trigger on `release/**`.
> - Release scope from `release-scope.txt`: 25.0.0 → 26.0.0 is 966 mutants (371 incompatible); 24.0.0 → 25.0.0 is 1079 (364). The figure "643 / 285" said in the chat was wrong.
> - swift-mutation-testing 1.6.4 also has activation markers (no coverage), killed-by-crash, unviable isolation, timeouts counted as detected, fail-fast,
>   parallel workers on directly launched SwiftPM bundles, measured operator tiers and Stryker/HTML/Sonar reports. The comparison below understates it.
> - Full review: `/Volumes/Personal/Github/g-cqd/litmus/docs/reviews/2026-11-02-session-review.md`.


Date: 2026-11-02. This supersedes the conclusions, not the raw evidence, of the preliminary note in `Github/notes`.
Implementation now lives in this package; implementation verification is separate from investigation measurements.

## Evidence sources

1. `/Users/user/Public/Swift-Mutation-Analyzer-Evidence`:
   original plan, deadwood report, framework comparison, probe sources and baseline/simulator logs.
2. `/Users/user/Public/mutation-testing-investigation-2026-11-02/evidence`:
   scripts, captured outputs, release-history observations and probe copies.
3. Local family repositories under `/Volumes/Personal/Github/g-cqd`, and the reference app worktree
   `ci-TICKET-0-analyzers`, HEAD `0d9f8e72d658f169c4b6836c0e509379c686b99f`.
4. Reference tool binary 1.6.4, and source tag v1.6.4 downloaded separately for comparison. The comparison input's
   older tool-version assessments and README `main` descriptions are not substituted for pinned-source evidence.

Evidence classes: **measured** command outcome; **source** inspected implementation; **probe** limited synthetic test;
**scenario** arithmetic on assumptions; **proposal** not implemented/validated. No class implies another.

## Reference target measurements

The default reference plan generated 4176 mutation sites in a corpus of 2493 discovered files, in about 0.94 seconds.
2344 sites were schematizable and 1832 incompatible (43.9%). Discovery is not the primary performance problem.

| Operator | Sites | Incompatible |
| --- | ---: | ---: |
| NegateConditional | 2846 | 998 |
| SwapTernary | 776 | 509 |
| LogicalOperatorReplacement | 554 | 325 |

| Module | Sites | Incompatible |
| --- | ---: | ---: |
| ModuleUI | 1349 | 722 |
| Example App | 815 | 270 |
| ModuleCall | 556 | 285 |
| ModuleTickets | 440 | 182 |
| ModuleUtilities | 165 | 20 |
| ModuleChats | 159 | 81 |
| ModuleWorkflows | 129 | 79 |
| ModuleParts | 106 | 44 |
| ModuleAPI | 102 | 53 |
| ModuleAssets | 89 | 48 |
| ModuleNetworking | 79 | 2 |
| ModuleExperimental | 57 | 17 |
| ModuleMacros | 55 | 0 |
| ModuleContacts | 48 | 23 |
| ModuleTestingUtilities | 9 | 0 |
| NotificationExtension | 7 | 0 |
| Dangerfile.hooks.swift | 4 | 4 |
| scripts | 3 | 0 |
| BroadcastExtension | 2 | 0 |
| Dangerfile.swift | 2 | 2 |

The initial scope includes macro/support/scripts/extensions. It is not a qualified production-runtime denominator.
A backwards/indentation heuristic placed 1063 incompatible sites in view bodies/builders, 730 in other properties/
initializers, 38 elsewhere and 1 in a function/initializer default parameter. These are not AST-verified classifications;
“1790 fixable” is a hypothesis, not a result.

Approximate source survey: 2512 non-generated files /190297 lines. Grep found 2007 `@Test`, 363 XCTest test methods and
350 test files, not actual enumerated test cases. The unit bundle is app-hosted (`TEST_HOST=Example.app/Example`).
Several local packages require iOS and plugins, so plain host SwiftPM is not equivalent to the app's Xcode test setup.

Last 12 successful CI unit-test steps: 240, 204, 183, 202, 200, 200, 193, 198, 239, 175, 170, 225 seconds; median 200.
The step includes bundler/build/test. The full workflow median is about 7.3 minutes (28 successes of last 30 observed).
These are not pure suite or launch timings. App build products appeared around 6.5 minutes into one local attempt;
that attempt never completed tests and is not a valid completed cold-build benchmark.

Deadwood 0.15.0 ran in about 3.14 s, reporting 58 findings over 2981 files. Rough brace matching found six mutation sites
within those declarations; a preview/debug heuristic found 51 sites. Neither supports large speedup claims or sound
pruning. Constant-condition negation generally changes semantics; statically unused does not mean untested.

The direct test-type-token heuristic found no matching test file for 2098 sites. This is **not a sound upper or lower
bound** on actual uncovered mutants: indirect references can execute unmatched code, and matching a type name does not
prove a particular expression runs. Static lookup is useful for prioritization, not no-coverage verdicts.

## What failed in real execution

A reference-tool one-file run found seven schematizable sites but the unmutated build failed after 8m43.449s.
There were 16 build failures: SwiftLint plugin “No lintable files” failures in 14 packages, a localization cleanup fatal
error referencing the relocated DerivedData products, and an app runtime script failure. No mutant ran, no score exists.
The root causes were not isolated. APFS cloning may reduce copying cost, but cannot by itself repair path assumptions.

Normal Xcode attempts reached simulator installation, then hung in `SimDevice installApplication`. Another destination
failed because its device data directory was missing. No coverage map, selected-test latency or complete suite timing
was obtained. Builds started by the investigation were stopped; the app worktree was clean at that checkpoint.
Restarting shared CoreSimulator service was deliberately avoided so the user's active session was not disrupted.

## Pinned reference tool: retain its strengths

v1.6.4 already includes source schematization, schema batches (16 mutants/function), fallback/narrowing, caches with
source/test hashes and test-selection metadata, baseline scope checks and conditional compilation handling with
SwiftIfConfig. It is inaccurate to claim all of these would be new advantages of Litmus.

Its scope visitor recognizes functions/initializers/deinitializers and explicit accessors, but not shorthand computed
getter blocks. Some incompatibility is an implementation limitation rather than a Swift prohibition on statements in
all getters. An upstream scope-discovery patch or a smaller adapter/fork is a legitimate alternative to a new engine.
The new tool is justified by integrated execution/evidence policy and compiler/context experiments, not by pretending
the reference implementation lacks optimizations it already has. Other tools in the comparison were not rerun here.

## Expression probes and their limits

The preserved successful probe type-checks with Swift 6, warnings-as-errors, strict memory safety and ExistentialAny,
including SwiftUI body/modifier expressions, initializers, default arguments, a getter, guard, typed throws and await.
A macOS harness switches an atomic and observes `original: false mutant 6: true`. The primitive Bool truth tables pass.
A first generic typed-throws/autoclosure helper did not compile; that rejects the attempted design, not every helper.

For primitive Bool and fixed activation `m`, `&&`→`||` can be represented as `a ? (m || b) : (m && b)` and `||`→`&&` as
`a ? (!m || b) : (!m && b)`. These formulas alone do not prove preservation of arbitrary Swift overloads/effects,
ownership/lifetimes, result-builder type inference, autoclosures, inout/exclusivity or typed throwing contexts.
Nested textual rewrites can explode AST size. Litmus therefore uses non-overlapping bounded batches and actual inactive
controls, rather than claiming all 4176 sites can safely inhabit one build. Compile-time inflation remains unmeasured.

Per-test runtime coverage also needs more than a callback: Swift Testing public trait installation, XCTest observation,
parameterized IDs, detached work, callbacks, setup/teardown and global initializers all need validated attribution.
Unknown context must widen selection; it cannot produce a no-coverage verdict. The initial implementation uses full suites.

## What the family contributes

| Project | Direct reuse or lesson | Boundary |
| --- | --- | --- |
| analyzerkit | Corpus/discovery, canonical paths, classification, regions, suppression, reports, bounded processes | Not an existing mutation/build/simulator engine |
| aemi | Bounded parallel maps, kernel hashes and byte/runtime utilities | Fast identity hashes are not integrity/authenticity |
| AemiJSON | Typed bounded configuration/artifacts, deterministic model encoding | Report encode failure must throw, not manufacture `{}` |
| AemiProtobuf | Versioned bounded binary artifact envelope | Initial JSON payload envelope is not native field-level cache acceleration |
| swift-search | Resolved index navigation and future candidate test hints | Not a sound complete test-reachability graph |
| deadwood | Reachability/regions/prioritization | Never silently remove sites or label negation equivalent |
| dolly | Clone grouping/presentation | Tests at different clone sites may differ; no verdict sharing |
| fcheck | CFG/path obligations; future cleanup/durability operators | A static warning is not an executable mutation oracle |
| modeler | Effects/interleaving preconditions; future concurrency operators | An overapproximate model is not proof of a kill |
| arcleak | Ownership/capture/token operator inspiration and explicit lifetime oracles | A successful test process is not evidence of absence of leaks |

analyzerkit's CompilationConditions at the inspected revision requests filtering when defines are nonempty; it has fixed
Swift/compiler defaults and does not model `canImport`. Complete per-target Xcode conditions require real build-settings
integration. BoundedProcess strips DEVELOPER_DIR unless explicitly overridden and cannot clean independent simulator daemons.
Family FNV fingerprints include line/column; they are diagnostic baselines, not stable semantic execution-cache keys.
Unchanged file bytes alone cannot justify verdict reuse when tests, dependencies or build configuration change.

## Performance model: scenarios, not a promised runtime

Let B be total schema build time, M mapping/control cost, C executed mutants, L launch/install overhead, t selected tests,
W effective workers and R retries/confirmation. Then T ≈ B + M + Σ(L_i+t_i+overhead_i)/W + R. Not all terms parallelize.
Using 2000 mutants and four effective workers gives the following hypothetical mutation-execution component:

| Assumed L+t per mutant | Worker time | Idealized wall time |
| ---: | ---: | ---: |
| 2 s | 1.11 h | 16.7 min |
| 10 s | 5.56 h | 83.3 min |
| 30 s | 16.67 h | 250 min |
| 60 s | 33.33 h | 500 min |

Builds, controls, retries and resource contention are additional. Neither 2000 nor these latencies is derived from the
2098 name-reference misses. The older 2344×100s≈65.1h calculation assumed a suite duration, not measured it; it is worker
wall time, not CPU time, and does not prove a weekly run infeasible. High launch overhead does not eliminate the value
of selection when the suite is larger; it only caps the speedup. Litmus initially trades some speed for confirmed kills.

## Weekly and release rollout

First qualify the reference app build and simulator path, then measure operator coverage, compile growth and launch/test
cost. Run a small module before a full corpus. Schedule weekly/manual runs on isolated runners, retain artifact provenance,
and scope release reports without presenting a historical run as fresh testing of a different release commit.

PR branch filters apply to the base branch. Reporting on PRs **from** `release/*` or `merge_release/*` requires checking
`github.event.pull_request.head.ref`; PRs into release branches are a separate policy. Branch-creation/push support is
optional, not a replacement for the requested PR behaviour. Recent merge history suggests several release refs point at
develop preparation merges, but does not establish creation events or a complete PR head/base audit. Some hotfix commits
are not ancestors of develop; possible cherry-picks require further inspection. No CI workflow was changed in this work.

Danger needs a release/pin, report-path arguments, provenance/freshness handling, missing-data policy and integration tests,
not only one invocation line. A copied old report with missing/stale files must be visibly incomplete and fail execution
validation. Final production go/no-go requires measured budgets and independent review; no calendar estimate is justified.
