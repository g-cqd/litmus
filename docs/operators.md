# Operators

Each operator has a rule identifier, used by `--operators`, by suppression directives
(`// @lm:accept:next replace-relational -- reason`), and in reports.

| Rule | Tier | Mutation |
| --- | --- | --- |
| `negate-condition` | stable | negate an `if`, `guard` or `while` condition |
| `swap-ternary` | stable | negate the condition of a ternary |
| `replace-logical` | stable | exchange `&&` and `\|\|`, keeping operand grouping |
| `replace-relational` | standard | `<` to `<=` and `>=`; `<=` to `<` and `>`; `>` to `>=` and `<=`; `>=` to `>` and `<`; `==` and `!=` exchanged |
| `flip-boolean` | standard | `true` and `false` exchanged |
| `replace-arithmetic` | standard | `+` and `-` exchanged, `*` and `/` exchanged, `%` to `*`, and compound assignments (`+=`, `-=`, `*=`, `/=`, `%=`) |
| `replace-range` | standard | shift range upper bounds (`a..<b` to `a..<((b) + 1)`, `a...b` to `a...((b) - 1)`) |
| `remove-negation` | standard | remove unary logical negation (`!x` to `x`) outside direct conditions |
| `replace-nil-coalescing` | standard | replace nil-coalescing (`a ?? b`) with its fallback (`b`) |
| `remove-call` | experimental | skip a call statement whose result is unused |
| `remove-view-element` | experimental (UI, opt-in) | skip a leaf SwiftUI view-builder element (`--operators` only; reported separately from logic score) |

## What is left alone

- Every operator: tests, previews, generated code, debug-only regions, macro arguments, attribute arguments (compile-time constants), enum case declarations (raw values).
- `replace-relational`: `===` and `!==`, and operators Litmus does not list (`&+`, `..<`).
- `flip-boolean`: a literal in a `case` pattern, where it is matched and not evaluated.
- `replace-arithmetic`: an operand that is a string literal (concatenation; its `-` never compiles).
- `remove-call`: `print`, `debugPrint`, `dump`, `NSLog`, `os_log`, `assert`, `assertionFailure`, `precondition`, `preconditionFailure`, `fatalError` and logger methods (`.debug`, `.info`, `.error` and the like); `super.init` and `self.init`; a call that is the only statement of a closure, getter, or function with a result (it may be the returned value); anything inside a result builder (`@...Builder`, `var body: some ...`).

A removed call is written as `if !marker { call }`, so the statement keeps its place in the code; `try` and `await` stay inside it.

## What they find

Run with `--operator-tier experimental` on two sample libraries, a general-purpose one (A) and one built on checked integer arithmetic (B); one build per batch, no unviable mutants in either:

| Rule | A (killed / survived) | B (killed / crashed / survived) |
| --- | --- | --- |
| `negate-condition` | 11 / 2 | 16 / 1 / 0 |
| `replace-relational` | 25 / 7 | 18 / 10 / 0 |
| `replace-arithmetic` | 6 / 0 | 18 / 126 / 0 |
| `flip-boolean` | 8 / 1 | none |
| `remove-call` | 3 / 0 | 14 / 0 / 10 |

Read three things from it. `replace-relational` finds the most survivors in ordinary code, which is its purpose: boundary shifts are the commonest gap. `replace-arithmetic` in code with checked integer arithmetic mostly traps, so it reports `crashed`; a crash is a detection, but a weak one that says little about the assertions. `remove-call` found the most survivors per mutant in B, where calls to mutating helpers had no test checking their effect; it is experimental because a surviving removal is more often an equivalent or untestable call than a surviving comparison is.

Two packages are not a benchmark. Treat the table as the reason the default stays `stable`, not as a rate to expect.
