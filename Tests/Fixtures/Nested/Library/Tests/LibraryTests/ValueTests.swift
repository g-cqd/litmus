import Testing

@testable import Library

@Test func values() { #expect(value(true) == 1); #expect(value(false) == 2) }
