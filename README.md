# Litmus

Evidence-led Swift mutation testing, inspired by `arcleak`, `deadwood`, `dolly`, `fcheck`, `modeler` and `analyzerkit`.
Built on **analyzerkit, aemi, AemiJSON and AemiProtobuf**.

**Status: initial implementation, not production-qualified, safety-certified or military-qualified.**
High performance, resilience and reliability are design requirements; qualification claims need independent evidence.
The CLI runs on **macOS 15+ with Swift 6.4**. A subject keeps its own deployment settings.

## Build and test

```sh
swift build --build-tests -j 4
swift test --skip-build
./scripts/smoke.sh       # real host-package mutation run; builds/runs a small fixture
```

## Host-compatible Swift package

```sh
.build/debug/litmus plan /path/to/package --output /tmp/plan.json
.build/debug/litmus run /path/to/package --trust-project --output /tmp/litmus-run-001
.build/debug/litmus analyze /path/to/package --results /tmp/litmus-run-001/run.pb --format json --strict
```

The run directory must not exist and must be outside the source tree. It stores the copied workspace, build products,
original/inactive controls, test evidence, bounded process logs and checkpointed `run.json`. A completed run also writes
`run.pb`. The workspace is removed after completion unless `--keep-workspace`; failed runs retain it for diagnosis.
Only the copy is rewritten. Litmus never edits the subject checkout. This is **not an OS sandbox**: manifests, plugins,
scripts and tests execute arbitrary code. Use disposable restricted runners for untrusted PRs; do not expose secrets.

## Xcode project or workspace

```sh
.build/debug/litmus run /path/to/repository \
  --project 'App.xcodeproj' --scheme 'AppTests' \
  --destination 'platform=iOS Simulator,id=YOUR-EXISTING-SIMULATOR-UDID' \
  --trust-project --output /tmp/litmus-ios-001
```

`--project` also accepts a relative `.xcworkspace`. The root must contain all local dependencies.
Litmus does not create, reset or shut down simulators. The explicit destination must be usable before running.
Builds use `xcodebuild build-for-testing`, then `.xctestrun`-based `test-without-building`.
**Actual iOS simulator execution remains an operational validation gate; see [verification](docs/verification.md).**

## iOS Swift package

An iOS-only package must not be tested with host `swift test` and called “iOS tested”. Use its Xcode package scheme:

```sh
.build/debug/litmus run /path/to/ios-package --scheme PackageScheme \
  --destination 'platform=iOS Simulator,id=YOUR-EXISTING-SIMULATOR-UDID' \
  --trust-project --output /tmp/litmus-package-ios-001
```

Omit `--project`: Xcode opens the package in the copied working directory. Supply both scheme and destination.

## Mutation and verdict policy

Initial operators: `negate-condition`, `swap-ternary`, `replace-logical`. Conditions are expression elements, not `if let`
bindings or availability syntax. Test/generated/script/mock/preview/debug-only regions are excluded by fixed policy.
Compiler conditions are not guessed from the host; the actual subject build validates each schema. Inactive clauses
may still be in the plan: a survivor is not a claim of coverage, and no no-coverage category is inferred statically.

Each conflict-free batch guards expression replacements with an immutable startup selector. Overlapping sites are in
different batches. Each batch has its own inactive passing control. Each active mutant runs the full selected suite in a
fresh test process. A failure is confirmed by another inactive control followed by another active run. Test counts must
correspond to the baseline. Structured xUnit/xcresult evidence is required; build exit code alone cannot kill a mutant.

`killed`, `survived`, `timeout`, `invalid`, `infrastructureError`, `notRun` are distinct. A failed schema build is unresolved
infrastructure evidence, not an inferred kill or silent exclusion. There is no misleading combined score with unknown outcomes.
The first version does not have per-test coverage mapping, persistent workers, multi-mutant execution, equivalence pruning,
verdict-cache reuse, simulator pooling, sharding or auto-generated app CI integration.

## Reports and exit status

`analyze --results` reports **historical** execution evidence; it does not rerun tests. It validates the artifact and all
current copied input bytes (including tests, resources, settings and new files). Matching source is not a new execution,
proof of artifact authenticity or proof of an unchanged external environment. Execution date/toolchain stay in the artifact.

- `--format xcode|json|sarif`: family diagnostics, JSON envelope v1, SARIF 2.1.0.
- `--relative-to ROOT`: relative paths; in this version it must be the subject root.
- `--only FILE` / `--only-from FILE`: scope findings, never narrow execution. Incomplete execution still fails.
- `--strict`: survivors (warning-severity findings) fail the gate.
- `0`: complete execution / reporting gate passed. `run` preserves survivors for a separate reporting policy.
- `1`: report findings fail the gate. `64`: usage. `70`: incomplete/stale/unresolved execution or rejected evidence.
  `74`: requested output failed. `78`: invalid configuration.

Stdout carries one machine-readable object; stderr carries diagnostics. No missing result is treated as a clean report.
`--help` is the authoritative implemented surface; full analyzer-family flag parity is future integration work.

## Configuration and suppression

`.litmus.json` accepts `{ "exclude": ["**/Generated/**"] }`. `--config` names a file explicitly; repeat `--exclude-path`
to add globs/substrings. analyzerkit also reads existing shared top-level exclusions. Its pinned closed tool registry does
not yet accept a `litmus` section in `.swift-analyzers.json`. Unsupported region/define/platform overrides are rejected
rather than pretending to reproduce build settings. Baseline-writing/reading CLI flags are not yet implemented.

```swift
// @lm:accept:next swap-ternary -- deliberately equivalent domain cases
let label = flag ? "same" : "same"
```

The family directive grammar also supports `accept`, `accept:this`, `disable`, `enable` and the `litmus:` namespace.
Suppression leaves sites in `plan.suppressed`, not silently erased evidence. Exclusion and suppression are policy, not proof
that a mutant is equivalent. The report's `suppressed` list is reserved for diagnostic baselines; see the plan for source directives.

## Engineering record

- [White paper](development/WHITE-PAPER.md): purpose, reliability requirements, threat model and architecture.
- [ADRs](development/adr): assurance, dependencies, source isolation/execution and bounded schemas.
- [Diary](development/diary): observations, failures and verification history.
- [Assurance/verification](docs/verification.md): requirements, tests and remaining gaps.
- [Investigation](docs/investigation.md): evidence and corrections to the preliminary report.

The package name is provisional; no remote availability or publication claim is made.

### SwiftPM result transport

The SwiftPM driver uses `--parallel --num-workers 1` to obtain structured XCTest XML, and consumes Swift Testing's separate
`NAME-swift-testing.xml` file as well. A fresh full-suite invocation can therefore spawn multiple XCTest child processes.
That overhead is an explicit performance limitation of this initial host-package driver, not a claim of one test-host launch.
