import SwiftUI

/// The currencies the API supports, with the symbols the web app shows.
enum Currencies {
    static let all: [(code: String, symbol: String, name: String)] = [
        ("RSD", "дин.", "Сербский динар"), ("EUR", "€", "Евро"), ("HUF", "Ft", "Венгерский форинт"),
        ("USD", "$", "Доллар США"), ("GBP", "£", "Фунт стерлингов"), ("CHF", "Fr.", "Швейцарский франк"),
        ("JPY", "¥", "Японская иена"), ("CNY", "¥", "Китайский юань"), ("CAD", "C$", "Канадский доллар"),
        ("AUD", "A$", "Австралийский доллар"), ("PLN", "zł", "Польский злотый"), ("CZK", "Kč", "Чешская крона"),
        ("RON", "lei", "Румынский лей"), ("BGN", "лв", "Болгарский лев"), ("BAM", "KM", "Конвертируемая марка"),
        ("MKD", "ден", "Македонский денар"), ("TRY", "₺", "Турецкая лира"), ("UAH", "₴", "Украинская гривна"),
        ("RUB", "₽", "Российский рубль"), ("SEK", "kr", "Шведская крона"), ("NOK", "kr", "Норвежская крона"),
        ("DKK", "kr", "Датская крона"),
    ]

    static let `default` = "EUR"

    static func symbol(_ code: String) -> String {
        all.first { $0.code == code }?.symbol ?? code
    }

    static func name(_ code: String) -> String {
        all.first { $0.code == code }?.name ?? code
    }
}

enum MoneyFormat {
    private static let style = Decimal.FormatStyle.number
        .precision(.fractionLength(2))
        .locale(Locale(identifier: "ru_RU"))

    static func string(_ amount: Decimal, _ currency: String) -> String {
        "\(amount.formatted(style)) \(Currencies.symbol(currency))"
    }

    static func signed(_ amount: Decimal, _ currency: String, type: TransactionType) -> String {
        (type == .income ? "+" : "−") + string(amount, currency)
    }
}

enum DayFormat {
    /// Transaction dates are UTC midnights, so they are shown in UTC to keep the day the user picked.
    static func title(_ date: Date) -> String {
        var style = Date.FormatStyle().day().month(.wide).weekday(.wide)
        style.timeZone = TimeZone(identifier: "UTC")!
        style.locale = Locale(identifier: "ru_RU")
        let text = date.formatted(style)
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    static func short(_ date: Date) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = Locale(identifier: "ru_RU")
        return date.formatted(style)
    }

    /// The local calendar day the user picked, as that day's UTC midnight (what the web app sends).
    static func utcMidnight(ofLocalDay date: Date) -> Date {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return MonthPeriod.utc.date(from: parts) ?? date
    }

    /// The reverse: a UTC midnight shown as the same day in the local DatePicker.
    static func localDay(ofUTCMidnight date: Date) -> Date {
        let parts = MonthPeriod.utc.dateComponents([.year, .month, .day], from: date)
        return Calendar.current.date(from: parts) ?? date
    }
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x888888
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let resolved = UIColor(self).resolvedColor(with: .current)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        resolved.getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }
}

extension TransactionType {
    var tint: Color { self == .income ? .green : .primary }
}
