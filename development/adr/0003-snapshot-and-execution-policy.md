# ADR 0003 — Independent source snapshot and conservative process-per-mutant execution

Status: accepted
Date: 2026-11-02

## Decision

Never mutate an original checkout, even with an automatic restoration promise. Copy bounded regular inputs into a new
owned run directory outside the source; reject links/special files rather than silently follow them. Keep failed snapshots
for diagnosis. Preserve all copied input hashes, including tests, resources and build settings.

Use bounded subprocess supervision with absolute paths and explicit argv, no shell. The user must opt into trusted
project execution. Do not restart or globally clean simulator services owned by the user. Do not claim the copy is an OS sandbox.

Validate original/inactive baselines, run one mutant per test process, require structured executed-test evidence,
and confirm apparent kills twice with a passing inactive control between them. A timeout or a failed schema build is
unresolved, not killed. Keep one outcome per plan site and checkpoint after each decision.

## Alternatives rejected

In-place edits risk data loss after crashes; hard links risk source writes; APFS clones alone do not solve build-script
path assumptions. Persistent/multi-mutant workers risk state contamination and attribution errors. Static name reachability
is not a sound full-suite replacement. Rejecting all links is strict, but makes the first isolation contract reviewable.

## SwiftPM transport detail (observed during implementation)

Swift 6.4 emits Swift Testing xUnit as `NAME-swift-testing.xml`, separately from the requested XCTest `NAME.xml`.
XCTest xUnit emission requires SwiftPM's parallel runner; use `--parallel --num-workers 1` and sum both structured files.
Thus “process per mutant” means a fresh full-suite invocation; SwiftPM may spawn per-XCTest-case child processes. This is
extra launch cost, not a speed improvement claim. Do not parse console summaries or discard one framework's results.
