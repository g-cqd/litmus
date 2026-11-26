# Execution model and limitations

## Build and test flow

1. Establish the workspace and input snapshot.
2. Identify eligible mutation sites and group non-nested sites into batches.
3. Rewrite each batch into a schema with individually activated mutations.
4. Build the schema. Isolate build failures by diagnostics and subdivision; a mutation that fails alone on its own lines is unviable.
5. Run the inactive schema to establish passing controls and reach evidence. `--unmutated-baseline` requests an additional original-source baseline.
6. Run reached mutations in separate test processes. Confirm failures according to the selected kill-confirmation policy.
7. Journal verdicts and write the completed or incomplete run artifact.

An activation marker establishes whether execution reached the mutation. A failure without activation is not sufficient for a kill. Crashes and timeouts are rerun independently. Flaky-test probing and targeted confirmation reduce false detections but cannot eliminate nondeterminism.

## Test execution

Host Swift package test bundles can run directly after building. Both hostless and app-hosted iOS Simulator unit test bundles can use Litmus's simulator helper (cached per toolchain under `~/Library/Caches/litmus/simulator-helper`), which invokes `simctl spawn` directly across concurrent workers and supports Swift Testing and XCTest. If an app-hosted bundle cannot load directly or its baseline needs a launched `UIApplication`, Litmus falls back to `xcodebuild` automatically. UI test bundles always use `xcodebuild`. `--no-simulator-helper` forces the Xcode path, and so does an `--xcodebuild-argument` that selects tests (`-only-testing`, `-skip-testing`, test configurations), which the helper cannot honour; the run's notes say so.

The helper runs Swift Testing first, then every XCTest case on the process's main thread, so `@MainActor` and `async` XCTest cases work. A run that exceeds its deadline reports where it stopped: the XCTest case that never finished, or that every test had finished but the process did not exit.

An Xcode destination written as `name=iPhone 16,OS=18.2` (or `OS=latest`, the default) is resolved through `simctl` to one simulator's identifier before the run; the run's notes record it, and the simulator helper is then usable. A name that matches several simulators on one runtime, or none, is refused.

`--simulators N` (1...16) runs an Xcode simulator run on N simulators at once. Litmus clones the destination when it is shut down, or makes new devices of its type when it is booted; boots them while the first schema builds; gives each test run its own simulator and DerivedData (the build products are shared: no schema builds while tests run); restarts one after a crash or timeout; and deletes them at the end. The devices are recorded under `~/Library/Application Support/litmus/simulator-pools` with a lock their run holds, so the next run deletes the devices of a run that was killed. Only devices named in that record are ever deleted; the destination's own simulator is never shut down or erased.

For Xcode runs, Litmus stops a mutant's tests at the first failure shown by Xcode's result stream, removes each result bundle after reading its summary (`--keep-result-bundles` keeps them), passes `-collect-test-diagnostics never` and `-enableCodeCoverage NO` (unless overridden), pre-boots a shut-down destination simulator while the first schema builds, and pins `ARCHS` and `ONLY_ACTIVE_ARCH` for simulator builds unless the project's own arguments set them. On a macOS destination this took a small fixture from 90 s and 1.2 GiB to 24 s and 69 MiB with the same verdicts.

A failing inactive control is retried once; if it fails again its batch is split by halves, within a budget, until the mutant that breaks it is alone and only that one is an infrastructure error. The notes say which batches were split.

Per-target selection limits execution to test modules that can reach a file. `--no-test-target-selection` disables that optimization. Per-test reach (on by default; `--no-per-test-reach`) records which Swift Testing tests reach each mutant during the serial control run, through one event stream shared with the schema's reach records, at no extra run; a bundle without Swift Testing tests runs whole. Closure reuse keys leave out the test files of targets that do not cover a mutant's file when test-target selection is on, so editing one module's tests keeps another module's verdicts.

Schemas and test processes name their variables with a run token (`LITMUS_ACTIVE_ID_<8 hex>`, derived from the subject root), so a subject whose tests start another Litmus run, Litmus on itself included, never hands the outer selection to the inner run.

`litmus clean` deletes the simulators of pools whose run is gone and any device named like a pool's that no live pool owns; `--run DIR` removes a finished run's workspace copy, build products and worker directories and keeps its evidence; `--dry-run` only reports. A `--destination` naming no available simulator fails before the workspace is copied, with the available simulators listed.

## Evidence and limitations

- Mutant identifiers are anchored to declarations and normalized source rather than line offsets. This improves stability across unrelated edits; it does not establish semantic equivalence.
- Only the operators of the selected tier contribute to the score; a score is comparable only with one of the same operators.
- Only the supported mutation operators contribute to the score. Uncovered behavior and equivalent mutations still require human interpretation.
- Input hashes validate recorded content, not all external state. Network responses, environment changes, tool behavior, and nondeterministic tests can affect results.
- Conditional compilation, generated sources, macros, and unusual project layouts may limit classification. Review exclusions in the plan.
- Runtime instrumentation can affect compilation or behavior. Inactive controls and isolated rebuilds detect some, not all, such effects.
- Workspaces protect against accidental source changes, not malicious project code. See [Security](../SECURITY.md).
