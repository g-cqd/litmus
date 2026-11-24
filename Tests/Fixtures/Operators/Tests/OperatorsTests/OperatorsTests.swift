import Operators
import Testing

@Test func `total multiplies`() { #expect(total(4, 3) == 12) }
@Test func `average divides`() { #expect(average(10, 2) == 5) }
@Test func `offset keeps the value`() { #expect(offset(5) == 5) }
@Test func `a value inside and outside the limit`() {
    #expect(within(3, 5))
    #expect(!within(9, 5))
}
@Test func `enabled is true`() { #expect(isEnabled()) }
@Test func `the banner is joined`() { #expect(banner == "operators") }
@Test func `ping records both`() {
    let recorder = Recorder()
    ping(recorder)
    #expect(recorder.items == ["ping", "pong"])
}
@Test func `warm runs without a check`() { warm(Recorder()) }
@Test func `noisy records`() {
    let recorder = Recorder()
    noisy(recorder)
    #expect(recorder.items == ["noisy"])
}
