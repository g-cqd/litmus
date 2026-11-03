# Testing and performance

## Run the tests

```sh
swift build --build-tests
swift test --skip-build
bash scripts/smoke.sh
```

For optimized tests, enable testable modules explicitly:

```sh
swift build --scratch-path .build-release -c release --build-tests -Xswiftc -enable-testing
swift test --scratch-path .build-release -c release --skip-build -Xswiftc -enable-testing
```

The unit and integration suite covers planning, evidence decoding, process supervision, workspaces, result reuse, reporting, and sharding. The smoke script runs real fixture mutations and checks kills, crashes, timeouts, survivors, uncovered and unviable mutations, source restoration, reports, gates, budgets, reuse, and interruption handling.

Xcode and simulator execution also depend on the installed Xcode version, available destinations, and the project's test configuration. A passing host test suite does not establish compatibility with every simulator or project.

## Performance characteristics

Litmus reduces build work by compiling mutation batches rather than each mutation separately. Inactive controls identify unreached sites; target selection and optional per-test reach reduce test execution. Persistent workspaces preserve build output, and compatible stored verdicts avoid repeating completed work.

Performance depends on build size, test duration, mutation density, suite parallelism, and machine load. There is no universal speedup factor. Compare runs with the same toolchain, source, tests, and options, and record cold versus warm build and store state.

Each run reports build and test counts, CPU usage, peak sampled child memory, disk usage, and elapsed time. Use those fields to evaluate CI budgets. A diff selecting no mutation sites skips build and test work; that is a scope result, not evidence that the full project has no surviving mutations.
