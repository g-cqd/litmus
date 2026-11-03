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

Both package tests and the standalone smoke command select `TOOLCHAINS=swift`:
Litmus invokes xcrun for subject builds, which otherwise can choose Xcode's
older compiler even after a newer swift.org toolchain is installed on PATH.
The command exports this explicitly because `swift.environment` applies to
built-in package steps, not arbitrary shell commands.
