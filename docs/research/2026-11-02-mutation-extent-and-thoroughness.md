# How far Litmus' mutations can go, and how thorough a run can be

Investigation, 2026-11-02. Nothing here is implemented as an operator yet; what is implemented is the measuring
instrument (`litmus census`) and one compatibility fix found while piloting on a real package.

## Summary

- **Extent.** Litmus mutates 3 kinds of site (4,149 mutants on the app). A syntax census finds **33 candidate kinds**
  in Swift code. Proposed tiers take the app to about **15,900** (standard), **33,000** (extended) and **48,700**
  (exhaustive) mutants, and the six family packages measured together from 4,779 to 14,802, 27,939 and 46,209.
- **Fit.** 27 placements covering the standard and extended tiers' shapes (all but `!` and unary-minus removal, which
  are plain expression replacements) compile **to object code** together in one
  schema, for the iOS 18 Simulator, under Swift 6 strict memory safety with ExistentialAny, default MainActor
  isolation, and Swift 5 mode; four predicted failures fail as predicted. So one batched build can hold them, as it
  holds today's three.
- **Swift-specific operators no competitor has:** forcing an optional binding to `nil`, dropping the left side of
  `??`, skipping a `switch` case to its `default` with an injected `where !m`, skipping a loop with `for … where !m`,
  and removing a `defer`. Two Swift properties make them cheap: optionals and `where` clauses.
- **Thoroughness** depends less on operator count than on four mechanisms Litmus can add on top of activation
  markers: a per-test kill matrix, subsumption-reduced scoring, a compile-time equivalence check on survivors only,
  and infection recording for side-effect-free operands.
- **Cost.** Extended-tier mutants are 8× today's on the app. Builds grow with sites, not mutants, but test runs grow with
  mutants. Without per-test selection, the extended tier is a weekly-at-most mode on the app.

## Evidence

| Source | What it gives |
| --- | --- |
| Stryker "Supported mutators" page, PIT "Mutators" page, cargo-mutants `book/src/mutants.md`, muter `Docs/mutation_operators.md` (fetched 2026-11-02) | Operator catalogues of the reference tools |
| swift-mutation-testing 1.6.4 `Docs/OPERATORS.md`, `Docs/operators/results.md`, `equivalence.csv` | Measured kill, unviable and reviewed-equivalent rates of 7 Swift operators over 5 projects |
| `litmus census` (new): app worktree `0d9f8e72d6` and AemiJSON, AemiProtobuf, analyzerkit, deadwood, fcheck, modeler at their HEADs | Sites and mutants per candidate operator, production files only, previews and debug code excluded |
| `docs/research/probes/OperatorShapes.swift`, `UnviableShapes.swift`, `ImplicitReturn.swift` | Which shapes compile; compiled to object code, not only type-checked |
| Four Litmus runs on fcheck (206 mutants of the current tier) | How thorough today's verdicts are on a real package, and what makes them wrong |

Methodological finding: `swiftc -typecheck` accepts a statement inserted before an implicit return; the "missing
return" error appears only in SIL generation. Shape probes must compile (`-c`), and so must any future pre-check.

## Census

Sites / mutants per candidate operator. `b` = statement sites inside result builders (`var body: some View`,
`@…Builder`), not counted, because `if !m { … }` is not a valid builder statement.

| Operator | Shape | App | AemiJSON | AemiProtobuf | analyzerkit | deadwood | fcheck | modeler |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| negate-condition (current) | expression | 2830/2830 | 1364/1364 | 769/769 | 489/489 | 471/471 | 132/132 | 206/206 |
| swap-ternary (current) | expression | 766/766 | 128/128 | 185/185 | 88/88 | 29/29 | 23/23 | 37/37 |
| logical-replace (current) | expression | 553/553 | 276/276 | 204/204 | 119/119 | 104/104 | 50/50 | 105/105 |
| relational-equality `==`↔`!=` | expression | 1716/1716 | 647/647 | 538/538 | 320/320 | 222/222 | 105/105 | 184/184 |
| relational boundary and negation | expression | 365/730 | 661/1322 | 256/512 | 153/306 | 132/264 | 20/40 | 33/66 |
| optional-binding-to-nil | expression | 1902/1902 | 441/441 | 421/421 | 274/274 | 214/214 | 151/151 | 190/190 |
| nil-coalescing-to-default | expression | 710/710 | 58/58 | 110/110 | 88/88 | 78/78 | 56/56 | 63/63 |
| return default: Bool (true, false) | statement | 886/1772 | 127/254 | 74/148 | 92/184 | 69/138 | 19/38 | 13/26 |
| return default: String ("", "xyzzy") | statement | 745/1490 | 72/144 | 93/186 | 70/140 | 36/72 | 16/32 | 21/42 |
| return default: number (0, 1) | statement | 326/652 | 117/234 | 74/148 | 22/44 | 17/34 | 4/8 | 3/6 |
| return default: nil | statement | 573/573 | 108/108 | 122/122 | 69/69 | 24/24 | 20/20 | 28/28 |
| return default: empty collection | statement | 318/318 | 86/86 | 93/93 | 85/85 | 82/82 | 19/19 | 21/21 |
| return early (Void) | statement | 1917/1917 | 270/270 | 232/232 | 66/66 | 91/91 | 20/20 | 39/39 |
| return default, type without a default value | — | 2199 (b1116) | 245 | 161 | 155 | 106 | 69 | 68 |
| void-call-removal | statement | 9010 (b7368) | 1263 | 1305 | 692 | 699 | 188 | 368 |
| cleanup-call-removal (fcheck) | statement | 327 (b11) | 16 | 6 | 14 | 8 | 0 | 13 |
| defer-removal (fcheck) | statement | 63 (b7) | 13 | 4 | 15 | 0 | 0 | 0 |
| throw-removal | statement | 271 (b6) | 262 | 291 | 53 | 30 | 18 | 19 |
| break-continue-swap | statement | 124 (b3) | 107 | 57 | 78 | 88 | 14 | 32 |
| await-statement-swap (modeler) | statement | 62 (b4) | 0 | 0 | 0 | 0 | 0 | 0 |
| arithmetic-replace | expression | 1290 | 599 | 410 | 173 | 84 | 26 | 44 |
| compound-assignment-replace | expression | 132 | 389 | 178 | 97 | 47 | 6 | 26 |
| bitwise-replace | expression | 44 | 167 | 79 | 46 | 13 | 1 | 0 |
| range-boundary `..<`↔`...` | expression | 103 | 89 | 50 | 54 | 12 | 3 | 6 |
| boolean-literal-flip | expression | 2936 | 380 | 256 | 216 | 177 | 55 | 69 |
| not-removal | expression | 726 | 143 | 174 | 86 | 126 | 47 | 57 |
| unary-minus-removal | expression | 49 | 12 | 13 | 2 | 2 | 1 | 0 |
| isEmpty-negation | expression | 342 | 46 | 89 | 67 | 66 | 23 | 45 |
| collection-method-swap (`first`/`last`, `min`/`max`, …) | expression | 399 | 107 | 186 | 211 | 75 | 80 | 56 |
| collection-method-removal (`sorted`, `filter`, …) | expression | 299 | 17 | 46 | 51 | 59 | 43 | 62 |
| switch-case-skip to `default` | clause | 785 | 253 | 319 | 158 | 98 | 11 | 14 |
| loop-skip (`for … where !m`) | clause | 156 | 137 | 203 | 167 | 225 | 53 | 102 |
| condition-to-constant (`true`, `false`) | expression | 2830/5660 | 1364/2728 | 769/1538 | 489/978 | 471/942 | 132/264 | 206/412 |
| integer-literal-replace | expression | 4139/6654 | 2344/3712 | 1175/1755 | 718/1025 | 330/435 | 101/136 | 134/159 |
| string-literal-empty | expression | 3315 | 628 | 1362 | 770 | 591 | 402 | 433 |

Kept out by construction (counted to show the size): string literals passed to logging and assertions (app 642),
`switch` cases without a `default` (app 2997: a `where` guard breaks exhaustiveness), `+` with a string literal operand
(app 110), and `[weak self]` captures (app 310, see arcleak below).

Totals by proposed tier (cumulative):

| Tier | Operators | App mutants | Six packages |
| --- | --- | --- | --- |
| current | negate-condition, swap-ternary, logical-replace | 4,149 | 4,779 |
| standard | + relational (both), optional-binding-to-nil, nil-coalescing-to-default, return defaults (all typed kinds, Void early return) | 15,929 | 14,802 |
| extended | + void-call and cleanup-call removal, defer and throw removal, break/continue swap, arithmetic, compound assignment, bitwise, range, boolean literal, `!` and unary minus removal, `isEmpty`, collection swaps and removals, switch-case skip, loop skip | 32,985 | 27,939 |
| exhaustive | + condition-to-constant, integer and string literals, await swap | 48,676 | 46,209 |

The census is syntax-only. It cannot see types: some `<` sites compare non-`Comparable` types that define only `<`,
some `+` concatenate strings without a literal, some return types are type aliases of `Bool`. These become unviable
mutants in the schema build, which isolates them (ADR 0005), at the price of extra builds.

## Operator catalogue

Reference tools: **S** Stryker (JS/.NET/Scala), **P** PIT, **C** cargo-mutants, **M** muter, **X**
swift-mutation-testing 1.6.4. X's numbers: median kill rate / unviable / reviewed equivalent, over 5 projects.

| Operator | In | Measured elsewhere | Shape and schema | Risks | Recommendation |
| --- | --- | --- | --- | --- | --- |
| Relational boundary and negation (`<`→`<=`, `>=`) and equality | S, P, C, M, X | X: 82.7% / 7.4% / 32.6% | expression; `<`, `<=`, `>`, `>=` produce 2 variants | Boundary mutants are often equivalent (index loops) | **standard**, after a campaign confirms the unviable rate |
| Optional binding to `nil` (`if let x = (m ? nil : e)`) | none | — | expression inside the binding; forces the `else` path | Shorthand `if let x` needs `= x`; equivalent when both paths agree | **standard**: Swift's commonest control flow, 1902 sites on the app |
| `??` to its default (`a ?? b` → `b`) | S (`??`→`&&` only) | — | expression; same type as the whole | Equivalent when `a` is always nil in tests | **standard** |
| Return default (`if m { return false }`; single-expression bodies `(m ? false : (e))`) | P, C | C's main genre | statement prefix, or expression for implicit returns | Not for types without a default (2199 app functions); the probe shows a statement before an implicit return does not compile, so the expression form is required there | **standard** for Bool, numbers, String, Optional, collections, Void |
| Void call removal (`if !m { call() }`) | P, M, X (RemoveSideEffects) | X: 69.3% / 1.9% / 27.8%, the most expensive per mutant (19.6 s) | statement; blocked in builders | Logging, cache and metrics calls are often equivalent; loops that only progress through the call can hang | **extended**, with an exclusion list as muter's `excludeCalls` |
| Cleanup removal: `defer`, `close`/`cancel`/`unlock`/`finish`/`resume` | none (fcheck's obligations) | — | statement; `defer { if !m { … } }` | Only tests that observe leaks or the state after release kill it | **extended**; reports should say which obligation the survivor leaves untested |
| Throw removal (`if !m { throw e }`) | none | — | statement | Unviable when the throw ends a path that must return | **extended** |
| Break/continue swap | P (experimental switch), S (none) | — | statement | Can hang loops (timeout verdicts) | **extended** |
| Arithmetic, compound assignment, bitwise, unary minus | S, P, C, X | X arithmetic: 88.9% / 12.1% / 27.3% | expression | String `+`; overflow traps (crash verdicts) | **extended** |
| Range boundary `..<`↔`...` | none directly (S regex) | — | expression; types match | Out-of-range crash, counted as a crash kill | **extended** |
| Boolean literal flip | S, P, X | X: 73.6% / 11.5% / 27.9% (demoted to experimental) | expression | Configuration flags such as `atomically:` are equivalent | **extended**, excluding known-equivalent argument labels |
| `!` removal, `isEmpty` negation | S | — | expression | Overlap with negate-condition inside conditions | **extended**, outside conditions only |
| Collection method swap/removal (`first`/`last`, `min`/`max`, `sorted`, `filter`) | S (method expression) | — | expression when the types match (`first`/`last` both `T?`) | `prefix`/`suffix` on `String` return different types | **extended**, by an explicit list of type-preserving pairs |
| Switch case skip to `default` (`case .a where !m:`) | C (match arms) | — | clause | Only with a `default`; without, exhaustiveness fails (probe) | **extended** |
| Loop skip (`for x in s where !m`) | none | — | clause; an existing `where` becomes `(w) && !m` | Equivalent when the loop is empty in tests | **extended** |
| Condition to constant `true`/`false` | S, P | — | expression | Partly subsumed by negation | **exhaustive** |
| Integer and string literal replacement | P (inline constants), S (strings) | — | expression | High equivalence (log text, padding) | **exhaustive**, logging arguments excluded |
| Await statement swap (modeler) | none | — | statement pair; only expression statements, never a declaration | Duplicates the two statements; reorders effects | **research**; 62 sites on the app |
| `[weak self]` to strong (arcleak) | none | — | clause | Unviable whenever the closure unwraps `self` (probe: `guard let self` on a non-optional); killed only by a test that asserts deallocation | **research**; needs a lifetime oracle, such as an arcleak-style deinit expectation |
| Higher-order (two mutants at once) | research tools | — | activation of a set | Combinatorial; masks | **not planned**; sample only if subsumption data asks for it |

Family inspiration, summarised: **fcheck** gives cleanup and obligation operators and the vocabulary to report
"obligation never tested". **modeler** gives the await-swap and lock-gap candidates, research only. **arcleak**
shows that ownership mutants need a lifetime oracle, not more operators. **deadwood** prioritises: a site in code it
reports unreachable will end `noCoverage`, so planning can schedule it last or skip building it. **dolly** groups
survivors in cloned code for review, never shares verdicts. **swift-search** can rank mutants by how many references
the enclosing declaration has, for sampling.

## Pilot: fcheck, current tier, four runs

fcheck `2c71f0a`, 206 mutants (132 negations, 50 logical swaps, 24 ternary swaps), 152 Swift Testing tests, debug
Litmus, on the shared 8-core machine (load 9–35).

| Run | Change | Wall | Verdicts | Score |
| --- | --- | --- | --- | --- |
| 1 | 0.2.0-dev as released | 1384 s | 126 killed, 25 timeout, 6 survived, 6 no coverage, **43 infrastructure errors** | n/a |
| 2 | reruns in a serial pass, twice the deadline among workers | 1564 s | 176 killed, 1 crashed, 22 survived, 6 no coverage, 1 infrastructure error | n/a |
| 3 | workers from the suite's parallelism (2), unviable by file | **650 s** | 180 killed, 1 crashed, 18 survived, 6 no coverage, 1 unviable | 88.29 % |
| 4 | targeted kill confirmation (default now), 3 workers | 1119 s | 175 killed, 1 crashed, 23 survived, 6 no coverage, 1 unviable | **85.85 %** |

What the runs showed (each a defect fixed the same day, see ADR 0005's amendment):

- **Contention fabricates detections.** Run 1's 25 timeouts were reruns competing with six workers; alone they were
  9 kills and 16 survivors. A tool that counts parallel-pass timeouts as detected overstates the score.
- **Oversubscription is slower, not faster.** fcheck's suite keeps 2.3–3.9 cores busy by itself; seven copies made
  first runs exceed 54 s against a 6.3 s suite. Two workers sized from the measured parallelism cut the run from 1564 s
  to 650 s (2.4×).
- **Activation proves the process ran the code, not that the failing test did.** In run 3, 10 kills rested only on
  `CallSiteScalingTests`, a timing test failing under load. In run 4, rerunning the failing tests alone, active then
  inactive, the timing test kills nothing: 5 of the 10 are survivors (as in run 2), and 5 are killed by other tests that
  fail-fast had not reached in run 3 because the timing test failed first. Targeted confirmation also attributes 147 of the 175 kills to
  named tests; 28 needed a whole-suite rerun (parameterized tests or tests that do not reach the mutant alone).
- **Scores move with conditions until confirmation is on.** Runs 3 and 4 differ by 2.4 points, all of it explained by
  the timing test. The remaining 23 survivors: 12 logical swaps (24% of that operator, against 12% for negations).

Run 4's wall time is the cost of the confirmation (two short runs per kill) on a machine at load 15–34; run 3's 650 s
was at load about 12. Not repeated enough to separate the two effects.

## Thoroughness beyond operators

1. **Per-test kill matrix.** Today a kill stops at the first failing Swift Testing issue and names the tests that
   killed it after confirmation (the pilot's first step towards a matrix). A `--kill-matrix` mode would
   run every reached mutant's whole suite and record each failing test from the event stream. This gives:
   which tests kill what; tests that kill nothing (redundant or tautological); flaky tests (a test failing for many
   unrelated mutants); and the input to subsumption. Cost: the full suite per covered mutant, no fail-fast.
2. **Subsumption-reduced score.** Many mutants are killed by exactly the same tests: one subsumes the others.
   Reporting the score over the minimal (dominator) set stops a tier with many easy mutants inflating it, and makes
   tiers comparable. It needs the kill matrix.
3. **Equivalence on survivors only.** Trivial compiler equivalence (compile the original and the mutant with `-O` and
   compare the machine code of the enclosing function) proves some equivalent mutants cheaply. The batched schema
   build cannot compare per mutant, but survivors are few: compiling only the survivors' files twice, alone, is
   affordable. Litmus would report them as `equivalent (proven)`, outside the score, with the evidence kept.
4. **Infection.** Markers prove the code was reached (R of RIPR), not that the value changed (I). For operators
   whose operands are side-effect free (literals, locals, parameters), the schema can evaluate both values and record
   a second marker only when they differ. "Reached, never infected" separates a test gap from an input gap.
5. **Coverage per test, then selection.** Markers recorded per test (Swift Testing test ID in the marker path) would
   let each mutant run only the tests that reached it, which is what makes the extended tier affordable on the app.
   It needs per-test process attribution, which XCTest's single-process runs do not give for free.
6. **Measured tiers.** Adopt X's method: a campaign over a corpus (the six family packages and the app), with
   kill rate, unviable rate, reviewed equivalent rate and cost per operator, and promote an operator only when it meets
   thresholds. X's numbers show why: boolean literals, relational and RemoveSideEffects each have about 28–33%
   reviewed-equivalent survivors.

## Cost

A batch holds at most 64 mutants (same-range variants share a replacement but still count), so builds grow with
mutants: the app's extended tier is about 515 builds at 64 per batch, 129 at 256, against 66 and 18 today. Large SwiftUI
schemas' compile time at 256 per batch is unmeasured. Test runs grow with covered mutants.
Today's app weekly projection is 18–66 builds plus one run per covered mutant. The extended tier multiplies the runs by
about 8, and the full kill matrix multiplies each run's length by the suite/first-failure ratio. Per-test selection
(item 5) is therefore a prerequisite for the extended tier on the app, not on the packages, whose suites are fast.

## Recommended order

1. Ship the standard tier behind `--operators standard`; run the campaign on the six packages; keep each operator only
   if its unviable rate stays under 15% and its reviewed-equivalent rate under 25% (X's `default` criteria).
2. Add the kill matrix and the subsumption-reduced score, so the tiers are compared on minimal mutants.
3. Add equivalence-on-survivors (TCE) and infection markers, to cut review time.
4. Per-test coverage and selection, then the extended tier on the app.
5. Research: await swap and lock-gap mutants (modeler), ownership mutants with a lifetime oracle (arcleak).

## Not verified

The census sees syntax only, so per-operator unviable rates are X's or unknown until Litmus' own campaign. The
probes prove that the shapes compile together, not that every site of each kind does. Kill rates of the new
operators on our packages are unmeasured. The builder detection (`body`, `@…Builder`) is a heuristic: statement sites
inside action closures within a builder are counted as blocked although valid.
