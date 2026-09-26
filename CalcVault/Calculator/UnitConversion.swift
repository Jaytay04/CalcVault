import Foundation

/// Deterministic, offline unit conversion for the calculator.
///
/// Multiplicative dimensions are normalized through a single base unit. Temperature
/// is intentionally handled separately because its scales have an additive offset.
/// The converter does not fetch rates or use locale-sensitive parsing.
public enum UnitConversion {
    public enum Category: String, CaseIterable, Codable, Hashable, Sendable {
        case length
        case mass
        case temperature
        case area
        case volume
        case time
        case speed
    }

    public enum Unit: String, CaseIterable, Codable, Hashable, Sendable {
        // Length (base unit: metre)
        case meter
        case kilometer
        case centimeter
        case millimeter
        case inch
        case foot
        case yard
        case mile

        // Mass (base unit: gram)
        case gram
        case kilogram
        case milligram
        case ounce
        case pound

        // Temperature (base unit: kelvin)
        case celsius
        case fahrenheit
        case kelvin

        // Area (base unit: square metre)
        case squareMeter
        case squareKilometer
        case squareCentimeter
        case squareInch
        case squareFoot
        case squareYard
        case squareMile

        // Volume (base unit: litre)
        case liter
        case milliliter
        case cubicMeter
        case cubicCentimeter
        case gallon
        case quart
        case pint
        case cup

        // Time (base unit: second)
        case second
        case millisecond
        case minute
        case hour
        case day
        case week

        // Speed (base unit: metre per second)
        case metersPerSecond
        case kilometersPerHour
        case milesPerHour
        case feetPerSecond
        case knot

        public var category: Category {
            switch self {
            case .meter, .kilometer, .centimeter, .millimeter, .inch, .foot, .yard, .mile:
                return .length
            case .gram, .kilogram, .milligram, .ounce, .pound:
                return .mass
            case .celsius, .fahrenheit, .kelvin:
                return .temperature
            case .squareMeter, .squareKilometer, .squareCentimeter, .squareInch, .squareFoot,
                 .squareYard, .squareMile:
                return .area
            case .liter, .milliliter, .cubicMeter, .cubicCentimeter, .gallon, .quart, .pint, .cup:
                return .volume
            case .second, .millisecond, .minute, .hour, .day, .week:
                return .time
            case .metersPerSecond, .kilometersPerHour, .milesPerHour, .feetPerSecond, .knot:
                return .speed
            }
        }

        public var displayName: String {
            switch self {
            case .meter: return "Meter"
            case .kilometer: return "Kilometer"
            case .centimeter: return "Centimeter"
            case .millimeter: return "Millimeter"
            case .inch: return "Inch"
            case .foot: return "Foot"
            case .yard: return "Yard"
            case .mile: return "Mile"
            case .gram: return "Gram"
            case .kilogram: return "Kilogram"
            case .milligram: return "Milligram"
            case .ounce: return "Ounce"
            case .pound: return "Pound"
            case .celsius: return "Celsius"
            case .fahrenheit: return "Fahrenheit"
            case .kelvin: return "Kelvin"
            case .squareMeter: return "Square Meter"
            case .squareKilometer: return "Square Kilometer"
            case .squareCentimeter: return "Square Centimeter"
            case .squareInch: return "Square Inch"
            case .squareFoot: return "Square Foot"
            case .squareYard: return "Square Yard"
            case .squareMile: return "Square Mile"
            case .liter: return "Liter"
            case .milliliter: return "Milliliter"
            case .cubicMeter: return "Cubic Meter"
            case .cubicCentimeter: return "Cubic Centimeter"
            case .gallon: return "US Gallon"
            case .quart: return "US Quart"
            case .pint: return "US Pint"
            case .cup: return "US Cup"
            case .second: return "Second"
            case .millisecond: return "Millisecond"
            case .minute: return "Minute"
            case .hour: return "Hour"
            case .day: return "Day"
            case .week: return "Week"
            case .metersPerSecond: return "Meters per Second"
            case .kilometersPerHour: return "Kilometers per Hour"
            case .milesPerHour: return "Miles per Hour"
            case .feetPerSecond: return "Feet per Second"
            case .knot: return "Knot"
            }
        }

        public var symbol: String {
            switch self {
            case .meter: return "m"
            case .kilometer: return "km"
            case .centimeter: return "cm"
            case .millimeter: return "mm"
            case .inch: return "in"
            case .foot: return "ft"
            case .yard: return "yd"
            case .mile: return "mi"
            case .gram: return "g"
            case .kilogram: return "kg"
            case .milligram: return "mg"
            case .ounce: return "oz"
            case .pound: return "lb"
            case .celsius: return "°C"
            case .fahrenheit: return "°F"
            case .kelvin: return "K"
            case .squareMeter: return "m²"
            case .squareKilometer: return "km²"
            case .squareCentimeter: return "cm²"
            case .squareInch: return "in²"
            case .squareFoot: return "ft²"
            case .squareYard: return "yd²"
            case .squareMile: return "mi²"
            case .liter: return "L"
            case .milliliter: return "mL"
            case .cubicMeter: return "m³"
            case .cubicCentimeter: return "cm³"
            case .gallon: return "gal"
            case .quart: return "qt"
            case .pint: return "pt"
            case .cup: return "cup"
            case .second: return "s"
            case .millisecond: return "ms"
            case .minute: return "min"
            case .hour: return "h"
            case .day: return "d"
            case .week: return "wk"
            case .metersPerSecond: return "m/s"
            case .kilometersPerHour: return "km/h"
            case .milesPerHour: return "mph"
            case .feetPerSecond: return "ft/s"
            case .knot: return "kn"
            }
        }

        fileprivate var multiplicativeFactor: Double? {
            switch self {
            case .meter: return 1
            case .kilometer: return 1_000
            case .centimeter: return 0.01
            case .millimeter: return 0.001
            case .inch: return 0.0254
            case .foot: return 0.3048
            case .yard: return 0.9144
            case .mile: return 1_609.344
            case .gram: return 1
            case .kilogram: return 1_000
            case .milligram: return 0.001
            case .ounce: return 28.349_523_125
            case .pound: return 453.592_37
            case .squareMeter: return 1
            case .squareKilometer: return 1_000_000
            case .squareCentimeter: return 0.0001
            case .squareInch: return 0.000_645_16
            case .squareFoot: return 0.092_903_04
            case .squareYard: return 0.836_127_36
            case .squareMile: return 2_589_988.110_336
            case .liter: return 1
            case .milliliter: return 0.001
            case .cubicMeter: return 1_000
            case .cubicCentimeter: return 0.001
            case .gallon: return 3.785_411_784
            case .quart: return 0.946_352_946
            case .pint: return 0.473_176_473
            case .cup: return 0.236_588_236_5
            case .second: return 1
            case .millisecond: return 0.001
            case .minute: return 60
            case .hour: return 3_600
            case .day: return 86_400
            case .week: return 604_800
            case .metersPerSecond: return 1
            case .kilometersPerHour: return 1 / 3.6
            case .milesPerHour: return 0.447_04
            case .feetPerSecond: return 0.3048
            case .knot: return 0.514_444_444_444_444_4
            case .celsius, .fahrenheit, .kelvin:
                return nil
            }
        }

        fileprivate var temperatureScale: TemperatureScale? {
            switch self {
            case .celsius: return .celsius
            case .fahrenheit: return .fahrenheit
            case .kelvin: return .kelvin
            default: return nil
            }
        }
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case nonFiniteInput
        case nonFiniteResult
        case incompatibleUnits(from: Category, to: Category)
        case invalidDomain(category: Category)
    }

    fileprivate enum TemperatureScale: Sendable {
        case celsius
        case fahrenheit
        case kelvin
    }

    /// Converts a finite value between units in the same category.
    ///
    /// Length, mass, area, volume, time, and speed are non-negative physical
    /// quantities. Celsius and Fahrenheit may be negative; Kelvin must be at
    /// or above absolute zero. An overflow during conversion is rejected.
    public static func convert(_ value: Double, from: Unit, to: Unit) throws -> Double {
        guard value.isFinite else {
            throw Error.nonFiniteInput
        }
        guard from.category == to.category else {
            throw Error.incompatibleUnits(from: from.category, to: to.category)
        }

        if from.category == .temperature {
            return try convertTemperature(value, from: from, to: to)
        }

        guard value >= 0 else {
            throw Error.invalidDomain(category: from.category)
        }
        guard let sourceFactor = from.multiplicativeFactor,
              let destinationFactor = to.multiplicativeFactor else {
            preconditionFailure("Non-temperature units must have multiplicative factors")
        }

        let baseValue = value * sourceFactor
        guard baseValue.isFinite else {
            throw Error.nonFiniteResult
        }
        let convertedValue = baseValue / destinationFactor
        guard convertedValue.isFinite else {
            throw Error.nonFiniteResult
        }
        return convertedValue
    }

    /// Returns the stable display order for the units in a category.
    public static func units(for category: Category) -> [Unit] {
        Unit.allCases.filter { $0.category == category }
    }

    private static func convertTemperature(_ value: Double, from: Unit, to: Unit) throws -> Double {
        guard let sourceScale = from.temperatureScale,
              let destinationScale = to.temperatureScale else {
            preconditionFailure("Temperature units must have temperature scales")
        }

        let kelvin: Double
        switch sourceScale {
        case .celsius:
            kelvin = value + 273.15
        case .fahrenheit:
            kelvin = (value - 32) * (5 / 9) + 273.15
        case .kelvin:
            kelvin = value
        }

        guard kelvin.isFinite else {
            throw Error.nonFiniteResult
        }
        guard kelvin >= 0 else {
            throw Error.invalidDomain(category: .temperature)
        }

        let convertedValue: Double
        switch destinationScale {
        case .celsius:
            convertedValue = kelvin - 273.15
        case .fahrenheit:
            convertedValue = (kelvin - 273.15) * (9 / 5) + 32
        case .kelvin:
            convertedValue = kelvin
        }

        guard convertedValue.isFinite else {
            throw Error.nonFiniteResult
        }
        return convertedValue
    }
}

// These aliases keep call sites readable when a consumer does not need the
// namespace, while the nested API remains the canonical public surface.
public typealias UnitConversionCategory = UnitConversion.Category
public typealias UnitConversionUnit = UnitConversion.Unit
public typealias UnitConversionError = UnitConversion.Error
