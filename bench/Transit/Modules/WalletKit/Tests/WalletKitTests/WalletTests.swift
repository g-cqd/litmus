import Testing
import WalletKit

@Suite struct WalletTests {
    @Test func `a top-up adds to the balance`() throws {
        var wallet = Wallet()
        try wallet.topUp(500)
        #expect(wallet.balance == 500)
        #expect(throws: WalletError.invalidAmount) { try wallet.topUp(0) }
    }

    @Test func `the balance has a ceiling`() throws {
        #expect(WalletLimits.maximumBalance == 20_000)
        var wallet = Wallet(balance: 19_900)
        #expect(throws: WalletError.overLimit) { try wallet.topUp(200) }
        try wallet.topUp(100)
        #expect(wallet.balance == 20_000)
    }

    @Test func `business accounts start at level three`() {
        #expect(!WalletLimits.isBusinessAccount(level: 2))
        #expect(WalletLimits.isBusinessAccount(level: 3))
    }

    @Test func `paying needs funds`() throws {
        var wallet = Wallet(balance: 300)
        try wallet.pay(300)
        #expect(wallet.balance == 0)
        #expect(throws: WalletError.insufficientFunds) { try wallet.pay(1) }
    }

    @Test func `the audit trail records payments and declines`() throws {
        var wallet = Wallet(balance: 100)
        try wallet.pay(37)
        #expect(AuditTrail.shared.contains("pay 37"))
        #expect(throws: WalletError.insufficientFunds) { try wallet.pay(99) }
        #expect(AuditTrail.shared.contains("declined 99"))
    }

    @Test func `reloading tops up to the target below the threshold`() {
        #expect(Wallet(balance: 300).reloadAmount(threshold: 500, target: 2_000) == 1_700)
        #expect(Wallet(balance: 500).reloadAmount(threshold: 500, target: 2_000) == 0)
    }

    @Test func `points double past one hundred euros`() {
        #expect(Wallet.points(monthlySpend: 5_050) == 50)
        #expect(Wallet.points(monthlySpend: 15_000) == 300)
    }

    @Test func `percentages are clamped`() {
        #expect(Wallet.clampedPercent(150) == 100)
        #expect(Wallet.clampedPercent(-4) == 0)
        #expect(Wallet.clampedPercent(42) == 42)
    }

    @Test func `station names are capitalised`() {
        #expect(StationDirectory.shared.displayNames["port"] == "Harbour")
    }
}
