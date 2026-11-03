# CI

The pinned swift-ci workflow and local CLI read `action.json`. Litmus drives
Xcode, xcrun and simulators, so whole-package Linux builds are deliberately off.
Quality still runs on Linux from the pinned formatter/analyzer archives.

The real fixture smoke test runs as its own macOS command on schedule, tags and
manual dispatch. It explicitly builds Litmus and obtains the executable path
from SwiftPM: it does not rely on another job's build tree or `.build/debug`
layout. Do not attach it `after: macos-debug` with a separate cadence: attached
commands inherit the host's cadence and ignore their own `os` and `cadence`.

Ordinary changes run macOS debug tests. Release and sanitizer tests run on the
heavy cadence; tag archives and publication use the shared release graph.

The standalone smoke command builds and locates Litmus with SwiftPM first, then sets `TOOLCHAINS=swift` only for the smoke process. Litmus invokes `xcrun` for subject builds, which otherwise can choose Xcode's older compiler. Do not export `TOOLCHAINS=swift` globally: it conflicts with Swiftly's toolchain selection for the main package build.

The Dolly baseline accepts repeated native/simulator harness control flow, mutation-run control blocks, and CLI option scaffolding. The package-selection changes shift location-sensitive fingerprints; the refreshed baseline contains 25 clone groups. Shared build-selection options are factored into one option group rather than duplicated between `run` and `check`.
