# Recommended amendments to analyzerkit, aemi, AemiJSON and AemiProtobuf

Litmus 0.2.0-dev pins analyzerkit `fb3f5d6`, aemi `921fd8d`, AemiJSON `172164f` and AemiProtobuf `418182e`. It uses
them wherever they fit (table at the end) and works around eleven gaps locally. Each recommendation below names
the gap, what Litmus does meanwhile, and the evidence. None of these repositories was modified.

Priority: **P1** blocks a correctness or reliability property in Litmus or another analyzer; **P2** removes duplicated
code or a measurable cost; **P3** is a convenience.

## analyzerkit

| Id | Pri | Component | Gap | Litmus meanwhile | Recommended change |
| --- | --- | --- | --- | --- | --- |
| AK-1 | P1 | `IndexStoreSupport.BoundedProcess` | No way to stop a child on a condition seen while it runs, and no streaming of its output | Races the process against a task that polls the Swift Testing event file, then cancels the task, so `BoundedProcess` tears down the process group (`Harness.swift`, `runWatching`) | `run(…, monitor:)` taking an async closure over output chunks, or returning an `AsyncSequence` of chunks with an explicit `terminate()`; documented TERM/KILL semantics either way |
| AK-2 | P1 | `BoundedProcess.Result` | A signal is reported as `128 + signal` in `exitStatus`, so a crash cannot be told from a program that exits 134 itself | Treats `exitStatus ≥ 128` from `xctest` as a crash, a documented ambiguity | Add `terminationSignal: Int32?` beside `exitStatus` (the information exists in `waitpid`) |
| AK-3 | P2 | `BoundedProcess.allowedEnvironmentKeys` | A closed allow-list that drops `DEVELOPER_DIR`, `DYLD_*` and `TOOLCHAINS`; every tool that runs Xcode tools re-adds them | Re-adds `DEVELOPER_DIR` and sets `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` explicitly (`subjectEnvironment`) | An `EnvironmentPolicy` value: `.scrubbed`, `.toolchain` (adds `DEVELOPER_DIR`, `TOOLCHAINS`, `SDKROOT`), `.scrubbed(adding:)`, so the intent is visible at call sites |
| AK-4 | P2 | `BoundedProcess.Result` | No resource usage of the child | Measures wall time only | Return `rusage` of the child (user and system CPU, maximum RSS): per-mutant cost accounting and memory budgets |
| AK-5 | P1 | `AnalyzerConfiguration.SharedConfiguration` | `toolNames` is a closed set of five tools, so `.swift-analyzers.json` rejects a `litmus` section | Reads only `.litmus.json` and the shared top-level keys | Always accept the section of the calling `Tool`, and keep rejecting unknown sections only for tools that registered |
| AK-6 | P1 | `ReportSupport.ToolReportFormat.format` | JSON encoding failure returns `"{}"`, a report that looks empty and clean | Renders JSON and SARIF itself with a throwing AemiJSON encoder (`LitmusReportFormat.render`) | A throwing `format`; the non-throwing one deprecated |
| AK-7 | P2 | `ReportSupport.Fingerprint` | FNV-1a over rule, path, **line and column**: an edit above a finding renews its fingerprint | Mutant ids hash path, byte range, operator and text; report fingerprints stay line-based | An optional content-anchored fingerprint: rule, path, enclosing declaration, normalised text, ordinal within the declaration (ADR-0009/0015 change) |
| AK-8 | P2 | `ProjectModel.ProjectClassification` | Knows which target compiles a file, but not which **test** targets depend on that target, nor scheme or test-plan membership | Uses the provenance only to skip files no target compiles (`.convention(.unclaimed)`) | `testTargets(covering path:)` from manifests and `project.pbxproj` dependencies, and scheme/test-plan reading: lets a mutation tool, deadwood and swift-search pick test targets without a build |
| AK-9 | P2 | `ProjectModel.CompilationConditions` | Host `os()` only, fixed Swift and compiler versions, `canImport` not modelled | Mutates every clause; a site in an inactive clause ends as `noCoverage`, reported but never built in | Per-target conditions from build settings (`SWIFT_ACTIVE_COMPILATION_CONDITIONS`, `SDKROOT`, platform) and `canImport` from the SDK's module list |
| AK-10 | P2 | `SourceCorpus` | No bounded, link-refusing copy of a tree with content identity | `WorkspaceSnapshot` on aemi's `DirectoryWalk`, `BoundedFileReader` and SHA-256 | A `TreeSnapshot` primitive (copy, inventory, SHA-256 manifest, verification), reusable by deadwood's index-store builds in an isolated copy |
| AK-11 | P3 | `ProjectModel.CodeRegionScanner` | Line spans only; a site on a line shared with a preview is excluded whole | Excludes by line | Byte ranges beside the lines |

## aemi

| Id | Pri | Component | Gap | Litmus meanwhile | Recommended change |
| --- | --- | --- | --- | --- | --- |
| AE-1 | P1 | `AemiIO.PosixFile` | Only `pread`/`pwrite` over raw buffer pointers; a strict-memory-safety client must write `unsafe` | One audited `unsafe pwrite` in `ResultJournal.append` | Safe `write(_ bytes: [UInt8], at:)`, `read(at:count:) -> [UInt8]`, and `RawSpan`/`OutputSpan` overloads |
| AE-2 | P1 | `AemiIO` | No durable atomic replace (temporary file, `fsync`, `rename`, `fsync` of the directory) and no `O_EXCL` creation | Foundation `.atomic` (no directory sync) for checkpoints; `ResultJournal` refuses an existing file by a racy existence check | `PosixFile.Mode.create(exclusive:)` and `AtomicFile.replace(at:with:durability:)` |
| AE-3 | P2 | `AemiIO` | No copy-on-write copy (`clonefile`, `copyfile(COPYFILE_CLONE)`) | Reads and writes every byte of the snapshot | `PosixFile.clone(from:to:)` with a fallback copy; snapshot cost on APFS becomes metadata-only |
| AE-4 | P2 | `AemiFileSystem.DirectoryWalk.Policy.isCancelled` | Called on walker threads, where `Task.isCancelled` reads the wrong task, so passing it silently never cancels | Checks cancellation before the walk only | Accept a cancellation token (`Atomic<Bool>` or a `Task` handle captured by the caller) and document that the predicate runs off-task |
| AE-5 | P2 | `AemiRuntime.mapConcurrently` | Returns all results at the end | Journals verdicts after each batch's parallel pass: a crash loses at most one batch's verdicts, not their evidence | An unordered streaming variant (`AsyncThrowingStream` of `(index, result)`) with the same bound and cancellation |
| AE-6 | P3 | `AemiRuntime.ResourcePool` | The factory is `init?(path:)`; `checkout` returns nil when drained | `WorkerSlot: PooledResource` creates a directory from the path; the pool is sized to the concurrency limit so it never drains | A closure factory and an `async` checkout that waits |
| AE-7 | P2 | `AemiMetrics.ProcessProbe` | Measures the current process only | Reports wall time per phase and per mutant | Children's resource usage (`RUSAGE_CHILDREN`) for CPU-time accounting of test runs |
| AE-8 | P3 | `AemiKernel` | Fast identity hashes (XXH64, wyhash) but no cryptographic digest, so Linux builds need another package | CryptoKit SHA-256 (Apple only) | Re-export swift-crypto's SHA-256 behind a `ContentDigest` protocol rather than implementing one |

## AemiJSON and AemiProtobuf

| Id | Pri | Component | Gap | Litmus meanwhile | Recommended change |
| --- | --- | --- | --- | --- | --- |
| AJ-1 | P2 | AemiJSON | No incremental JSON Lines reader that keeps a partial last line | `TestEvidence.swiftTestingEvents` splits lines and parses each with the lazy tape | `AemiJSON.lines(_ bytes:) -> (documents, consumed)` and an `AsyncSequence` over a growing file |
| AP-1 | P2 | AemiProtobufCore | No length-delimited message stream (`writeDelimited`/`readDelimited`) | `ResultJournal` writes and reads varint frames by hand, and reports a truncated last frame | Framed stream reader and writer with a truncation result, not an error |
| AP-2 | P3 | AemiProtobuf | Artifacts are Codable structures with enums, optionals and nested arrays | The protobuf envelope carries AemiJSON bytes plus a SHA-256 | `@ProtoMessage` coverage of these shapes, so journal records become native messages (smaller, no JSON parse on read) |

## What Litmus already takes from them

| Need | Provided by |
| --- | --- |
| Discovery, canonical paths, path filters, bounded reads, line index, large-stack parsing, syntax-depth guard | analyzerkit `SourceCorpus`, `ProjectModel` (`SyntaxDepth`) |
| Project layout, file classification and target provenance, regions, test and generated-code conventions | analyzerkit `ProjectModel` |
| Suppression comments (`// @lm:accept …`) | analyzerkit `Suppression` |
| Process supervision (session, deadline, TERM/KILL, output caps, scrubbed environment) | analyzerkit `IndexStoreSupport.BoundedProcess` |
| Report envelope, SARIF model and columns, Xcode diagnostics, fingerprints, exit statuses, CLI option groups | analyzerkit `ReportSupport`, `AnalyzerCLI` |
| Shared configuration keys and validation | analyzerkit `AnalyzerConfiguration` |
| Snapshot and inventory walk (no link followed, bounded, parallel) | aemi `AemiFileSystem.DirectoryWalk` |
| Bounded parallel hashing, copying, planning and mutant execution | aemi `AemiRuntime.mapConcurrently` |
| Worker slots | aemi `AemiRuntime.ResourcePool` |
| Journal writes with an ordering barrier | aemi `AemiIO.PosixFile`, `DurabilityProfile.barrier` |
| Mutant identities (XXH64) and hexadecimal digests | aemi `AemiKernel` |
| Artifacts, configuration, event-stream parsing (lazy tape), I-JSON decoding | AemiJSON |
| Artifact envelope and verdict journal frames | AemiProtobufCore `WireWriter`/`WireReader` |
