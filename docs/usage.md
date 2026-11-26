# Usage and configuration

Run `litmus --help` or `litmus <command> --help` for the full option reference.

## Commands

- `plan`: inspect eligible mutation sites without executing the project.
- `check`: inspect package paths, discoverable test configuration, or an existing `.xctestrun` without building.
- `run`: build instrumented batches, execute tests, and write run artifacts.
- `analyze`: validate recorded evidence against the source and render findings.
- `census`: count syntax locations for candidate mutation operators without building or testing. Candidate counts do not imply that those operators are supported by `run`.
- `merge`: combine compatible shards.
- `restore`: restore original files after an interrupted in-place run.

## Mutation scope

Litmus mutates with operators in three tiers; each tier includes the ones before it. See [operators](operators.md) for what each does, what it never touches, and how often it detects a missing test.

| Tier | Operators |
| --- | --- |
| `stable` (default) | `negate-condition`, `swap-ternary`, `replace-logical` |
| `standard` | adds `replace-relational`, `flip-boolean`, `replace-arithmetic`, `replace-range`, `remove-negation`, `replace-nil-coalescing` |
| `experimental` | adds `remove-call` |

Extended operators (`remove-view-element`, `replace-stdlib-semantic`, `remove-normalization`, `replace-optional-chain`, `return-boundary`, `return-constant`, `empty-body`, `empty-closure-body`, `remove-switch-case`) are explicit opt-in via `--operators`.

`--operator-tier TIER` picks a tier; `--operators ID,ID` names exactly which operators run (the two are alternatives); both work on `plan` and `run`. `litmus census` lists the candidates and which operator implements each. Litmus excludes tests, previews, generated code, debug-only regions, macro and attribute arguments, enum case declarations, and files it identifies as outside compiled targets. The plan records exclusions; inspect it when project classification is ambiguous.

Use `--only-path GLOB`, `--exclude-path GLOB`, `--arid-call NAME`, and `--exclude-declaration PATTERN` to control scope. A unified diff can be supplied with `--diff FILE`, or computed with `--diff-base REV`. `--diff-scope lines` is the default; `files` includes all sites in affected files.

## Configuration

A `.litmus.json` file can set shared analyzer configuration and Litmus-specific scope keys, for example:

```json
{
  "exclude": ["**/Generated/**"],
  "include": ["Sources/Core/**"],
  "aridCalls": ["Analytics.track", "Telemetry"],
  "excludeDeclarations": ["*ForTesting", "*ForPreview"]
}
```

A `litmus` section in `.swift-analyzers.json` is also supported. Use `--config FILE` to select an explicit file.

Suppress an intentional mutation with a source directive:

```swift
// @lm:accept:next swap-ternary -- Both branches are intentionally equivalent.
let value = condition ? first : second
```

Suppressed sites remain visible in the plan; an unknown operator name in a directive emits a warning note in the plan and suppresses nothing.

## Score gates

`--minimum-score PERCENT` fails a `run` or `analyze` whose mutation score is lower. `--maximum-score-drop POINTS --baseline-run RUN` fails when the score fell by more than that from an earlier run (`.json` or `.pb`). A drop is judged only between runs that measured the same thing: whole-subject runs of the same operators over the same files, with no change scope, shard, or budget stop; otherwise the gate says why it cannot compare and fails. A run with an unresolved mutant has no score and fails. These gates are independent of `--strict` and `--gate new-survivors`.

## Execution controls

`--jobs`, `--batch-size`, `--suite-width`, `--timeout`, and `--timeout-factor` control concurrency, batching, and deadlines. `--memory-limit` bounds monitored process memory. `--baseline-repetitions` controls flaky-test probing. `--kill-confirmation targeted|full|none` controls verification of detected mutations.

`--progress` (the default when standard error is a terminal; `--no-progress` turns it off) prints one line per decided mutant. When `--resume` or a nightly run recorded how long each mutant took, the slowest start first. `--test-target NAME` (repeatable) runs only those test targets for every mutant, with the baseline still running them all.

`--background` lowers build and first-pass priority. It can substantially increase wall time and may trigger a project's own compiler timing limits. `--xcodebuild-argument ARG` passes an additional argument to Xcode; repeat it for each argument and value.

## Reports

`analyze --format` supports `xcode`, `json`, `sarif`, `markdown`, and `stryker`. `run --report` renders a report directly after execution. `--only` and `--only-from` filter reported findings rather than execution scope.

Run artifacts contain input identities, execution policy, test counts, mutation results, and resource costs. Analysis revalidates input content. Changed inputs produce degraded evidence instead of a passing historical report.

| Exit status | Meaning |
| --- | --- |
| `0` | Successful command; inspect budget and completion fields for bounded runs. |
| `1` | Findings under the selected gate. |
| `64` | Invalid usage. |
| `70` | Incomplete, stale, or unresolved evidence. |
| `74` | Output error. |
| `78` | Configuration error. |

`--strict` fails on survivors and uncovered mutations. `--gate new-survivors` compares survivors with `--baseline`. Budget-limited runs may exit successfully while listing untested mutations; CI should check completion when exhaustive results are required.

## Packages inside a repository

When a package depends on sibling directories, make the containing repository the snapshot root and select the package separately:

```sh
litmus run /path/to/repository --package-path Modules/Library \
  --scheme Library --destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' \
  --trust-project --output /tmp/litmus-library
```

Litmus copies the root, executes builds and tests from the package directory, and mutates only that package. Paths in evidence remain relative to the root. `plan --package-path` supports the same discovery scope. Sibling packages are retained as build inputs, not mutation targets. `--only-path` filters still apply within the selected package. `--package-path` must name a package inside the root and cannot be combined with `--project`.

`--test-plan NAME` explicitly selects a plan referenced by the scheme. Litmus does not silently replace test plans or add targets: doing so could change which tests the project intends to run. `-only-testing` can filter existing test targets but cannot repair an empty test configuration.

A package whose manifest has `.package(path:)` dependencies outside the root is refused before any copy, with the command to run from their common parent.

## Check configuration without building

```sh
litmus check /path/to/repository --package-path Modules/Library \
  --scheme Library --destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>'
litmus check --xctestrun /path/to/Library.xctestrun
```

`check` validates package paths and discoverable shared schemes/test plans without executing project code. It catches empty test actions, missing plans, and unresolved target container paths. Automatically generated or ambiguous schemes still require Xcode to resolve them. After building, Litmus validates the actual `.xctestrun` before starting tests; an empty artifact reports its scheme, test plan, and corrective guidance. A successful static check is not proof that Xcode will discover or execute tests.

The output directory must be new and outside the source root. Existing directories are never silently deleted or overwritten. Use a new `--output` and optionally `--resume OLD_RUN` to reuse compatible verdicts.
