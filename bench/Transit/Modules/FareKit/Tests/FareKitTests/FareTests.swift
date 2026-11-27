import FareKit
import Testing

@Suite struct FareTests {
    let tariff = Tariff()

    @Test func `an adult pays per zone`() {
        #expect(tariff.fare(zones: 2, rider: .adult, age: 30, peak: false) == Fare(cents: 360))
    }

    @Test func `at least one zone is charged`() {
        #expect(tariff.fare(zones: 0, rider: .adult, age: 30, peak: false) == Fare(cents: 180))
    }

    @Test func `young children ride free, older children pay half`() {
        #expect(tariff.fare(zones: 3, rider: .child, age: 4, peak: true) == Fare(cents: 0))
        #expect(tariff.fare(zones: 2, rider: .child, age: 9, peak: false) == Fare(cents: 180))
    }

    @Test func `peak adds a surcharge except for seniors`() {
        #expect(tariff.fare(zones: 2, rider: .adult, age: 30, peak: true) == Fare(cents: 450))
        #expect(tariff.fare(zones: 2, rider: .senior, age: 70, peak: true) == Fare(cents: 215))
    }

    @Test(arguments: [(Rider.adult, 0), (.child, 50), (.senior, 40), (.student, 30)])
    func `each concession has its discount`(rider: Rider, percent: Int) {
        #expect(tariff.discountPercent(for: rider) == percent)
    }

    @Test func `rounding goes to the nearest five cents`() {
        #expect(tariff.roundedToFive(101) == 100)
        #expect(tariff.roundedToFive(103) == 105)
        #expect(tariff.roundedToFive(105) == 105)
    }

    @Test func `the daily cap bounds the total`() {
        #expect(tariff.dailyTotal([Fare(cents: 400), Fare(cents: 300)]) == Fare(cents: 700))
        #expect(tariff.dailyTotal([Fare(cents: 500), Fare(cents: 500)]) == Fare(cents: 900))
    }
}
