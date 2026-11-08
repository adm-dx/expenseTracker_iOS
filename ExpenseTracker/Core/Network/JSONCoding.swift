import Foundation

/// The API sends dates as `Date.toISOString()` (with milliseconds) and expects strict ISO 8601 back.
nonisolated enum APIDate {
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func parse(_ string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? plain.parse(string))
    }

    static func format(_ date: Date) -> String {
        withFraction.format(date)
    }
}

nonisolated enum JSONCoding {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = APIDate.parse(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
            }
            return date
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(APIDate.format(date))
        }
        return encoder
    }
}

/// Money arrives as strings with two fraction digits ("12.50") and is sent as JSON numbers.
nonisolated enum Money {
    private static let posix = Locale(identifier: "en_US_POSIX")

    static func parse(_ string: String) -> Decimal {
        Decimal(string: string, locale: posix) ?? 0
    }

    /// Parses what the user typed: accepts "12,5" and "12.5", ignores spaces.
    static func parseInput(_ string: String) -> Decimal? {
        let cleaned = string
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .replacingOccurrences(of: ",", with: ".")
        guard !cleaned.isEmpty, cleaned.range(of: #"^\d+(\.\d{0,2})?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return Decimal(string: cleaned, locale: posix)
    }

    static func string(_ value: Decimal) -> String {
        var value = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 2, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    static func rounded(_ value: Decimal) -> Decimal {
        parse(string(value))
    }
}
