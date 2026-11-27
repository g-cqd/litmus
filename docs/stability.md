# CLI, Exit-Code, and Schema Stability

This document defines the compatibility contract for Litmus's CLI subcommands, exit statuses, configuration files, and machine-readable artifacts.

## Subcommands and flags

Top-level subcommands (`plan`, `run`, `analyze`, `census`, `accept`, `unaccept`, `merge`, `store`, `restore`, `clean`, `check`, `agent-guide`) and their documented option names follow semantic versioning:

- Patch and minor releases add optional flags or fields and preserve existing flag spellings and defaults unless a breaking behavioral change is explicitly called out in `release-notes/`.
- Unknown flags, invalid selectors, or conflicting option combinations fail fast with exit code `64` (`EX_USAGE`).

## Exit codes

Litmus shares `AnalyzerCLI`'s exit-code contract across all subcommands:

| Code | Meaning |
| ---: | --- |
| `0` | Clean execution; all active gates passed. |
| `1` | Findings gate failed (`--strict`, `--gate new-survivors`, `--minimum-score`, or `--maximum-score-drop`). |
| `2` | Configuration or input validation error (unreadable baseline, untrusted store archive, invalid config). |
| `3` | Internal execution or baseline failure (unmutated tests failed, build error, incomplete run). |
| `4` | Output write failure. |
| `64` | Command-line usage error. |

## Machine-readable artifacts

| Artifact | Version / Schema | Compatibility |
| --- | --- | --- |
| `.litmus.json` | Keyed JSON object | Unknown keys are rejected so typos fail closed; new optional keys remain backward-compatible. |
| `.litmus-accepted.json` | `AcceptanceFile` (`schemaVersion: 1`) | Shared across the `analyzerkit` tool family; anchored by path, declaration, operator, and normalized source/replacement text. |
| Baseline file (`--write-baseline`) | `BaselineFile` (`version: 1`, `tool: "litmus"`) | Stores anchored (`a…`) and classic (`f…`) fingerprints; requires matching `tool` and version. |
| `run.json` / `run.pb` | `RunArtifact` + `executionPolicy` (`inactive-schema-baseline/v5`) | Carries `provenance.toolVersion` and `provenance.executionPolicy`; additive fields default cleanly when decoding older minor versions. |
| `analyze --format json` | `MutationReport` | Additive top-level fields (`operators`, `findings`, `score`, `policy`, `executionTimings`). |
| `analyze --format agent` | `AgentReport` (`schemaVersion: 1`) | Self-contained gap records for coding agents (`summary`, `gaps`). |
| `analyze --format sarif` | SARIF `2.1.0` | Includes `litmus/anchored/v1` partial fingerprints for code-scanning deduplication. |
| `analyze --format stryker` | `mutation-testing-report-schema` `2` | Compatible with Stryker dashboard and HTML report viewers. |
| `analyze --format github` | GitHub Actions workflow commands | Emits `::warning`, `::error`, and `::notice` lines (capped at 50 inline annotations per step). |
| `analyze --format github-summary` | Markdown for `$GITHUB_STEP_SUMMARY` | For people, not parsers: its layout may change in any minor version. |
| `analyze --format html` | One self-contained HTML page | For people, not parsers: its layout and embedded data may change in any minor version. It makes no network request (`Content-Security-Policy: default-src 'none'`). |
| Result store (`v1/records/*.rec`, `litmus store pack`) | Envelope `v1` (`litmus-store-pack/v1`) | Keyed by `litmus-reuse/v1` digest (including `toolVersion` and `executionPolicy`), verified by SHA-256 or `LITMUS_STORE_KEY` HMAC-SHA256 on every read and unpack. |
