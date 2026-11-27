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
- `accept` / `unaccept`: record or remove a reviewed equivalent mutant in `.litmus-accepted.json`.
- `agent-guide`: print, or install with `--install`, the workflow a coding agent follows to close mutation gaps.
- `clean`: delete orphaned pool simulators, and with `--run DIR` a finished run's workspace and build products.

## Mutation scope

Litmus mutates with operators in three tiers; each tier includes the ones before it. See [operators](operators.md) for what each does, what it never touches, and how often it detects a missing test.

| Tier | Operators |
| --- | --- |
| `stable` (default) | `negate-condition`, `swap-ternary`, `replace-logical` |
| `standard` | adds `replace-relational`, `flip-boolean`, `replace-arithmetic`, `replace-range`, `remove-negation`, `replace-nil-coalescing` |
| `experimental` | adds `remove-call` |

Extended operators (`remove-view-element`, `replace-stdlib-semantic`, `remove-normalization`, `replace-optional-chain`, `return-boundary`, `return-constant`, `empty-body`, `empty-closure-body`, `remove-switch-case`, `nullify-optional-binding`, `negate-is-empty`, `skip-loop`, `swap-break-continue`, `replace-bitwise`, `remove-unary-minus`, `replace-collection-transform`, `swap-first-last`) are opt-in via `--operators` (`--operators all` enables every non-fault logic operator). `--fault-operators` (or `--operators fault`) adds the four fault-injection operators (`remove-defer`, `remove-cleanup-call`, `weaken-capture`, `swap-async-order`). `--ui-operators` (or `--operators ui`) adds the SwiftUI UI-domain operators (`remove-view-element`, `negate-disabled`, `remove-presentation`, `remove-view-action`, `neutralize-view-modifier`); `remove-accessibility-metadata` is opt-in by name; under `xcodebuild`, UI test bundles automatically propagate Litmus's environment to `XCUIApplication` via `UITargetAppEnvironmentVariables`. Type-directed operators auto-discover `.build` / `DerivedData` index stores or accept `--index-store-path PATH`.

`--operator-tier TIER` picks a tier; `--operators ID,ID` names exactly which operators run (the two are alternatives); both work on `plan` and `run`. `litmus census` lists the candidates and which operator implements each. Litmus excludes tests, previews, generated code, debug-only regions, macro and attribute arguments, enum case declarations, and files it identifies as outside compiled targets. The plan records exclusions; inspect it when project classification is ambiguous.

Use `--only-path GLOB`, `--exclude-path GLOB`, `--arid-call NAME`, and `--exclude-declaration PATTERN` to control scope. A unified diff can be supplied with `--diff FILE`, or computed with `--diff-base REV`. `--diff-scope lines` is the default; `files` includes all sites in affected files.

A diff that changes only tests plans no mutant unless `--include-test-changes` is given. With it, each changed test file brings in the production code it can affect: with `--reach-from NIGHTLY` (a run with per-test reach), when every changed line lies inside a Swift Testing test that run knew, only the mutants those tests reached; otherwise, and for deleted test files, every site of the production files the file's test targets cover. The plan's scope records what came in. With `--gate new-survivors` and the base branch's baseline, a mutant a weakened test no longer kills fails the gate.

`run --only-id SELECTOR` (repeatable) runs only the selected mutants: a 16-digit id, an unambiguous id prefix of at least 8 digits, or `path:line[:operator]` (the path matches whole trailing components). Only their files are rewritten, and they are always executed: an earlier verdict from `--resume` or the result store is not reused, since the tests may have changed. With a persistent workspace (`--workspace persistent:DIR`) this re-verifies one mutant after a test edit with an incremental build.

## Configuration

A `.litmus.json` file can set shared analyzer configuration and Litmus-specific scope keys, for example:

```json
{
  "exclude": ["**/Generated/**"],
  "include": ["Sources/Core/**"],
  "aridCalls": ["Analytics.track", "Telemetry"],
  "excludeDeclarations": ["*ForTesting", "*ForPreview"],
  "acceptedFile": ".litmus-accepted.json"
}
```

A `litmus` section in `.swift-analyzers.json` is also supported. Use `--config FILE` to select an explicit file.

Suppress an intentional mutation with a source directive:

```swift
// @lm:accept:next swap-ternary -- Both branches are intentionally equivalent.
let value = condition ? first : second
```

Suppressed sites remain visible in the plan; an unknown operator name in a directive emits a warning note in the plan and suppresses nothing.

To accept an equivalent mutant without a comment in production code, record it with its proof:

```sh
litmus accept <id> --from RUN_DIR --reason "a == b gives a - b == 0, the else value, so > and >= agree"
```

The entry goes to `.litmus-accepted.json` (or `acceptedFile`, or `--accepted-file`) with the mutant's path, declaration, operator, original and replacement. The reason needs at least 10 non-space characters, and a mutant the run detected is refused without `--force`. Planning suppresses accepted mutants like a directive; an entry follows its mutant across edits elsewhere (by id, then by its anchor). An entry of a planned file that matches no mutant is reported as `stale-missing`. `run --verify-accepted` runs accepted mutants anyway and reports those a test now detects as `stale-killed`. `litmus unaccept <id>` removes an entry.

## Score gates

`--minimum-score PERCENT` fails a `run` or `analyze` whose mutation score is lower. `--maximum-score-drop POINTS --baseline-run RUN` fails when the score fell by more than that from an earlier run (`.json`, `.pb`, or its run directory). A drop is judged only between runs that measured the same thing: whole-subject runs of the same operators over the same files, with no change scope, shard, or budget stop; otherwise the gate says why it cannot compare and fails. A run with an unresolved mutant has no score and fails. These gates are independent of `--strict` and `--gate new-survivors`.

## Execution controls

`--jobs`, `--batch-size`, `--suite-width`, `--timeout`, and `--timeout-factor` control concurrency, batching, and deadlines. `--memory-limit` bounds monitored process memory. `--baseline-repetitions` controls flaky-test probing. `--kill-confirmation targeted|full|none` controls verification of detected mutations.

`--shared-process auto|on|off` (default `auto`): with `on`, a mutant's narrowed Swift Testing run goes to a helper process that keeps the test bundle loaded, and the mutant is switched on through a shared memory page. Only kills are decided there, and only when the mutant was hit and its tests pass again unmutated in the same process. Survivors, crashes, timeouts and anything in doubt are decided in a fresh process. `auto` turns it on per batch only when it pays: at least 8 covered mutants, a process start of at least 0.25 s, and more start time saved than the workers cost. macOS SwiftPM bundles start in about 0.1 s, so `auto` leaves them in fresh processes, and a note says why. It applies to macOS SwiftPM test bundles and to iOS Simulator unit test bundles run through Litmus's helper.

`--per-test-reach` is on by default (`--no-per-test-reach` turns it off): the serial control run records which Swift Testing tests reach each mutant, each mutant then runs only those tests, and a narrowed survivor is rechecked against every covering test module, so an XCTest-only kill is never lost.

`--progress` (the default when standard error is a terminal; `--no-progress` turns it off) prints one line per decided mutant. When `--resume` or a nightly run recorded how long each mutant took, the slowest start first. `--test-target NAME` (repeatable) runs only those test targets for every mutant, with the baseline still running them all.

`--background` lowers build and first-pass priority. It can substantially increase wall time and may trigger a project's own compiler timing limits. `--xcodebuild-argument ARG` passes an additional argument to Xcode; repeat it for each argument and value.

## Reports

`analyze --format` supports `xcode`, `json`, `sarif`, `markdown`, `stryker`, and `agent`. `agent` is one JSON document for a coding agent: a summary (scores, verdict counts, stale acceptances) and every survivor (`reached_not_detected`) and uncovered mutant (`not_reached`) with its code, a numbered context excerpt, the tests that reached it, the test targets covering its file, and a `litmus run --only-id` command that re-verifies it; `--domain logic|ui|all` filters them. `litmus agent-guide --install [--target agents|claude|agents-md]` writes the matching workflow to `.agents/skills/litmus/SKILL.md`, `.claude/skills/litmus/SKILL.md`, or a marked section of `AGENTS.md`. `run --report` renders a report directly after execution. `--only` and `--only-from` filter reported findings rather than execution scope.

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

`--test-plan NAME` explicitly selects a plan referenced by the scheme. Litmus does not silently replace test plans or add targets: doing so could change which tests the project intends to run. To test every unit-test target instead, pass `--all-test-targets` (with `--project`, instead of `--scheme`): Litmus writes a `__LitmusAllUnitTests` scheme into its own workspace copy (never the subject's tree; refused in place) with every unit-test target of the project, or of every project the workspace lists in its `contents.xcworkspacedata` (projects beside it that it does not list are left out, and so are listed projects outside the copied root, with a note), and `--include-ui-tests` adds UI-test targets.

`--skip-failing-targets` (implied by `--all-test-targets`) excludes a test target that fails unmutated instead of stopping the run: the baseline is rerun without it, it is skipped in every later run, and the mutants only it covers are reported as not run, outside the score, with a note naming the target. Under `xcodebuild` the target is the one the result bundle's first failure names. When Litmus's simulator helper fails the baseline, the run falls back to `xcodebuild`, which decides which targets truly fail; the helper is then retried without them and used again if it passes, so a target that fails only under the helper never gets excluded. `-only-testing` can filter existing test targets but cannot repair an empty test configuration.

A package whose manifest has `.package(path:)` dependencies outside the root is refused before any copy, with the command to run from their common parent.

## Check configuration without building

```sh
litmus check /path/to/repository --package-path Modules/Library \
  --scheme Library --destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>'
litmus check --xctestrun /path/to/Library.xctestrun
```

`check` validates package paths and discoverable shared schemes/test plans without executing project code. It catches empty test actions, missing plans, and unresolved target container paths. Automatically generated or ambiguous schemes still require Xcode to resolve them. After building, Litmus validates the actual `.xctestrun` before starting tests; an empty artifact reports its scheme, test plan, and corrective guidance. A successful static check is not proof that Xcode will discover or execute tests.

The output directory must be new and outside the source root. Existing directories are never silently deleted or overwritten. Use a new `--output` and optionally `--resume OLD_RUN` to reuse compatible verdicts.
