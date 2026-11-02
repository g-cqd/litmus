# ADR 0007 — Pull-request runs: fixed costs first, sound reuse, bounded impact

Status: accepted (plan; implemented by phases)
Date: 2026-11-02

## Context

Litmus should run on every pull request without straining the runner. Sixty merged reference-app pull requests
(docs/research/2026-11-02-pr-profile.md) create a median of 1 mutant on changed lines (p90 9, max 52), and 40 % create
none. Measured on ModuleParts (docs/design/0001): a cold `build-for-testing` takes 285 s, one after a one-file edit 19 s;
`test-without-building` takes 9–11 s for 0.1 s of tests; a direct helper on the simulator 3.3–4.3 s. A pull-request run
is therefore all fixed costs: copy, two cold builds, baseline, flaky probe, control. Competitors scope by diff
(cargo-mutants, infection), reuse results (Stryker, PIT, SMT) and shard (cargo-mutants, Stryker); none states when reuse
is sound.

## Decision

1. **Scope by the change.** `--diff`/`--diff-base` select the sites on changed lines, then optionally the rest of the
   changed files; with no site selected the run ends successfully before any copy or build.
2. **Build once, incrementally.** The inactive schema is the baseline (the unmutated build runs only when the schema does
   not build). Workspaces are explicit: `copy` (default, never writes the source), `persistent` (stable path, synchronised
   by manifest and verified before use, build directory kept), `in-place` (CI only, clean tree required, every original
   journalled before it is rewritten, restored on exit, on signal and at the next start, then verified).
3. **Run what can fail, cheaply.** Test targets by manifest and `-only-testing`; a Litmus-owned simulator helper over
   Swift Testing's versioned ABI entry point for hostless bundles, `xcodebuild` otherwise; per-test reach and flaky tests
   from the nightly run when their fingerprints match; a kill by a test that does not reach the mutant is rejected.
4. **Reuse only what cannot have changed.** Mutant identity anchored to code (path, declaration, normalised text, ordinal,
   operator). A result is reused only when the identity and the digests of its module's sources, the selected test
   targets, toolchain, build settings and execution policy all match; a looser declaration-level key exists for nightly
   runs only. Every reused verdict names the run it came from. The store verifies every record on read, is size-bounded
   and is read-only for untrusted pull requests.
5. **Bound the impact.** `--budget` and `--max-mutants` stop cleanly in priority order, untested mutants reported as not
   run; a stopped run resumes from its journal; the artifact reports the run's own wall time, child CPU, peak memory and
   disk; sharding by module for nightly runs.
6. **Gate on what the change created.** Survivors on changed lines that the base branch's baseline does not hold, the
   family's `--report-new-since` model; SARIF on changed lines for Danger, a Markdown summary, Stryker's JSON schema.

## Consequences

- The median pull request should cost under 30 s on top of the job that builds and tests it (estimated from phase 0;
  to be measured when phases 1–3 land); 40 % cost about a second.
- `in-place` is the only mode that writes the user's tree; its journal and restore are safety-critical and get the
  fault-injection tests the snapshot has (kill at every step, then a new run restores).
- Offset-based mutant identities end; reports from earlier runs are not comparable to later ones by id.
- The simulator helper depends on Swift Testing's ABI v0; a version it does not know means `xcodebuild`, not a guess.
- Two upstream candidates: changed-line scope from a unified diff in analyzerkit (every analyzer can use it) and a
  verified, size-bounded content-addressed store in aemi.
