# Probes of the 2026-11-02 session review

Run from this directory with Xcode 27.2 / Swift 6.4.2.

- `private-selector-failure.swift`: `xcrun swiftc -typecheck private-selector-failure.swift -module-name Cur -parse-as-library -swift-version 6`
  fails twice: the current `private` selector cannot be used in a public default argument or an `@inlinable` body (D2).
- `main-swift-crash.swift`: copied to `main.swift` and compiled, it exits 139 with `LITMUS_ACTIVE_ID=01`: the selector appended
  after top-level code is read before initialisation (D3).
- `logical-precedence.swift`: prints `text-replacement: true intended: false`: unparenthesised operand text changes the mutant (D1).
- `activation-design.swift`: the proposed once-initialised per-mutant activation; type-checks with `-sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)"
  -target arm64-apple-ios17.0-simulator -module-name Lib -parse-as-library -warnings-as-errors` and each of: `-swift-version 6 -strict-memory-safety
  -enable-upcoming-feature ExistentialAny -enable-upcoming-feature InternalImportsByDefault -enable-upcoming-feature MemberImportVisibility`;
  `-swift-version 6 -default-isolation MainActor -strict-memory-safety`; `-swift-version 5`; `-swift-version 6 -enable-library-evolution`;
  `-swift-version 6 -enable-upcoming-feature NonisolatedNonsendingByDefault -enable-upcoming-feature InferIsolatedConformances`.
  Type-checking only: not yet run in a test process, and not yet checked in `main.swift`.
