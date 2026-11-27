# Shared-process equivalence

**Property.** For every mutant, `--shared-process on` and `auto` give the verdict `--shared-process off` gives. Sharing changes the cost of a verdict, never the verdict.

Two mechanisms share work:

- **Shared workers:** one test process runs mutant after mutant, switched through a shared memory page (Swift Testing; macOS SwiftPM bundles and simulator unit-test bundles).
- **UI sessions:** one `xcodebuild` runs many UI-test mutants as test-plan configurations.

## Assumptions

- E1. Tests are deterministic given their inputs (C1 in [cache soundness](cache-soundness.md)).
- E2. A mutant is active only while the control page names it (`SharedControlPage`), or, in a UI session, only in the app processes its own configuration launches with its activation variables.

## Shared workers

These rules are in `SharedProcessHarness` and `docs/design/shared-process.md`.

**S1. Kills.** A shared kill is accepted only when three things hold:
- the page counted hits of the active mutant;
- a test recorded an issue;
- the failing tests, rerun unmutated in the same process, pass.

Otherwise the worker is replaced and the mutant is decided in a fresh process. A failure caused by state the process carried over from an earlier mutant therefore cannot become a kill.

**S2. No shared survivor stands alone.** A shared worker reports a pass only when the judge will recheck it in a fresh process against the whole covering modules (`recheckSurvivors`, the default). With `--no-recheck-survivors`, the run is redone fresh at once. Every survivor's verdict thus comes from a fresh process, as with `off`.

**S3. Process-lifetime switches.** A switch evaluated while the bundle loads, or differently across two unmutated passes, is process-cached, such as a `static let` built from a mutated expression. Its mutant always runs in a fresh process.

**S4. Crashes and timeouts** end the worker. The judge reruns the mutant alone and fresh, as with `off`.

## UI sessions

These rules are in `UISessionHarness`.

**U1. Only first runs are shared.** Reruns, confirmations and timeout checks (`alone`) always run in their own `xcodebuild`. A failing configuration therefore becomes a kill, crash or timeout only through the same fresh rerun `off` would make.

**U2. A survivor is decided in its own app processes.** Each configuration's test launches the app with that mutant's `LITMUS_ACTIVE_ID` (E2). The pass and the activation markers it reports are that mutant's, as in a separate run.

**U3. Population check.** A configuration missing from the result bundle, or with a different test count from the others, is not used. Its mutant runs fresh.

**Shared with `off`, not removed by it.** The simulator's persistent app data (user defaults, files in the app container) outlives an app process in both modes. A test suite that depends on it breaks E1 either way.

## Evidence

- `shared-process verdicts equal isolated verdicts, mutant by mutant` and `auto stays off where processes start fast, with the isolated verdicts` (`SharedProcessTests`), on `Tests/Fixtures/SharedProcess`. The fixture includes a `static let` built from a mutated expression, a `lazy var` singleton, a mutant that corrupts a global before failing, and one that traps.
- The benchmark's TripKit, FareKit and WalletKit packages: identical verdicts with `on`, `auto` and `off` (v0.5.0 notes).
- `bench/Transit`, scheme `TransitUI`, `--operators ui`: identical verdicts for all 9 mutants with and without UI sessions (v0.9.0 notes).
- The two session-side helpers are unit-tested in `UISessionTests`: per-configuration result parsing and the multi-configuration `.xctestrun`.
