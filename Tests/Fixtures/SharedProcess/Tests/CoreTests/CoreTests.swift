import Testing

@testable import Core

@Test func retries() { #expect(Limits.maxRetries == 3) }
@Test func strictness() { #expect(!isStrict(1)); #expect(isStrict(9)) }
@Test func pageSize() { #expect(Settings.shared.pageSize == 20) }
@Test func positivePage() { #expect(computePageSize(4) == 8) }
@Test func ledgerGrows() {
    let before = ledger.count
    #expect(record(5) == before + 1)
}
@Test func ledgerIsClean() { #expect(!ledger.contains(-1)) }
@Test func headroomBelowTen() { #expect(headroom(3) == 7) }
@Test func grades() { #expect(grade(95) == "A"); #expect(grade(60) == "B"); #expect(grade(10) == "C") }
@Test func clamping() { #expect(clamp(5, to: 10) == 5) }
