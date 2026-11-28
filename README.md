# Litmus

Mutation testing for Swift packages and Xcode projects.

Litmus introduces small changes to production code and runs your tests against them. A change that survives identifies behavior your tests may not check. Litmus batches mutations into instrumented builds, records which code the tests reach, and preserves the evidence behind each verdict.

## Requirements

- macOS 15.6 or later
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

Only mutation sites on changed lines are selected by default. `--diff-scope files` selects all sites in changed files. `--include-test-changes` also selects the production code a change's test edits can affect, so deleting or weakening a test is checked too. A run with no selected mutations skips building and testing.

## Reading a run

```sh
litmus analyze . --results /tmp/litmus-run/run.json --format html > report.html          # one offline page to explore
litmus analyze . --results run.json --format github-summary --compare base/run.json >> "$GITHUB_STEP_SUMMARY"
```

## Closing gaps with a coding agent

```sh
litmus analyze . --results /tmp/litmus-run/run.json --format agent --domain logic   # every gap, self-contained
litmus run . --trust-project --only-id <id> --output "$(mktemp -d)/run"             # re-verify one mutant
litmus accept <id> --from /tmp/litmus-run --reason "<proof of equivalence>"         # out-of-source acceptance
litmus agent-guide --install                                                        # the workflow, as an agent skill
```

Agents that speak MCP can use `litmus mcp` instead: plan, run, gaps and accept as tools, with warm incremental builds between calls. For example, in an MCP client's configuration: `{"command": "litmus", "args": ["mcp"]}`. While you work, `litmus watch . -- --trust-project` reruns what each save changes.

See [usage](docs/usage.md#mutation-scope) for selectors, acceptance files and stale acceptances.

Use `--minimum-score PERCENT` to fail below a mutation score, `--operator-tier standard` for comparison, boolean and arithmetic mutations, and the [GitHub Action](docs/ci.md#github-action) to run it on a runner. Use `--result-store DIR` to reuse eligible verdicts and `--baseline FILE --gate new-survivors` to report new survivors. A budget limits new work; it does not establish that every selected mutation was tested. See [CI and incremental runs](docs/ci.md).

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
- [Operators](docs/operators.md)
- [CI and incremental runs](docs/ci.md)
- [Execution model and limitations](docs/execution.md)
- [Testing and performance](docs/testing.md)
- [CLI, exit-code, and schema stability](docs/stability.md)
- [Invariants: restoration, cache soundness, shared-process equivalence](docs/formal/README.md)
- [Benchmark against other Swift mutation testers](docs/benchmark.md)
- [Security](SECURITY.md)
- [Release notes](release-notes/v1.2.1.md)

## License

See [LICENSE](LICENSE).

## Contributing & Security

- [Contributing](CONTRIBUTING.md)
- [Security](SECURITY.md)
- [License](LICENSE)
## Privacy & Verification

- **Privacy:** `litmus` runs 100% offline with zero network calls, zero telemetry, and zero personal data collection. See [`PRIVACY.md`](PRIVACY.md).
- **Security & Signatures:** Commits and release tags are GPG-signed (`1BF1 901A 8C67 2E9B C12E 1B31 9FE7 C7E8 522E E497`), and published release archives carry SHA-256 checksums and GitHub SLSA build provenance attestations (`gh attestation verify`). See [`SECURITY.md`](SECURITY.md).
