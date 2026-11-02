# Security and operational assurance

Litmus is an initial local implementation, not a qualified/certified safety tool. Do not use its mutation outcomes as the
sole basis for release approval, regulatory acceptance or military/high-criticality deployment.

## Trust boundaries

- `plan` reads source/project files as data. It never executes a manifest to classify code.
- `run --trust-project` executes manifests, plugins, scripts and tests with the invoking user's authority.
- Independent file copies prevent accidental in-place mutation. They do **not** contain malicious project code.
- Use a disposable restricted macOS runner/VM for untrusted subjects. Do not mount credentials, signing material,
  production data or unrelated developer workspaces. Network restrictions and secrets policy are external controls.
- SHA-256 and protobuf framing detect corruption/changed content; unsigned artifacts may be forged by their author.
- Pin the toolchain and all external dependencies/settings/environment on CI. Reports verify copied input bytes, not
  permissions, extended attributes, external tool/network state or authenticity of an old artifact.

## Audited imported unsafe API calls

Strict memory safety and warnings-as-errors are enabled. Two imported Foundation surfaces need explicit audit:

1. `XMLParser.delegate` is imported `unowned(unsafe)`. The owner is retained across synchronous parsing through
   `withExtendedLifetime`, and the delegate pointer is cleared before the owner can be released.
2. `PropertyListSerialization.propertyList` exposes an optional output-format pointer. Litmus passes `nil` and owned,
   size-bounded `Data`; no caller-owned pointer is dereferenced or retained.

3. `PosixFile.pwrite` (aemi `AemiIO`) takes a raw buffer. `ResultJournal.append` passes the buffer of an owned array
   inside `withUnsafeBytes`, synchronously, under the journal's mutex; nothing escapes (upstream AE-1 asks for a safe
   overload).

No custom raw-pointer kernel, `unsafeBitCast`, force cast or `@unchecked Sendable` is introduced by Litmus.

## Subject processes

Direct execution sets `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` to the selected Xcode's macOS platform directories
for `swiftpm-testing-helper` and `xctest`, as SwiftPM does, and gives every run its own `TMPDIR` and marker directory.
The activation code compiled into the subject reads two environment variables and creates empty files named after
mutant identifiers (16 hexadecimal characters) in the marker directory; it never writes elsewhere.
Dependency code has its own audited unsafe surfaces; enabling strict memory safety here does not qualify dependencies.

## Resource and failure policy

See R-01–R-12 in the white paper. Process output is capped, commands have deadlines, and process groups are terminated on
cancellation. Simulator daemons are outside that group; no global CoreSimulator cleanup is performed. Interrupted/failed
runs retain incomplete evidence. If evidence cannot be decoded or reconciled, the gate is not green.

## Outstanding security/assurance work

Independent review; fuzzing of all external artifacts and parser boundaries; hostile filesystem/race tests; stronger test
identity/failure signatures; process fault injection; metadata/environment provenance; signed reproducible releases; a
qualification plan for whatever standard and criticality level the eventual operator actually requires.

No vulnerability-reporting endpoint or published GitHub repository has been established for this local project yet.
