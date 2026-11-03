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

Host Swift package test bundles can run directly after building. Hostless iOS Simulator bundles can use Litmus's simulator helper, which supports Swift Testing and XCTest. App-hosted bundles use Xcode's test execution. `--no-simulator-helper` forces the Xcode path.

Per-target selection limits execution to test modules that can reach a file. `--no-test-target-selection` disables that optimization. `--per-test-reach` records reach at individual test granularity, requiring additional test runs.

## Evidence and limitations

- Mutant identifiers are anchored to declarations and normalized source rather than line offsets. This improves stability across unrelated edits; it does not establish semantic equivalence.
- Only the supported mutation operators contribute to the score. Uncovered behavior and equivalent mutations still require human interpretation.
- Input hashes validate recorded content, not all external state. Network responses, environment changes, tool behavior, and nondeterministic tests can affect results.
- Conditional compilation, generated sources, macros, and unusual project layouts may limit classification. Review exclusions in the plan.
- Runtime instrumentation can affect compilation or behavior. Inactive controls and isolated rebuilds detect some, not all, such effects.
- Workspaces protect against accidental source changes, not malicious project code. See [Security](../SECURITY.md).
