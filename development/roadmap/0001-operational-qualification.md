# 0001 — Operational qualification gates

status: in-progress
blocked-by: healthy iOS simulator runner and independent review

1. Core parser/schema/verdict/artifact contracts and bounded source isolation.
2. Real host-package mutation fixture, including both killed and surviving mutants.
3. Xcode-generated `.xctestrun` fixtures and actual iOS package plus hosted-app runs.
4. Reference app build scripts/plugins and SwiftUI type-check cost comparison.
5. Profiling: cold/warm costs, launch overhead, compile inflation, resident memory, reliable concurrency.
6. Fault injection/fuzzing, independent code review, provenance/reproducible release checks.
7. Weekly and release PR integration with explicit head/base branch policy and no stale-green reports.

Per-test runtime attribution, simulator pooling, native protobuf facts, incremental verdict caching, advanced analyzer-inspired
operators and clone presentation are later work requiring separate ADRs and evidence. No “few weeks” delivery claim.
