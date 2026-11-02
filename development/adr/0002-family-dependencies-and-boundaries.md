# ADR 0002 — Reuse the family foundations, not every analyzer engine

Status: accepted
Date: 2026-11-02

## Context

The user requests analyzer-family conventions and reliance on aemi, AemiJSON and AemiProtobuf. Foundation alone cannot
supply the family contracts; adding all analyzer engines would enlarge the trusted computing base without speeding tests.

## Decision

Pin analyzerkit and its compatible aemi/codec revisions. Select specific products only. SwiftSyntax handles parsing;
ArgumentParser supplies the CLI; Apple CryptoKit supplies SHA-256. aemi XXH64 is for diagnostic IDs, never authenticity.
AemiJSON owns external model encoding. AemiProtobufCore owns a versioned binary envelope containing that same model and
an integrity digest. Do not claim this envelope is native per-field protobuf optimization or cryptographic signing.

Use SourceCorpus, ProjectModel, Suppression, ReportSupport and IndexStoreSupport's bounded process boundary. Keep the
mutation/test/simulator-specific policy in Litmus. Take conceptual lessons from every analyzer without importing each Core.

SharedConfiguration's pinned version has a closed set of five tool-section names. Until an upstream compatibility change
is agreed, `.litmus.json` is the execution/planning configuration. Existing shared top-level settings can be read through
analyzerkit, but a `litmus` section in `.swift-analyzers.json` is not advertised as supported.

## Consequences

Local sibling repositories are references, not mutable path dependencies. Lockfile and upstream pins make resolution
reviewable. Dependency code has its own unsafe surfaces; strict memory safety on Litmus is not a proof about all dependencies.
