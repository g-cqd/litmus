import Testing

@testable import ExampleApp

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

@Test func `clamp keeps a small value`() { #expect(clamp(5) == 5) }
@Test func `sign of a positive value`() { #expect(sign(3) == 1) }
@Test func `an index past the end gives nil`() { #expect(element([1], 5) == nil) }
@Test func `drain reaches zero`() { #expect(drain(3) == 0) }
@Test func `overlap keeps the common bits`() { #expect(overlap(Mask(0b1100), Mask(0b1010)) == Mask(0b1000)) }
