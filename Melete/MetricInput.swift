import Foundation

enum MetricInput {
    static func parse(_ text: String, allowsDecimal: Bool) -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = allowsDecimal ? #"^[0-9]+(?:\.[0-9]{1,3})?$"# : #"^[0-9]+$"#
        guard !normalized.isEmpty,
              normalized.range(of: pattern, options: .regularExpression) != nil,
              let decimal = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), decimal >= 0 else { return nil }
        var scaled = decimal * Decimal(1000)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        guard rounded == scaled, let number = Int64(NSDecimalNumber(decimal: rounded).stringValue),
              allowsDecimal || number % 1000 == 0 else { return nil }
        return number
    }
}
