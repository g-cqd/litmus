# Litmus

Mutation testing for Swift packages and Xcode projects.

Litmus introduces small changes to production code and runs your tests against them. A change that survives identifies behavior your tests may not check. Litmus batches mutations into instrumented builds, records which code the tests reach, and preserves the evidence behind each verdict.

## Requirements

- macOS 15 or later
- Swift 6.4 or later
- Xcode and an available simulator for iOS tests

The project under test retains its own build settings. Running a project executes its manifests, plugins, scripts, and tests; only run code you trust, or use an isolated runner. See [Security](SECURITY.md).

## Build

```sh
swift build -c release
swift run litmus --help
```

Release archives are available from [GitHub Releases](https://github.com/g-cqd/litmus/releases).

## Quick start

```sh
# Inspect mutation sites without executing the project.
litmus plan /path/to/package --output plan.json

# Build and run mutations in a separate workspace.
litmus run /path/to/package --trust-project --output /tmp/litmus-run

# Report the recorded results; fail on survivors and uncovered mutations.
litmus analyze /path/to/package --results /tmp/litmus-run/run.pb --format json --strict
```

For an Xcode project, run from a root containing its local package dependencies:

```sh
litmus run . --project App.xcodeproj --scheme AppTests \
  --destination 'platform=iOS Simulator,id=<SIMULATOR-UDID>' \
  --trust-project --output /tmp/litmus-ios
```

For an iOS-only Swift package, specify its scheme and destination without `--project`. If it depends on sibling packages, use the containing repository as the root and add `--package-path Modules/Library`. This preserves relative dependencies and the package's test-plan context. See [nested packages and configuration checks](docs/usage.md#packages-inside-a-repository).

## Pull request checks

```sh
litmus run . --trust-project --diff-base origin/main --budget 600 \
  --output /tmp/litmus-pr --report json
```

Only mutation sites on changed lines are selected by default. `--diff-scope files` selects all sites in changed files. A run with no selected mutations skips building and testing.

Use `--result-store DIR` to reuse eligible verdicts and `--baseline FILE --gate new-survivors` to report new survivors. A budget limits new work; it does not establish that every selected mutation was tested. See [CI and incremental runs](docs/ci.md).

## Results

| Verdict | Meaning |
| --- | --- |
| `killed` | Tests detect the mutation. |
| `crashed`, `timeout` | Execution crashes or exceeds its deadline after reaching the mutation. |
| `survived` | Tests pass after reaching the mutation. |
| `noCoverage` | No test reaches the mutation. |
| `unviable` | The mutation does not compile in isolation. |
| `infrastructureError`, `notRun` | No conclusive result is available. |

The mutation score is detected mutations divided by detected plus undetected mutations. Unviable mutations are excluded; unresolved results prevent a complete score. A high score is not proof of correctness.

## Documentation

- [Usage and configuration](docs/usage.md)
- [CI and incremental runs](docs/ci.md)
- [Execution model and limitations](docs/execution.md)
- [Testing and performance](docs/testing.md)
- [Security](SECURITY.md)
- [Release notes](release-notes/v0.3.2.md)

## License

See [LICENSE](LICENSE).
