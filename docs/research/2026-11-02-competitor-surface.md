# What other mutation tools offer that Litmus does not — 2026-11-02

Sources: the documentation pages fetched on 2026-11-02 and kept in
`~/Public/Litmus-Implementation-Evidence/study-2026-11-02/competitors/` (Stryker JS and .NET configuration, mutant
states, incremental and disabling pages; PIT Maven quickstart and incremental analysis; cargo-mutants book pages;
mutmut, infection, muter, Mull, mutant (Ruby) and gremlins READMEs), and swift-mutation-testing 1.6.4's own
documentation (`Docs/USAGE.MD`, `OPERATORS.md`, `STRYKER-COMPATIBILITY.md`). Claims below cite the tool whose page says
so; nothing here was run except swift-mutation-testing.

## Already covered by Litmus

Schemata (one build per batch: Stryker, muter, SMT), fail-fast per mutant (cargo-mutants, PIT), parallel workers,
timeouts derived from a baseline (Stryker `timeoutFactor`, PIT `timeoutFactor`/`timeoutConstant`), a baseline run that
must pass (cargo-mutants `--baseline`), no-coverage status (Stryker `NoCoverage`), compile errors outside the score
(Stryker `CompileError`), suppression comments (Stryker `// Stryker disable`, cargo-mutants `#[mutants::skip]`, Mull
annotations, muter `// muter:disable`), SARIF and JSON reports, a quality gate.

Litmus goes further than every tool listed on: activation evidence for every verdict (a kill whose code never ran is not
a kill; SMT counts those as "integrity warnings" in its score), targeted kill confirmation and flaky-test exclusion
(none of the tools above re-checks a kill or probes for flaky tests), process cleanup beyond the process group, and
journalled, digest-checked evidence.

## Surface Litmus is missing

| Feature | Who has it | Value for Litmus | Effort |
| --- | --- | --- | --- |
| **Incremental runs**: reuse verdicts of mutants whose code and tests did not change | Stryker (`incremental`, a git-like diff against `stryker-incremental.json`), PIT (`withHistory`), mutmut (per function), Mull, SMT (result cache) | High: a weekly app run re-tests only what changed. The journal already holds per-mutant verdicts with source fingerprints | Medium: needs a test-side fingerprint (which tests could reach a mutant: test-target selection gives it) |
| **Diff mode**: mutate only lines changed in a PR | cargo-mutants (`--in-diff`), infection (`--git-diff-filter`, `--git-diff-lines`), Stryker (`since`), mutant (`--since`) | High: the PR gate the original request asked about (release PRs) | Low: plan filter on a unified diff |
| **Sharding** across machines, then merge | cargo-mutants (`--shard k/n`), SMT (`plan`, `run --shard`, `merge`) | Medium: CI matrix for the app | Low–medium: plan already deterministic; needs a merge command |
| **Plan / reproduce one mutant** with the sandbox kept | SMT (`reproduce`), mutmut (`apply`), Mull (generate patches) | Medium: debugging a survivor | Low |
| **Baseline comparison gate**: fail on new survivors or a score drop | SMT (`--baseline`, `--max-new-survivors`, `--max-score-drop`), PIT thresholds | High for CI | Low: Litmus `analyze` has a gate; add baseline diff |
| **Stryker report schema** (HTML dashboard, Stryker Dashboard) | Stryker family, SMT (Stryker JSON v1) | Medium: free HTML report and dashboard | Low: a reporter |
| **Static mutants** handled separately (code run at load time, which schemata cannot switch per test) | Stryker (`ignoreStatic`, "static mutants") | Medium: Swift globals and `static let` initialisers run once per process; Litmus' per-process activation already handles them correctly, but their cost (whole suite) is not reported | Low: classify and report |
| **Type-checker filtering** of mutants before running | mutmut (type checker), Stryker (`checkers`: TypeScript), infection (`--static-analysis-tool`) | Medium: Litmus' unviable isolation finds them by building; a `-typecheck` prefilter of risky operators would save builds (the census showed which shapes fail) | Medium |
| **Test strength** (killed ÷ killed + survived, coverage excluded) as a separate gate | PIT (`testStrengthThreshold`), infection (`--min-covered-msi`) | Medium: separates "untested code" from "weak tests" | Low: both numbers are in the artifact |
| **Full mutation matrix** (every test against every mutant) | PIT (`fullMutationMatrix`) | High for thoroughness (study 1) | Medium: `--no-fail-fast` plus per-test results |
| **Per-test coverage** to run only covering tests | Stryker (`coverageAnalysis: perTest`), PIT, infection (`--only-covering-test-cases`), gremlins | High on large suites (study 4) | Medium–high in Swift: activation is per process |
| **Error-value / default-return operators** | cargo-mutants (`Err` values, default returns) | High: the census's "return default" tier | Medium (operator work, t11) |
| **Skip calls / functions by name** | cargo-mutants (`--skip-calls`), Stryker (`ignorers`), infection | Medium: logging, analytics, assertions | Low |
| **Mutation levels / tiers measured by campaign** | Stryker.NET (`mutation-level`), SMT (tiers from a measured campaign) | High, already planned (t11) | Medium |
| **Xcode integration** (run from an Xcode scheme, annotations in the editor) | muter | Medium for iOS teams | Medium |
| **Interactive browsing of survivors** | mutmut (terminal UI), mutant (`session subject`) | Low–medium | Medium |
| **Dry run / list** with diffs, no execution | cargo-mutants (`--list --diff`), Stryker (`dryRunOnly`) | Low: `litmus plan` exists, without diffs | Low |
| **Jobserver** bounding all subprocesses together | cargo-mutants | Low: workers are sized from the suite's parallelism | — |

## Recommended order

1. Diff mode and a baseline comparison gate: the PR use case, both small.
2. Incremental runs keyed on source fingerprint and selected test targets: the weekly app run.
3. Sharding and merge; Stryker JSON reporter.
4. Full matrix and per-test coverage (studies 1 and 4), operators by tier (t11).
