import XCTest
@testable import CalcVault

final class UnitConversionTests: XCTestCase {
    typealias Unit = UnitConversion.Unit
    typealias Category = UnitConversion.Category

    func testEverySupportedCategoryHasUnitsAndStableMetadata() {
        for category in Category.allCases {
            let units = UnitConversion.units(for: category)
            XCTAssertFalse(units.isEmpty, "No units registered for \(category.rawValue)")
            XCTAssertEqual(units, Unit.allCases.filter { $0.category == category })
            XCTAssertTrue(units.allSatisfy { !$0.displayName.isEmpty && !$0.symbol.isEmpty })
        }
    }

    func testRepresentativeLengthFixtures() throws {
        let fixtures: [(Double, Unit, Unit, Double)] = [
            (1, .kilometer, .meter, 1_000),
            (12, .inch, .foot, 1),
            (1, .mile, .kilometer, 1.609_344),
            (2.54, .centimeter, .inch, 1)
        ]

        for (value, source, destination, expected) in fixtures {
            let actual = try UnitConversion.convert(value, from: source, to: destination)
            XCTAssertEqual(actual, expected, accuracy: 1e-12)
        }
    }

    func testRepresentativeMassAreaVolumeTimeAndSpeedFixtures() throws {
        let fixtures: [(Double, Unit, Unit, Double)] = [
            (1, .kilogram, .gram, 1_000),
            (1, .pound, .ounce, 16),
            (1, .squareMeter, .squareCentimeter, 10_000),
            (1, .squareFoot, .squareInch, 144),
            (1, .cubicMeter, .liter, 1_000),
            (1, .gallon, .liter, 3.785_411_784),
            (1, .hour, .second, 3_600),
            (1, .week, .day, 7),
            (100, .kilometersPerHour, .metersPerSecond, 27.777_777_777_777_78),
            (1, .knot, .metersPerSecond, 0.514_444_444_444_444_4)
        ]

        for (value, source, destination, expected) in fixtures {
            let actual = try UnitConversion.convert(value, from: source, to: destination)
            XCTAssertEqual(actual, expected, accuracy: max(abs(expected) * 1e-12, 1e-12))
        }
    }

    func testMultiplicativeCategoriesRoundTripAcrossAllUnits() throws {
        let values: [Category: Double] = [
            .length: 12.5,
            .mass: 2_345.75,
            .area: 18.25,
            .volume: 4.75,
            .time: 86_543.25,
            .speed: 31.125
        ]

        for category in [.length, .mass, .area, .volume, .time, .speed] as [Category] {
            guard let value = values[category] else {
                XCTFail("Missing fixture for \(category.rawValue)")
                continue
            }
            for source in UnitConversion.units(for: category) {
                for destination in UnitConversion.units(for: category) {
                    let converted = try UnitConversion.convert(value, from: source, to: destination)
                    let roundTrip = try UnitConversion.convert(converted, from: destination, to: source)
                    XCTAssertEqual(roundTrip, value, accuracy: max(abs(value) * 1e-12, 1e-12),
                                   "Failed \(source.rawValue) -> \(destination.rawValue)")
                }
            }
        }
    }

    func testTemperatureUsesAffineScaleConversion() throws {
        let fixtures: [(Double, Unit, Unit, Double)] = [
            (0, .celsius, .fahrenheit, 32),
            (100, .celsius, .fahrenheit, 212),
            (32, .fahrenheit, .celsius, 0),
            (0, .celsius, .kelvin, 273.15),
            (273.15, .kelvin, .celsius, 0),
            (0, .fahrenheit, .kelvin, 255.372_222_222_222_2)
        ]

        for (value, source, destination, expected) in fixtures {
            let actual = try UnitConversion.convert(value, from: source, to: destination)
            XCTAssertEqual(actual, expected, accuracy: 1e-10)
        }

        // A multiplicative implementation would incorrectly map 10 °C to 18 °F.
        XCTAssertEqual(try UnitConversion.convert(10, from: .celsius, to: .fahrenheit), 50, accuracy: 1e-12)
    }

    func testTemperatureRoundTripsAndAbsoluteZeroDomain() throws {
        for value in [-40.0, 0, 20, 100] {
            let fahrenheit = try UnitConversion.convert(value, from: .celsius, to: .fahrenheit)
            let celsius = try UnitConversion.convert(fahrenheit, from: .fahrenheit, to: .celsius)
            XCTAssertEqual(celsius, value, accuracy: 1e-10)
        }

        XCTAssertEqual(try UnitConversion.convert(0, from: .kelvin, to: .celsius), -273.15, accuracy: 1e-12)
        XCTAssertThrowsError(try UnitConversion.convert(-1, from: .kelvin, to: .celsius)) { error in
            XCTAssertEqual(error as? UnitConversion.Error, .invalidDomain(category: .temperature))
        }
        XCTAssertThrowsError(try UnitConversion.convert(-300, from: .celsius, to: .kelvin)) { error in
            XCTAssertEqual(error as? UnitConversion.Error, .invalidDomain(category: .temperature))
        }
    }

    func testCrossCategoryAndNonFiniteInputsAreRejected() {
        XCTAssertThrowsError(try UnitConversion.convert(1, from: .meter, to: .second)) { error in
            XCTAssertEqual(error as? UnitConversion.Error,
                           .incompatibleUnits(from: .length, to: .time))
        }
        XCTAssertThrowsError(try UnitConversion.convert(.nan, from: .meter, to: .foot)) { error in
            XCTAssertEqual(error as? UnitConversion.Error, .nonFiniteInput)
        }
        XCTAssertThrowsError(try UnitConversion.convert(.infinity, from: .meter, to: .foot)) { error in
            XCTAssertEqual(error as? UnitConversion.Error, .nonFiniteInput)
        }
    }

    func testPhysicalMultiplicativeDomainsRejectNegativeValues() {
        let fixtures: [(Unit, Unit)] = [
            (.meter, .foot),
            (.gram, .kilogram),
            (.squareMeter, .squareFoot),
            (.liter, .gallon),
            (.second, .minute),
            (.metersPerSecond, .milesPerHour)
        ]

        for (source, destination) in fixtures {
            XCTAssertThrowsError(try UnitConversion.convert(-1, from: source, to: destination)) { error in
                XCTAssertEqual(error as? UnitConversion.Error,
                               .invalidDomain(category: source.category))
            }
        }
    }

    func testOverflowIsRejectedInsteadOfReturningInfinity() {
        XCTAssertThrowsError(
            try UnitConversion.convert(Double.greatestFiniteMagnitude, from: .mile, to: .millimeter)
        ) { error in
            XCTAssertEqual(error as? UnitConversion.Error, .nonFiniteResult)
        }
    }

    func testConversionIsDeterministicAndOffline() throws {
        let first = try UnitConversion.convert(123.456, from: .mile, to: .kilometer)
        let second = try UnitConversion.convert(123.456, from: .mile, to: .kilometer)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first, 198.683_172_864, accuracy: 1e-12)
    }
}
