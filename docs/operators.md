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
| `remove-view-element` | UI (`--ui-operators`) | skip a leaf SwiftUI view-builder element (reported separately from logic score) |
| `negate-disabled` | UI (`--ui-operators`) | negate a SwiftUI `.disabled(...)` predicate |
| `remove-presentation` | UI (`--ui-operators`) | suppress `.sheet`, `.fullScreenCover`, `.popover`, `.alert`, `.confirmationDialog`, and `.navigationDestination` |
| `remove-view-action` | UI (`--ui-operators`) | skip a `Button` action, or the closure body of `.onAppear`, `.onDisappear`, `.task`, `.refreshable`, `.onSubmit`, `.onChange`, `.onTapGesture`, and `.onLongPressGesture` |
| `neutralize-view-modifier` | UI (`--ui-operators`) | `.opacity(x)` to `0` and `.allowsHitTesting(x)` to `!(x)`; the view's type does not change |
| `remove-accessibility-metadata` | UI (opt-in by name) | blank a literal `.accessibilityLabel`/`.accessibilityHint` and negate `.accessibilityHidden` |
| `replace-stdlib-semantic` | experimental (opt-in) | swap standard-library semantic pairs (`min`/`max`, `allSatisfy`/`contains`, `prefix`/`dropLast`, `dropFirst`/`suffix`, `hasPrefix`/`hasSuffix`) |
| `remove-normalization` | experimental (opt-in) | remove String normalization calls (`.lowercased()`, `.uppercased()`, `.trimmingCharacters(in:)`) |
| `replace-optional-chain` | experimental (opt-in) | force-unwrap an optional-chained expression (`a?.b` to `a!.b`, outside assignment targets) |
| `return-boundary` | experimental (opt-in) | shift or empty a typed return value (`(n) + 1`, `""`, `[]`) |
| `return-constant` | experimental (opt-in) | replace a typed return value with a boundary constant (`0`, `1`, `nil`, `true`, `false`) |
| `empty-body` | experimental (opt-in) | skip the body of a non-throwing `Void`-returning function or method |
| `empty-closure-body` | experimental (opt-in) | skip the body of a trailing `Void` closure (excluding `withLock`, `sync`, `autoreleasepool`, `assumeIsolated`) |
| `remove-switch-case` | experimental (opt-in) | guard a non-default `switch` case (`where !marker`) so it falls through to `default` |
| `nullify-optional-binding` | experimental (opt-in) | force `if let`, `guard let` or `while let` bindings (explicit, `try`/`await`, or shorthand `if let x`) to evaluate to `nil` |
| `negate-is-empty` | experimental (opt-in) | negate non-optional `.isEmpty` property accesses outside direct conditions |
| `skip-loop` | experimental (opt-in) | guard a `for … in` loop with `where !marker` so its body runs zero times |
| `swap-break-continue` | experimental (opt-in) | exchange unlabeled `break` and `continue` statements inside loops |
| `replace-bitwise` | experimental (opt-in) | exchange `&` and `\|`, `^` to `&`, `<<` and `>>`, and compound `&=`/`\|=`/`^=` |
| `remove-unary-minus` | experimental (opt-in) | remove unary `-` on non-literal expressions (`-x` to `x`) |
| `replace-collection-transform` | experimental (opt-in, type-directed) | replace `.sorted()` with `Array(x)`, `.filter(...)` with `x`/`Array(x)`, and `Array(x.reversed())` with `Array(x)` |
| `swap-first-last` | experimental (opt-in, type-directed) | exchange `.first` and `.last` on bidirectional collections (`Array`, `ArraySlice`, `String`) |
| `remove-defer` | fault (`--fault-operators`) | skip the body of a `defer` block at scope exit (excluding lock unlocks) |
| `remove-cleanup-call` | fault (`--fault-operators`) | skip standalone cleanup calls (`cancel`, `invalidate`, `close`, `finish`, `removeObserver`, …) |
| `weaken-capture` | fault (`--fault-operators`) | retain a `weak` or `unowned` closure capture strongly to test retain-cycle / deallocation checks |
| `swap-async-order` | fault (`--fault-operators`) | reverse two adjacent `await` call statements |

## What is left alone

- Every operator: tests, previews, generated code, debug-only regions, macro arguments, attribute arguments (compile-time constants), enum case declarations (raw values), declarations matching `excludeDeclarations`, and arguments of `aridCalls` / debug logging (`debugPrint`, `dump`, `NSLog`, `os_log`, `Logger.*`).
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
