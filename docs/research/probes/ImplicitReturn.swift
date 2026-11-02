// swift-format-ignore-file
// Probe of generated mutation shapes; see ../2026-11-02-mutation-extent-and-thoroughness.md.
let m = CommandLine.arguments.count > 3
func implicit(_ a: Bool) -> Bool {
    if m { return false }
    a
}
