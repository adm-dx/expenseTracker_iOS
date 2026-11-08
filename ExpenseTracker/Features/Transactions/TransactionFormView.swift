import SwiftData
import SwiftUI

struct TransactionFormView: View {
    @Environment(SyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CachedCategory.position) private var categories: [CachedCategory]
    @Query(sort: \CachedTag.name) private var tags: [CachedTag]

    let item: CachedTransaction?

    @State private var amountText = ""
    @State private var currency = Currencies.default
    @State private var type: TransactionType = .expense
    @State private var categoryId: String?
    @State private var tagId: String?
    @State private var day = Date.now
    @State private var note = ""
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Form {
                if let item, item.syncState == .failed {
                    Section {
                        Label(item.syncError ?? "Сервер отклонил изменение", systemImage: "exclamationmark.icloud.fill")
                            .foregroundStyle(.red)
                        Button("Отправить ещё раз") {
                            store.retry(item)
                            dismiss()
                        }
                    } footer: {
                        Text("Исправьте операцию и сохраните её, или удалите.")
                    }
                }

                Section {
                    Picker("Тип", selection: $type) {
                        ForEach(TransactionType.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    HStack {
                        TextField("0,00", text: $amountText)
                            .keyboardType(.decimalPad)
                            .font(.title2.weight(.semibold))
                        Picker("", selection: $currency) {
                            ForEach(currencyOptions, id: \.self) { code in
                                Text("\(code) \(Currencies.symbol(code))").tag(code)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                } footer: {
                    if !amountText.isEmpty && amount == nil {
                        Text("Введите сумму больше нуля, не больше двух знаков после запятой").foregroundStyle(.red)
                    }
                }

                Section {
                    Picker("Категория", selection: $categoryId) {
                        if categoryId == nil { Text("Выберите").tag(String?.none) }
                        ForEach(categories) { category in
                            Label {
                                Text(category.name)
                            } icon: {
                                Image(systemName: CategoryIcon.symbol(for: category.icon))
                                    .foregroundStyle(Color(hex: category.color))
                            }
                            .tag(Optional(category.id))
                        }
                    }
                    .pickerStyle(.navigationLink)

                    Picker("Тег", selection: $tagId) {
                        Text("Без тега").tag(String?.none)
                        ForEach(tags) { Text($0.name).tag(Optional($0.id)) }
                    }

                    DatePicker("Дата", selection: $day, displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ru_RU"))
                }

                Section("Описание") {
                    TextField("Необязательно", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .onChange(of: note) { _, value in
                            if value.count > 255 { note = String(value.prefix(255)) }
                        }
                }

                if let item {
                    Section {
                        Button("Удалить операцию", role: .destructive) {
                            store.deleteTransaction(item)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(item == nil ? "Новая операция" : "Операция")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }.disabled(fields == nil)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var currencyOptions: [String] {
        var list = store.enabledCurrencies
        if !list.contains(currency) { list.append(currency) }
        return list
    }

    private var amount: Decimal? {
        guard let value = Money.parseInput(amountText), value > 0, value <= Decimal(string: "9999999999.99")! else { return nil }
        return value
    }

    private var fields: TransactionFields? {
        guard let amount, let categoryId else { return nil }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return TransactionFields(amount: amount, currency: currency, type: type, note: trimmed.isEmpty ? nil : trimmed,
                                 date: DayFormat.utcMidnight(ofLocalDay: day), categoryId: categoryId, tagId: tagId)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let item {
            amountText = item.amount.formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(Locale(identifier: "ru_RU")))
            currency = item.currency
            type = item.type
            categoryId = item.categoryId
            tagId = item.tagId
            day = DayFormat.localDay(ofUTCMidnight: item.date)
            note = item.note ?? ""
        } else {
            currency = store.displayCurrency
            categoryId = categories.first?.id
        }
    }

    private func save() {
        guard let fields else { return }
        store.saveTransaction(fields, editing: item)
        dismiss()
    }
}
