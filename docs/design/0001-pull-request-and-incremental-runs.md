# Design 0001 — Mutation testing on every pull request, incrementally

Status: accepted as the plan, 2026-11-02; decisions in ADR 0007. Phase 0 measured (below).

## Goal

Run Litmus on every pull request of `example/app` and of the family repositories, in the job that already builds
and tests the change, without straining the runner: bounded extra time, cores, memory and disk, a verdict on every mutant
the change creates, and no wrong verdict. Weekly or nightly full runs keep the rest of the codebase measured and feed
the pull-request runs with reusable data.

Family principles apply unchanged: performance, safety (never modify the subject outside an owned copy unless asked,
never follow links, never trust a cache it cannot verify), resilience (interruption leaves a resumable, consistent state)
and reliability (a reused or skipped result is labelled, never presented as fresh).

## What a pull request looks like (measured)

`develop` of the reference app, the 60 last merged pull requests (`docs/research/2026-11-02-pr-profile.md` holds the method):

| Per PR touching Swift (42 of 60) | Median | p75 | p90 | Max |
| --- | --- | --- | --- | --- |
| Swift files changed | 4 | 11 | 22 | 39 |
| Mutants on changed lines (current tier) | **1** | 4 | 9 | 52 |
| Mutants in changed files | 8 | 23 | 52 | 101 |
| Local packages touched | 1 | 2 | 3 | 7 |

17 of 42 (40 %) create no mutant at all on changed lines; 27 of 42 touch only local packages, not the app target. With
the extended operator tier (about 8× the sites, `litmus census`), the changed-line median is about 8 and p90 about 70.

**Consequence: a pull-request run is a handful of mutants. Its cost is fixed costs** (copy, builds, baseline), not
mutants. Today Litmus pays, for one mutant: a full copy, an unmutated cold build, a baseline suite, a flaky probe, a schema
build, a control run, then the mutant. The design removes fixed costs first.

## Cost model

For a run of *m* mutants in one schema batch:

    T = copy + plan + B_base + S + P_flaky + B_schema + S_control + Σ_mutants (t_first + t_confirm) + reruns

- *B* (builds) dominates on the app.
- *S* (suite) is the selected test targets' time; a package's tests are a fraction of the app's.
- *t_first* with fail-fast is short for kills, the whole selected suite for survivors.
- With Xcode, every test run pays the launcher's fixed cost, which dwarfs the tests themselves.

### Phase 0, measured (ModuleParts, the most changed package; `develop` copy, iPhone 17 simulator, loaded machine)

| Step | Time |
| --- | --- |
| `build-for-testing`, cold (fresh DerivedData, package graph of 8 local packages) | 285 s |
| `build-for-testing` after editing one source file | **19 s** |
| `build-for-testing` with nothing changed | 9 s |
| `test-without-building`, 211 tests (the tests themselves: 0.1 s) | 9–11 s |
| `test-without-building -only-testing:` one suite (4 tests) | 8 s |
| `simctl spawn … xctest <bundle>` (Xcode's agent, console only, `-XCTest` selectors only) | 2.4–3.0 s |
| Litmus-owned helper: Swift Testing ABI v0 entry point, linked to XCTest and Testing, JSON events, filters | **3.3–4.3 s** |
| The same helper loading XCTest and Testing lazily with the bundle | 8–12 s (8.7 s in `dlopen`) |

So, for a one-package pull request: **an incremental build is 15× cheaper than a cold one** (19 vs 285 s), which makes
the workspace strategy the first lever; **the launcher, not the tests, is the per-run cost** (9 s for 0.1 s of tests),
and a direct helper divides it by about 3 while keeping structured events (kill attribution, test names) and filters.
A pull-request run of the median (one changed-line mutant) would then cost one incremental schema build (about 20 s),
the inactive control and the mutant (2 × 4 s): under 30 s added to the job, against an estimated 6 minutes today (not run on the app; copy, two
cold builds, baseline, probe, control).

## Design

### 1. Scope: what a pull-request run mutates (competitors: cargo-mutants `--in-diff`, infection `--git-diff-lines`, Stryker `since`)

- `--diff <unified diff file>` or `--diff-base <ref>`: the sites whose expression overlaps a changed line on the new side.
  The family's model is kept: the CI passes the change (as it passes `--only` files to the analyzers), Litmus parses a
  unified diff it is given (no network, no shelling to git unless `--diff-base` asks), reading it bounded.
- Priority classes, in order: changed lines, then (optionally, budget permitting) the rest of the changed files.
- **Zero-mutant fast path**: plan with the diff, and when no site is selected, exit success in about a second, before any
  copy or build. 40 % of app pull requests end there.

### 2. Builds: pay for one incremental build, not two cold ones

Three workspace strategies, chosen explicitly (`--workspace`):

| Strategy | For | How | Safety |
| --- | --- | --- | --- |
| `copy` (today, default) | untrusted or local runs | fresh copy (APFS clone), fresh build directory | the source is never written |
| `persistent DIR` | nightly and weekly runs, developer machines | a stable workspace path, synchronised from the source by manifest (unchanged files keep their bytes and times, changed ones rewritten, removed ones deleted), and a build directory kept beside it: builds are incremental across runs | the source is never written; the workspace is verified against the manifest before use and rebuilt from scratch when it does not match |
| `in-place` | CI, in the job that just built and tested the change | the checkout itself and the job's DerivedData: the schema build recompiles only the mutated files' modules | requires a clean git tree; every original is journalled before it is rewritten and restored on exit, on signal, and at the start of any later run that finds a schema marker; the run ends by verifying the restored bytes against the journal |

**The inactive schema is the baseline.** A schema with no mutant active behaves as the original by construction (each
site evaluates the original when its activation is false), and the control run already checks it against the baseline.
In pull-request mode Litmus builds the schema directly and uses the inactive control as the baseline: one build instead of
two. Only if the schema does not build is the unmutated build run, to tell a broken baseline from an unviable mutant.

### 3. Tests: run what can fail, once

- Test-target selection from the manifests (done, ADR 0006) and, for Xcode, `-only-testing:<target>`: a package change
  runs the package's tests, not the app's.
- **Reach-based selection** (study 4): the nightly run records per-test reach; a pull-request run uses it, when its
  fingerprints match, to run only reaching tests, together in one process (`--filter`/`-only-testing` per test).
- **Reach-based kill check** (study 4): a kill by a test that does not reach the mutant is not the mutant's; it replaces
  the confirmation reruns when reach is known, and costs nothing.
- **Flaky probe from the nightly**: the nightly records flaky tests; a pull-request run skips the probe and leaves them out.
- **Direct test execution on the simulator** (phase 0 spike, measured above): for hostless test bundles, a small
  Litmus-owned helper, built for the simulator and linked to XCTest and Testing, `simctl spawn`ed per run: it loads the
  bundle, calls Swift Testing's ABI v0 entry point (`swt_abiv0_getEntryPoint`, the one swift-testing exposes for tools)
  with the selection as its configuration, and streams JSON event records to a file Litmus reads as it does the event
  stream today. XCTest cases in the same bundle still need `xctest -XCTest <selectors>`; bundles with a host
  application stay on `xcodebuild`. The ABI is versioned; the helper checks the version and falls back to
  `xcodebuild` on anything it does not know.

### 4. Results: reuse what cannot have changed (competitors: Stryker incremental, PIT history, mutmut, SMT cache)

A **result store** (directory, content-addressed, protobuf records with SHA-256 as the journal already writes them):

- **Mutant identity anchored to code**, not offsets: analyzerkit's `Fingerprint.anchored` inputs (path, enclosing
  declaration, whitespace-normalised text, ordinal) and the operator. Today's identity hashes byte offsets, so any edit
  above a site renames every mutant below it.
- **Reuse key**: identity, the digest of the enclosing declaration, the digests of every source file of the mutant's module
  and of the selected test targets, the toolchain, the build settings, the execution policy version. Reuse is sound when
  all match: nothing that could change the verdict changed, under the deterministic-test assumption the flaky probe
  enforces.
- A looser key (declaration and reaching tests only, Stryker-like) is offered for the nightly as `--reuse declaration`,
  never for the pull-request gate, and every reused verdict carries the run it came from.
- Changed-line mutants are new by definition; reuse serves re-pushes, the changed-file class and the nightly.
- Store hygiene: size-bounded (oldest records evicted), read-only for untrusted pull requests (forks cannot poison it),
  every record verified on read; a record that fails is ignored and noted, never trusted.

### 5. Budgets: the runner stays usable

- `--budget <seconds>` and `--max-mutants`: mutants run in priority order; when the budget runs out the run stops
  cleanly (the interruption path that exists), untested mutants are `notRun` and listed, and the gate judges only what ran.
- Workers from the suite's measured parallelism (done), `--memory-limit` (done), `--background` for shared machines (done,
  with its caveat), one simulator per worker only when measured to pay.
- **Resume**: a run that stops (budget, signal, crash) resumes from its journal: decided mutants are not rerun
  (SMT has this; Litmus has the journal already).
- **Sharding** (`--shard k/n`, `merge`) for nightly runs and very large changes, split by module so shards share no build.
- The artifact reports the run's own cost (wall, child CPU, peak memory, disk) so runner budgets can be enforced and tuned.

### 6. Gate and reports for pull requests

- `--gate new-survivors` (with the base branch's baseline, the family's `--report-new-since` model): fail on survivors on
  changed lines that the baseline does not hold, never on old debt.
- SARIF on the changed lines (Danger already turns the analyzers' SARIF into review comments), a Markdown job summary,
  and Stryker's JSON schema for dashboards (the competitor surface report).

## Safety, resilience and reliability invariants

1. Only the owned workspace is written, except in `in-place`, where every write is journalled first and verified restored.
2. A reused verdict is labelled and traceable to its run; a stale, unverifiable or mismatching record is never reused.
3. Interruption at any point leaves either the previous state or a resumable one; never a mutated source left behind
   without a record to restore it.
4. A budget stop is not a failure and not a pass: untested mutants are reported as such.
5. Every new input (diff file, cache record, nightly reach data) is bounded and validated as the journal is.

## Phases and acceptance criteria

| Phase | Content | Accepted when |
| --- | --- | --- |
| 0. Measure | package cold, incremental and test costs; the direct-execution spike; pull-request profile | done: numbers in this document |
| 1. Scope | `--diff`, zero-mutant fast path, priority classes, budgets, resume | an app pull request with no changed-line mutant costs under 5 s; budget stops leave a resumable run |
| 2. Builds | inactive schema as baseline; `persistent` and `in-place` workspaces | a one-package pull request builds once, incrementally |
| 3. Tests | `-only-testing` targets; direct simulator helper; nightly reach and flaky data reused; reach kill check | per-mutant time on a package is under 5 s |
| 4. Reuse | anchored identity, result store, sound key, `--reuse declaration` for nightly | a re-push that changes tests only reruns only affected mutants |
| 5. Gate and reports | new-survivor gate, SARIF on changed lines, Markdown, Stryker JSON, sharding | Danger shows Litmus findings on the changed lines |

Upstream candidates (family-wide, to propose as before): a unified-diff reader and changed-line scope in analyzerkit
(`ReportScope` takes files today; deadwood and arcleak could report on changed lines too), and a verified,
size-bounded content-addressed store in aemi (the journal's frames and digests generalised).
