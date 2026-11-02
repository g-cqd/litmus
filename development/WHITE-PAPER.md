# Litmus — White paper

Status: initial implementation and assurance programme, **not certified or production-qualified**.
Host: Swift 6.4, macOS 15+. Subjects: host-compatible Swift packages and Xcode-driven iOS projects/packages.

## 1. Purpose and priorities

Litmus measures whether tests distinguish the original program from deliberate, local faults.
It does not prove functional correctness, absence of vulnerabilities, safety, or test completeness.
The governing priorities are reliability, resilience and performance, in that order when they conflict.
“Military/high criticality” is an assurance objective, not a label that implementation can award itself.
No DO-178C, DO-330, IEC 61508, Common Criteria or military qualification is claimed.
Qualification would require an applicable standard, independent review and validation, a controlled toolchain,
traceability, operational requirements and an assessed tool-qualification strategy beyond this repository.

## 2. Evidence before assertion

Each capability is either implemented, tested, measured, proposed or blocked. These are different states.
Synthetic fixtures establish a mechanism; real corpora establish applicability and performance.
The diary records observations and failures; ADRs record decisions; this paper records principles.
A missing simulator run is an assurance gap, never an implied pass.

## 3. Safety and reliability invariants

- **R-01 Source preservation.** Litmus never edits a subject's original source. Builds run on an owned independent copy.
- **R-02 Honest verdicts.** Exit status alone cannot kill a mutant. Structured evidence must contain executed tests.
- **R-03 Baseline validity.** The original and every inactive schema must pass before active results are interpreted.
- **R-04 Failure confirmation.** A kill needs two active failures separated by a passing inactive control.
- **R-05 Explicit uncertainty.** Timeout, unsupported schema, missing evidence, cancellation and infrastructure error
  remain unresolved; they cannot inflate a score or yield a successful execution gate.
- **R-06 Exact reconciliation.** Each planned mutant has one outcome; IDs, source ranges and source hashes are checked.
- **R-07 Bounded consumption.** Source, artifact, XML depth, filesystem inventory, concurrency, process output and
  deadlines have explicit bounds. Exceeding one is a visible error, not an empty success.
- **R-08 Artifact provenance.** Results identify the input snapshot (including tests/resources/settings), driver,
  toolchain, policy, time and tool version. Reporting checks current input correspondence.
- **R-09 Safe process boundary.** No shell interpretation. Absolute executable paths, scrubbed environment,
  process-group teardown and explicit execution permission.
- **R-10 Determinism.** Stable discovery order, deterministic batching and canonical artifact encoding.
- **R-11 No unjustified selection.** Missing name/index references are not absence of coverage. Run the full suite
  until runtime attribution and conservative fallbacks are independently established.
- **R-12 No false equivalence.** Static analyzer warnings and clone similarity do not remove mutation sites from a score.

## 4. Fault and threat model

Within scope: corrupt/truncated artifacts, malformed sources, stale results, bad ranges, duplicate IDs, links,
partial filesystem reads, invalid builds, flaky tests, process failure, timeouts and interrupted execution.
Build scripts and package manifests execute arbitrary code. The copied tree is **not** a security sandbox.
A trusted project can itself write outside its directory; an adversarial local actor may race filesystem operations.
An untrusted PR must run under a restricted disposable OS account/VM with no credentials or access to sensitive files.
SHA-256 detects accidental change; neither JSON nor protobuf artifacts are signatures or authenticity proofs.
Simulator services can outlive a killed xcodebuild process; no claim of global simulator cleanup is made.

## 5. Architecture

`LitmusCore` owns plans, syntax mutations, schema construction, snapshots, drivers, evidence and reports.
`litmus` owns CLI parsing, exit status and explicit permission to execute project code.

The pipeline is discovery → plan → independent snapshot → original build/test → conflict-free schema batches →
inactive schema test → one active mutant per fresh test process → confirmation/control → checkpointed artifact → report.
The run plans the copied bytes so its source offsets refer to what is actually built.

The first tier negates Boolean expression conditions, negates ternary conditions and replaces logical operators.
Bindings, availability clauses and preprocessor conditions are never wrapped as runtime Bool expressions.
Syntax is not type resolution: custom operators, builders, ownership and effect rules remain compiler-validation gates.
Non-overlapping batches prevent nested-expression duplication from growing exponentially.
A file-private immutable startup selector avoids changing an active mutant during evaluation.
No persistent test workers or simultaneous mutants are part of the initial design.

## 6. Reuse without dependency inflation

- analyzerkit: discovery/canonical paths/bounded reads, project classification, regions, suppression,
  process supervision, diagnostic/report/schema/SARIF contracts.
- aemi: bounded structured parallelism and fast deterministic diagnostic identities.
- AemiJSON: bounded typed configuration, plans and reports, deterministic canonical model encoding.
- AemiProtobufCore: versioned, integrity-checked binary artifact envelope without macro/reflection overhead.
- arcleak: ownership discipline and explicit-oracle philosophy; future ownership mutation operators need leak oracles.
- deadwood: reachability as advisory prioritization, not a license to prune test obligations.
- dolly: group clone survivors for presentation, never share verdicts between sites.
- fcheck: path witnesses and explicit obligations; future cleanup/durability fault operators.
- modeler: interleaving/state preconditions for future concurrency operators, not proof of a kill.
- swift-search: future navigation and selection hints, not a complete test-reachability graph.

Tool-specific execution mechanisms remain in Litmus until there is a proven second consumer.
No other analyzer is run on every mutant and no model/embedding dependency enters the mutation engine.

## 7. Performance policy

Correctness checks are not disabled for speed. Measure separate discovery, snapshot, compile, install/launch,
test, evidence parsing and artifact costs. Report worker time separately from CPU time and wall time.
Initial optimizations are bounded parallel discovery, schema batching and build-for-testing reuse inside a run.
Execution is serial initially: simulator concurrency must be measured under resource and reliability budgets first.
Verdict caches require all dependency/test/build/toolchain/environment inputs, not just an unchanged source file.
No cached verdict reuse or per-test runtime mapping is claimed in this implementation.
The benchmark must report sample size, machine, toolchain, corpus, cold/warm state, median and dispersion.
A performance target without a measurement is a goal, not a result.

## 8. Operational contract

`plan` does not execute project code. `run --trust-project` does; it refuses an existing/inside-source run directory.
Host packages use SwiftPM. iOS packages use Xcode with a scheme and destination; a host build is not an iOS test.
`analyze --results` reads historical execution evidence, verifies source correspondence and reports incompleteness.
No result file, stale input or partial run may become a clean green release report.
JSON stdout is separate from human stderr. Artifacts use atomic replacement, not partial in-place writes.
A survivor is actionable test debt; infrastructure failure is an execution problem, not test debt.
Whole-program execution scope and report scope remain separate.

## 9. Assurance gates

1. Confirm red-first core contracts; preserve their failing observations.
2. Verify syntax/ranges/batching, malformed input and resource bounds.
3. Verify isolation, baseline refusal, result reconciliation and failure confirmation through seams.
4. Run a real host package with deliberately strong and weak tests; check killed and surviving mutants.
5. Validate Xcode plist handling and a real iOS simulator fixture on a healthy runner.
6. Validate the reference app's scripts/plugins and SwiftUI compile costs before weekly rollout.
7. Independent review, fault injection, fuzzing, reproducible releases and standard-specific qualification assessment
   precede any high-criticality deployment claim.

## 10. Known limitations and ownership

The applicable standards, certification goals, release authority and acceptable weekly runtime remain user decisions.
Operational task state is in the provided tasks tool; user ideas are in the ideas tool, not silently treated as work.
`development/roadmap` provides stable deliverables/evidence gates, not a second mutable task database.
The evidence/verification document is the authoritative list of what was actually exercised in this checkout.
