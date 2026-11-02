# ADR 0004 — Non-overlapping expression schemas; build drivers are explicit

Status: accepted
Date: 2026-11-02

## Context

The reference plan has 4176 sites; 1832 are incompatible with the reference tool's schema classification. Many occur in
implicit getters/builders/initializers. The saved expression probe type-checks, but does not prove all Swift semantics.

## Decision

For a batch, replace a supported expression with `(selector == id ? replacement : original)`.
The selector is a private immutable String from startup environment. Prevent symbol collisions, validate source SHA-256
and byte ranges, and partition overlapping expressions into different bounded batches. Never recursively duplicate nested
rewrites. The compiler and inactive baseline validate each schema. Do not promise exactly one build for the whole corpus.

Only expression elements of condition lists are negated; bindings and availability syntax are preserved. Fold standard
operators with SwiftOperators. Treat unsupported custom operators/effects/builders as unqualified until fixtures establish them.

A host package uses `swift build --build-tests` and `swift test --skip-build`. An iOS package uses Xcode's package scheme;
projects/workspaces use explicit relative containers. Every Xcode execution requires an explicit scheme/destination.
Forward the active ID via each test target's `.xctestrun` environment and preserve test-root path resolution.

## Consequences

Build reuse is per non-overlapping batch, not an unconditional build-once claim. Extra inactive controls and Foundation
injection have measurable costs. iOS driver correctness needs a real simulator fixture before production support is claimed.
