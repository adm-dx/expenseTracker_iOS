import Foundation
import Testing
import UIKit
@testable import ExpenseTracker

struct CodingTests {
    @Test func decodesTransactionWithMillisecondDates() throws {
        let json = Fixture.transaction(id: "t1", tagIds: ["tag-1"], converted: "1464.80")
        let dto = try JSONCoding.decoder().decode(TransactionDTO.self, from: Data(json.utf8))
        #expect(dto.id == "t1")
        #expect(Money.parse(dto.amount) == Decimal(string: "12.5"))
        #expect(dto.type == .expense)
        #expect(dto.tagIds == ["tag-1"])
        #expect(dto.convertedAmount == "1464.80")
        #expect(APIDate.format(dto.date) == "2026-11-08T00:00:00.000Z")
        #expect(APIDate.format(dto.createdAt) == "2026-11-08T10:15:30.123Z")
    }

    @Test func decodesSummaryAndSettings() throws {
        let summary = """
        {"dateFrom":"2026-11-01T00:00:00.000Z","dateTo":"2026-11-30T23:59:59.999Z","totalIncome":"1000.00",
         "totalExpense":"250.40","balance":"749.60","byCategory":[{"categoryId":"c","name":"Еда","color":"#F97316",
         "icon":"utensils","type":"EXPENSE","total":"250.40","count":3}],"currency":"EUR","ratesDate":"2026-11-07"}
        """
        let decoded = try JSONCoding.decoder().decode(TransactionSummary.self, from: Data(summary.utf8))
        #expect(decoded.byCategory.first?.count == 3)
        #expect(Money.parse(decoded.balance) == Decimal(string: "749.6"))

        let settings = """
        {"theme":"dark","colorScheme":"slate","currency":"RSD","currencies":["EUR","RSD"],
         "location":{"mode":"manual","name":"Belgrade, RS","lat":44.82,"lon":20.46}}
        """
        let decodedSettings = try JSONCoding.decoder().decode(UserSettings.self, from: Data(settings.utf8))
        #expect(decodedSettings.theme == .dark)
        #expect(decodedSettings.currencies == ["EUR", "RSD"])
    }

    @Test func parsesUserInputAmounts() {
        #expect(Money.parseInput("12,5") == Decimal(string: "12.5"))
        #expect(Money.parseInput("1 200.99") == Decimal(string: "1200.99"))
        #expect(Money.parseInput("1.234") == nil)
        #expect(Money.parseInput("abc") == nil)
        #expect(Money.parseInput("") == nil)
    }

    @Test func createBodyLeavesOutEmptyFieldsAndSendsNumber() throws {
        let fields = TransactionFields(amount: Decimal(string: "12.5")!, currency: "EUR", type: .expense, note: nil,
                                       date: APIDate.parse("2026-11-08T00:00:00.000Z")!, categoryId: "c", tagId: nil)
        let data = try JSONCoding.encoder().encode(CreateTransactionBody(fields: fields))
        let object = Fixture.json(data)
        #expect(object["description"] == nil)
        #expect((object["amount"] as? NSNumber)?.doubleValue == 12.5)
        #expect(object["date"] as? String == "2026-11-08T00:00:00.000Z")
        #expect(object["tagIds"] as? [String] == [])
        #expect(Set(object.keys) == ["amount", "currency", "type", "date", "categoryId", "tagIds"])
    }

    @Test func updateBodyClearsDescriptionWithNull() throws {
        let fields = TransactionFields(amount: 5, currency: "USD", type: .income, note: nil, date: .now, categoryId: "c", tagId: "t")
        let text = String(decoding: try JSONCoding.encoder().encode(UpdateTransactionBody(fields: fields)), as: UTF8.self)
        #expect(text.contains("\"description\":null"))
        #expect(text.contains("\"tagIds\":[\"t\"]"))
    }

    @Test func parsesNestErrorBodies() {
        let many = APIError.from(status: 400, data: Data(#"{"statusCode":400,"message":["a","b"],"error":"Bad Request"}"#.utf8))
        #expect(many == .server(status: 400, message: "a\nb"))
        let one = APIError.from(status: 409, data: Data(#"{"statusCode":409,"message":"Exists"}"#.utf8))
        #expect(one == .server(status: 409, message: "Exists"))
    }

    @Test func monthBoundsAreUTC() {
        let month = MonthPeriod(year: 2026, month: 2)
        #expect(APIDate.format(month.start) == "2026-02-01T00:00:00.000Z")
        #expect(month.endISO == "2026-02-28T23:59:59.999Z")
        #expect(APIDate.format(month.nextStart) == "2026-03-01T00:00:00.000Z")
        #expect(month.adding(months: -2) == MonthPeriod(year: 2025, month: 12))
    }

    @Test func everyCategoryIconHasASymbol() {
        #expect(CategoryIcon.all.count == 41)
        for icon in CategoryIcon.all {
            #expect(UIImage(systemName: icon.symbol) != nil, "No SF Symbol \(icon.symbol) for \(icon.lucide)")
        }
    }
}
