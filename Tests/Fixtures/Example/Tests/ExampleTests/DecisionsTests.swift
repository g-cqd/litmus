import Example
import Testing

@Test func `gate rejects when only the second input is true`() {
    #expect(!gated(false, true))
}
@Test func `permission follows the flag`() {
    #expect(permitted(true))
    #expect(!permitted(false))
}
// Intentionally weak: both the original and swapped branch produce a positive value.
@Test func `label is positive`() {
    #expect(label(true) > 0)
}
