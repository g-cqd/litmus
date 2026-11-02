// swift-format-ignore-file
// Generated-code shape on purpose: imports and selectors after the code, as Litmus writes them.
let a = true, b = false, c = false
// original a || b || c folds as (a || b) || c ; intended mutant of the OUTER operator: (a || b) && c == false
print("text-replacement:", a || b && c, "intended:", (a || b) && c)
