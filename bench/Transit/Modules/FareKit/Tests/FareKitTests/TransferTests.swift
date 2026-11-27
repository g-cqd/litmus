import FareKit
import Testing

@Suite struct TransferTests {
    let policy = TransferPolicy()

    @Test func `a change within the window is free`() {
        #expect(policy.isFreeTransfer(start: 0, minute: 45, transfers: 0))
    }

    @Test func `the window and the transfer count both end it`() {
        #expect(!policy.isFreeTransfer(start: 0, minute: 61, transfers: 0))
        #expect(!policy.isFreeTransfer(start: 0, minute: 10, transfers: 2))
    }

    @Test func `boarding before the journey started is not a transfer`() {
        #expect(!policy.isFreeTransfer(start: 30, minute: 20, transfers: 0))
    }

    @Test func `peak hours are weekday mornings and evenings`() {
        #expect(TransferPolicy.isPeak(minuteOfDay: 8 * 60, weekday: true))
        #expect(TransferPolicy.isPeak(minuteOfDay: 17 * 60, weekday: true))
        #expect(!TransferPolicy.isPeak(minuteOfDay: 12 * 60, weekday: true))
        #expect(!TransferPolicy.isPeak(minuteOfDay: 8 * 60, weekday: false))
    }
}
