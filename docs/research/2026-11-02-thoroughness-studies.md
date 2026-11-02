# Four thoroughness studies on fcheck — 2026-11-02

Subject: fcheck at the commit recorded in the evidence (`commit.txt`), 206 mutants of the current tier (negated
conditions, swapped ternaries, swapped `&&`/`||`), 152 Swift Testing test functions (8 parameterized) in one module.
Litmus 0.3.0-dev, release. Two runs feed the studies:

- **Confirmed run** (defaults: targeted kill confirmation, flaky probe, test-target selection): 175 killed, 1 crashed,
  23 survived, 6 no coverage, 1 unviable, 85.85 %, every kill confirmed by named tests.
- **Study run** (`--no-fail-fast --per-test-reach --kill-confirmation none --baseline-repetitions 1`): 178 killed,
  1 crashed, 20 survived, 6 no coverage, 1 unviable, 87.32 %, 1797 s. Every mutant runs the whole suite, and every test
  runs alone once per schema build with markers on.

Scripts: `docs/research/studies/{matrix,tce,infection}.py`. Evidence: `~/Public/Litmus-Implementation-Evidence/study-2026-11-02/`.

## 1. Kill matrix and subsumption

| Measure | Value |
| --- | --- |
| Killed mutants with named killing tests | 178 of 178 |
| Distinct killing-test sets | 130 |
| Minimal (subsuming) groups | **38**, holding 65 mutants |
| Subsumed kills (any test that kills a minimal mutant kills them too) | 113 (63 %) |
| Mean killing tests per mutant | 6.97 |
| Tests that kill no mutant | **19 of 152** (deep-nesting, caching and parse-robustness tests: they guard behaviour these operators do not touch) |
| Tests that are the only killer of some minimal group | 25 |

The score counts 178 kills; the subsumption view says the suite's strength over this tier rests on 38 independent
faults. Two thirds of the kills add no information about the tests. A minimal-mutant score is the measure redundant
mutants cannot inflate; it needs the full matrix, so it costs a `--no-fail-fast` run (here 1797 s against 1933 s for
the confirmed run, which stops at the first failure but confirms each kill).

## 2. Trivial compiler equivalence (TCE)

Each survivor applied as plain source, its target rebuilt in release (about 8 s), the object files compared with debug
information stripped (code, data, symbols and relocations). Thirty killed mutants as a control.

| | Different code | Same code (equivalent) |
| --- | --- | --- |
| Survivors (23) | 23 | **0** |
| Killed controls (30) | 30 | 0 |

Both originals rebuild to identical objects, so the comparison is deterministic, and no killed mutant is "equivalent", so
it is sound on this sample. No survivor of this tier is provably equivalent: each changes the compiled code. Expected:
these three operators are the low-equivalence ones (swift-mutation-testing's campaign reviewed 7–9 % equivalent
survivors for them). TCE becomes worth its cost with the wider tiers (relational, arithmetic, removal: 27–33 % reviewed
equivalent in the same campaign), where it can remove survivors without a human.

Two mistakes on the way, both caught by the control: `otool` accepts one `-s` only (the first version hashed
relocations alone), and Swift Build puts objects in `<Target>-t.build` (the second found none and called every mutant
equivalent). The script now hashes whole stripped objects and fails when it finds none.

## 3. Infection

For a swapped `&&`/`||`, the value changes only when the operands differ. The suite ran once on a copy instrumented to
record, per site, whether it ran and whether its operands differed; only operands without calls, subscripts, closures,
force unwraps or `try` were instrumented (evaluating both operands is sound only then).

| Logical survivors (12) | Count |
| --- | --- |
| Not measurable (operands with calls or subscripts) | 9 |
| Infected (operands differed at least once), change not propagated | 2: `ResourceRule.swift:176`, `TypeScope.swift:40` |
| **Reached, never infected** | 1: `ResourceRule.swift:230` `lost.name == acquisition.name && lost.site != node.id` |

The never-infected survivor names the missing test precisely: no test makes a lost acquisition with the same name come
from another site. The infected ones are assertion gaps instead: the wrong value was computed and no expectation looked.
Negated conditions are always infected when reached; swapped ternaries are infected when the arms differ, which is
static for literal arms. A schema-level infection marker is therefore worth it for logical operators (and relational
ones in the next tier), limited by side effects: three quarters of fcheck's logical survivors could not be measured.

## 4. Per-test reach and selection

| Measure | Value |
| --- | --- |
| Reached mutants with per-test reach data | all |
| Mean tests reaching a mutant | 38.5 of 152 (a quarter) |
| Whole suite, alone | 8.5 s |
| Reaching tests, each run alone, summed | 18.6 s per mutant |
| Kills by a test that does not reach the mutant | **3** |

Per-test selection must run a mutant's reaching tests together, in one process (`--filter` for each): one test alone
costs about 100 ms of process start, so running them one by one is twice the whole suite. Together they are a quarter of
the suite's tests, which matters most for survivors (they run everything).

The three kills by a test that does not reach the mutant are exactly the three that targeted confirmation turned into
survivors: all three by `CallSiteScalingTests` ("four times the chain costs about four times the time"), a timing test
that fails under load whatever is mutated. Per-test reach is therefore also a confirmation that costs no rerun: a kill by
a test that cannot reach the mutant is not the mutant's. The flaky probe did not find this test (it passes on an
unloaded machine).

The 28 whole-suite fallbacks of the earlier pilot: 15 had no failing test names after the first run, 13 had names whose
targeted rerun did not reproduce. With the monitor-based fail-fast (analyzerkit's `BoundedProcess`) every kill now has
names and confirms: 0 fallbacks. The pilot's logs were not kept, so the old cause is likely (the cancelled race lost the
names), not proven. Parameterized tests were not the cause: those same mutants are now confirmed, 8 of their confirming tests parameterized.

## What to build, in order

1. **Reach-based kill check** (from study 4): reject a kill whose failing tests do not reach the mutant; cheaper than
   confirmation reruns when reach is known, and it caught every false kill here.
2. **Selection by reach, in one process**, for survivors first.
3. **Minimal-mutant score** in reports, from a `--no-fail-fast` run (study 1).
4. **Infection markers** for logical and relational operators with side-effect-free operands (study 3).
5. **TCE** with the wider operator tiers (study 2).
