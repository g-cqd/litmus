# Review of the 2026-11-02 ask session: completeness and correctness

Source: `~/.local/state/ask/sessions/Users-user-Developer-app/20261102T010816Z-3cfcf9af.jsonl`
(479 entries, 20 user turns, 1 compaction, 3 model changes, 2 dropped connections, 1 rewound branch). Every
correction below was re-checked against the saved evidence, git history or the GitHub API on 2026-11-02, not from memory.

## 1. Requests and what was delivered

| # | Request | Delivered | Verdict |
| --- | --- | --- | --- |
| 1 | Investigate weekly mutation testing and reporting on PRs that create a release | Spike with swift-mutation-testing (SMT) 1.6.4: plan 4176 mutants, a 1-file run whose unmutated build failed after 8m43s; draft weekly and release design | Done; nothing runs on the app yet (the baseline build fails in SMT's sandbox) |
| 2 | Release PRs = `release/*` or `merge_release/*` of the last 3 months | Git-history analysis | **Partly wrong**, see C1 and C2; corrected here with the GitHub API |
| 3 | Can we build a faster tool from analyzerkit and our tooling? | Investigation note in `Github/notes/` | Done, with overclaims, see C3–C9; the note was never corrected in place (now marked superseded) |
| 4 | Tooling = analyzerkit, dolly, deadwood, fcheck, modeler, swift-search, arcleak; local clones | All seven read from `/Volumes/Personal/Github/g-cqd` | Done |
| 5 | Extensive, detailed report in `~/Public` (asked 3 times, then "where is the report?") | 1st attempt: evidence folder only, connection dropped. 2nd (rewound): scripts and outputs, dropped again. 3rd: `Swift-Mutation-Analyzer-Investigation.md` (12 KB) written only after the user asked where it was | **Incomplete**: shorter than planned (the plan aimed at 15–25 KB with verdict policy, caching, security and rollout sections), never presented as the answer to the request, and `mutation-testing-investigation-2026-11-02/` has no README tying its evidence to a report |
| 6 | Build an iOS mutation tool on analyzerkit, aemi, AemiJSON, AemiProtobuf, for Xcode projects and packages | `litmus`, 4 commits, 22 tests, real SwiftPM fixture run (2 killed, 1 survived), generic iOS Simulator build-for-testing | Done for host SwiftPM packages; **Xcode test execution never ran** (only a build); see §4 for defects found since |
| 7 | Better name | `litmus` (the naming question was declined; assumption stated) | Done |
| 8 | Principles, white paper, ADRs, diary, tasks and ideas tools, high-criticality rigour | White paper (R-01–R-12), 4 ADRs, 3 diary entries, roadmap, SECURITY.md, verification map; tasks t1–t6; ideas checked (none) | Done; certification explicitly not claimed |
| 9 | Is it working? / How fast? | Accurate answers: host packages yes, iOS unverified; 20.8 s for the 3-mutant fixture, one debug sample | Correct |
| 10 | Review project and session, improve performance, reliability, accuracy vs competitors | In progress: this review, defect list §4, competitor gap §3 | Code fixes not yet made |

## 2. Corrections to statements made during the session

| Id | Turn | Statement | Correct version | Evidence |
| --- | --- | --- | --- | --- |
| C1 | 67 | "One PR, #1509, was merged into `release/23.0.1`" | #1509 was merged into **`develop`** (2026-08-13). `release/23.0.1` carries a single-parent cherry-pick of it (`33cbc10afa`, committed by another author on 08-17), plus two direct commits. **No PR had a head or base of `release/*` or `merge_release/*` since 2026-06-15** | `gh pr view 1509`; `gh pr list --state all --limit 400` (the 400 most recent PRs reach back to 2026-06-15) filtered on head and base |
| C2 | 67 | "25.0.0 → 26.0.0 changes 227 files: about 643 mutants, 285 incompatible" | The saved script gives **966 mutants, 371 incompatible** for 25→26 and **1079 / 364** for 24→25 (files outside ModuleUI, mutants counted in today's plan) | `mutation-testing-investigation-2026-11-02/evidence/outputs/release-scope.txt` |
| C3 | 187, note | "2098 is an upper bound on mutants no test reaches" | Neither an upper nor a lower bound: indirect callers are not counted, and a named type does not prove the expression runs | `static_test_reach.py`; already corrected in the Public report, **not** in the note |
| C4 | 187, note | "Danger reads it unchanged: one more line" | Needs a release pin, a results argument, freshness and missing-data handling, and tests | `Analyzer+StaticAnalysis.swift` hardcodes the arguments |
| C5 | 187, note | "Helpers are ruled out" | One generic typed-throws helper design failed; other helpers were not tried | `Failed-Helper-Probe.swift` |
| C6 | 187 | "A cold build takes about 6.5 min" | Inferred from product timestamps of a run that never finished testing; not a benchmark | `coverage-attempt-*-tail.log` |
| C7 | 187 | "SMT's docs blame default parameters and initializers, a tiny share" | SMT documents default parameters, **stored property initialisers**, global initialisers and enum raw values. The 730 bucket mixes computed and stored properties, so stored initialisers may be a large share. The SwiftUI share comes from SMT's scope visitor skipping implicit getters | `Docs/MUTATION-RESULTS.md` §"What makes a mutant incompatible"; `TypeScopeVisitor.swift` |
| C8 | 187, note | Static index or name references give "a safe superset" of tests | Not sound: dynamic dispatch, callbacks, macros and unindexed code. They can only order tests, never prove absence | Already corrected in the Public report and the Litmus white paper (R-11) |
| C9 | note | "The existing tool cannot tell inactive `#if` clauses" | SMT 1.6.4 has `InactiveRegionExtractor` and `HostBuildConfiguration` (with `canImport`) | pinned v1.6.4 source |
| C10 | 55 | "Packages fail alone because the sandbox holds only the project root" | Plausible, but never run; unverified | — |
| C11 | Report, investigation | Comparison of Litmus with SMT | **Incomplete.** It credited SMT with schema batches, caches and `#if` handling, but missed what SMT 1.6.4 already does and Litmus does not (§3) | `Docs/MUTATION-RESULTS.md`, `USAGE.MD`, `OPERATORS.md` |

Statements re-checked and found correct: 4176 / 2344 / 1832 mutants in 2493 files; the per-operator split; deadwood
58 findings in 2981 files (detect 2.06 s, scan 0.90 s); 6 and 51 region overlaps; CI step durations (median 200 s) and
28/30 successful runs; release tips cut at the `release_preparation` merges; SMT has no `--files-to-mutate`; the Litmus
answers to "is it working" and "how fast" (9 full-suite invocations, 20.8 s wall).

## 3. Litmus against the closest competitor (SMT 1.6.4)

| Capability | SMT 1.6.4 | Litmus 0.1.0-dev |
| --- | --- | --- |
| Mutants inside view bodies, implicit getters, default arguments, property initialisers | 44% need a separate build | One schema per non-overlapping batch: **Litmus is ahead** (but see D2) |
| No coverage (mutated code never ran) | Marker file per mutant | **Missing**: an unreached or uncompiled site is reported as *survived* (D7) |
| Integrity check (killed without activation) | Yes, rerun alone, warning | Missing |
| Crash = killed | "Killed by crash" | **Missing**: a crash is an infrastructure error (D5) |
| Timeout | Detected, after an isolated rerun | Unresolved; the run can never be green (D6) |
| Unviable mutants | Isolated, excluded from the score | **Missing**: one bad mutant fails its whole batch (D4) |
| Speed per mutant | Stops at the first failing test; tests named after the file run first | Full suite, plus 2 confirmation runs per kill |
| Parallel workers | CPUs − 1; runs SwiftPM bundles directly (no `.build` lock); one simulator clone per worker | Serial, via `swift test` |
| Operators | 7, with tiers set by a measured campaign (kill, unviable, equivalent rates) | 3, no campaign |
| Reports | Stryker JSON, HTML, Sonar, SARIF, Markdown, quality gate, `reproduce` | Family JSON envelope, SARIF, Xcode; no score, no Stryker schema |
| Kill confirmation, source isolation, provenance and staleness checks | Partial (sandbox copy; baseline scope) | **Litmus is ahead**: two failing runs around a passing control, independent snapshot, SHA-256 inventory |
| Real-world validation | Campaign on 5 projects; fails on this app's baseline build | One 3-mutant fixture; never run on the app or a simulator |

The session's positioning ("faster because of expression schemas and test selection") is only half true today:
expression schemas are a real advantage, but SMT already has coverage markers, fail-fast and parallel workers, which
Litmus lacks, and Litmus' confirmation runs cost up to three full-suite runs per kill.

## 4. Defects found in Litmus during this review (confirmed by probes)

| Id | Defect | Consequence | Probe |
| --- | --- | --- | --- |
| D1 | `replace-logical` rewrites by text without parentheses: the outer `||` of `a \|\| b \|\| c` becomes `a \|\| b && c`, i.e. `a \|\| (b && c)` | A different mutant than the one reported; wrong attribution | `/tmp/lp/prec.swift`: replacement `true`, intended `false` |
| D2 | The selector is `private`: a mutated default argument of a public function, or an `@inlinable` body, does not compile | The whole batch becomes "infrastructure error" | `/tmp/lp/Cur.swift`: two compiler errors |
| D3 | The selector is appended at the end of the file; in `main.swift` (top-level code) it is read before it is initialised | Segmentation fault of the subject | `/tmp/lp/m/run`: exit 139 |
| D4 | A failing schema build marks every mutant of the batch unresolved | No unviable verdict; batches poison each other | code review |
| D5 | A crashing test process gives no structured evidence → infrastructure error | Crash kills are lost; runs are not green | code review |
| D6 | Fixed 120 s test deadline, and a timeout is never resolved | Infinite-loop mutants (`while` negation) cost 120 s each and make the run fail | code review |
| D7 | No activation record | Sites in files the scheme does not compile, or never reached, are reported as survivors | code review |
| D8 | Serial `swift test` per mutant, full suite, no fail-fast | Slow; SwiftPM's `.build` lock prevents parallel runs | code review, SMT `USAGE.MD` §Parallelism |

A replacement design for D2/D3/D7 was probed: one `@usableFromInline nonisolated internal let` per mutant, initialised
once, whose initialiser records the activation (a marker file) and compares the selector. It type-checks for iOS 17 under
Swift 5 and 6 modes, default MainActor isolation, strict memory safety, ExistentialAny, InternalImportsByDefault,
MemberImportVisibility and library evolution, including a public default argument, an `@inlinable` body, a SwiftUI body,
an actor method, a nonisolated async function and typed throws (`/tmp/lp/Lib.swift`). It also turns the per-evaluation
string comparison into a once-initialised Boolean. `main.swift` still needs the declarations before the top-level code.

## 5. Process findings

- **The report was late.** The agent researched for three report attempts instead of writing; two connection drops and a
  rewind lost work, and a later branch did not know that an earlier one had created `~/Public/mutation-testing-…` (turn 206
  says "I didn't create it"; turn 192 had). Write the deliverable first, then extend it.
- **Corrections did not reach the earlier artefacts.** The overclaims of turn 187 were fixed in the new report but stayed
  in the note in `Github/notes/` and in the chat history.
- **Release-PR facts were taken from merge-commit subjects** rather than the GitHub API, which led to C1.
- **Builds:** 13 package debug builds for the initial implementation, above the ~4 budget; the causes are recorded in
  `docs/verification.md`.
- **Good practice kept:** red tests committed first (`c9752b1`), structured test evidence instead of console parsing (it
  caught the split Swift Testing XML), no change to the app or the family repositories, no simulator service restart.

## 6. Next steps (tracked as tasks)

1. Fix D1–D3 with the probed design and red tests; add activation (D7) and a no-coverage verdict.
2. Unviable isolation by bisecting failing batches (D4); confirmed crash and timeout verdicts with a deadline derived
   from the baseline duration (D5, D6); Stryker-compatible score.
3. Performance: run SwiftPM test bundles directly to allow workers; fail-fast on the Swift Testing event stream; measure.
4. Operators: relational, boolean literal, arithmetic as an opt-in tier, once unviable isolation exists.
5. Live simulator run of the fixture, then the app on a `mobile` runner.
