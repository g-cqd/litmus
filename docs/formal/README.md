# Invariants

Three properties Litmus's verdicts rely on, each stated with its assumptions, the argument from the code, and the tests that check it. These are written arguments, not machine-checked proofs: a change to the code they cite should update them.

| Document | Property |
| --- | --- |
| [Workspace restoration](workspace-restoration.md) | A run never loses or corrupts the subject's source, including when it crashes or is cancelled. |
| [Cache soundness](cache-soundness.md) | A reused verdict is the verdict a fresh run would give, under the closure reuse key. |
| [Shared-process equivalence](shared-process-equivalence.md) | `--shared-process on`, `auto` and `off` give the same verdict for every mutant. |
