# Cache soundness

**Property.** In `--reuse closure` mode (the default, and the only mode a pull-request gate may use), a verdict taken from a result store or a resumed run is the verdict a fresh run of the same mutant would give.

## Assumptions

- C1. Tests are deterministic given their inputs. The flakiness probe (`--baseline-repetitions`) leaves out tests that fail in any repetition of the unmutated suite.
- C2. A verdict depends only on:
  - the files of the mutant's package and of the local packages it depends on;
  - the toolchain, the build driver and its settings;
  - Litmus's version and execution policy;
  - the options that change how a verdict is decided.

  Tests that read the network, the clock or files outside the root break C2.
- C3. SHA-256 has no practical collisions. With `LITMUS_STORE_KEY` set, HMAC-SHA256 cannot be forged without the key.

## The key

`ReuseContext.key(m)` is the SHA-256 of these fields, separated by NUL:

| Field | Covers |
| --- | --- |
| `litmus-reuse/v1`, mode | the key's own format |
| context | `ReuseContextInputs`: tool version, execution policy, toolchain, driver, harness, fail-fast, kill confirmation, memory limit, timeout cap, factor and minimum, baseline repetitions, suite width, test-target selection, background priority, exclusions |
| mutant id, path, operator, original, replacement | the mutation itself |
| code | the digest of every input of the package closure containing `m` (analyzerkit's `packageClosure(containing:)`), or of the whole snapshot for an Xcode project or an unreadable layout |

**K1.** Any change to an input of C2 changes a field of the key (C3), so the stored verdict is not found.

**K2.** A mutant whose package depends on a local package outside the root is never reused (`outsideRoot`): the snapshot cannot see that package's changes.

**K3.** A record is used only after its SHA-256, or its HMAC when a key is set, verifies. A record that fails verification is a miss, never a verdict.

**K4.** `--only-id` never reuses the selected mutant's verdict: the person asked for a fresh one.

## Not sound, and labelled

`--reuse declaration` (nightly only) keys on the mutant's declaration and its covering test files instead of the closure. A change elsewhere in the module, such as a helper the declaration calls, does not change the key. Every verdict reused this way says so.

## Tests

- `a result store reuses every verdict of an unchanged subject without building` (`SnapshotAndRunnerTests`)
- `a store record that fails verification is a miss, never a verdict` (`SnapshotAndRunnerTests`)
- `only-id runs just the selected mutant and never reuses its earlier verdict` (`SnapshotAndRunnerTests`)
- `in place, a package depending on one outside the root is never reused` (`SnapshotAndRunnerTests`)
- `result store inspect, garbage-collect, pack, and unpack verify integrity and reject tampering` (`PhaseFTests`)
