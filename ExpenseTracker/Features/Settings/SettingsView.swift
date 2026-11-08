import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(SyncStore.self) private var store

    @State private var error: String?
    @State private var info: String?
    @State private var removing: String?
    @State private var isChangingPassword = false
    @State private var isConfirmingLogout = false
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                if let user = store.user {
                    Section("Профиль") {
                        LabeledContent("Имя", value: user.name)
                        LabeledContent("Email", value: user.email)
                    }
                }

                Section {
                    Picker("Валюта отображения", selection: displayCurrency) {
                        ForEach(store.enabledCurrencies, id: \.self) { code in
                            Text("\(code) — \(Currencies.name(code))").tag(code)
                        }
                    }
                    .disabled(!app.isOnline || isBusy)
                } footer: {
                    Text("Суммы и сводка пересчитываются в эту валюту по курсу ЕЦБ.")
                }

                Section {
                    ForEach(store.enabledCurrencies, id: \.self) { code in
                        HStack {
                            Text(code).font(.body.monospaced())
                            Text(Currencies.name(code)).foregroundStyle(.secondary)
                            Spacer()
                            Text(Currencies.symbol(code)).foregroundStyle(.secondary)
                        }
                        .swipeActions {
                            if code != Currencies.default && app.isOnline {
                                Button("Убрать", role: .destructive) { removing = code }
                            }
                        }
                    }
                    Menu {
                        ForEach(Currencies.all.filter { !store.enabledCurrencies.contains($0.code) }, id: \.code) { currency in
                            Button("\(currency.code) — \(currency.name)") { Task { await add(currency.code) } }
                        }
                    } label: {
                        Label("Добавить валюту", systemImage: "plus.circle")
                    }
                    .disabled(!app.isOnline || isBusy)
                } header: {
                    Text("Мои валюты")
                } footer: {
                    Text("EUR убрать нельзя. Смахните валюту влево, чтобы убрать её.")
                }

                Section("Оформление") {
                    Picker("Тема", selection: theme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    }
                    .disabled(!app.isOnline || isBusy)
                }

                Section("Синхронизация") {
                    LabeledContent("Сеть", value: app.isOnline ? "Онлайн" : "Офлайн")
                    LabeledContent("Не отправлено", value: "\(store.pendingCount)")
                    if let last = store.lastSyncAt {
                        LabeledContent("Последняя", value: DayFormat.short(last))
                    }
                    if let error = store.lastSyncError {
                        Text(error).font(.footnote).foregroundStyle(.orange)
                    }
                    Button {
                        Task { await store.sync(month: .current) }
                    } label: {
                        HStack {
                            Text("Синхронизировать сейчас")
                            if store.isSyncing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(store.isSyncing || !app.isOnline)
                }

                Section {
                    Button("Сменить пароль") { isChangingPassword = true }.disabled(!app.isOnline)
                    Button("Выйти", role: .destructive) { isConfirmingLogout = true }
                } footer: {
                    Text("Сервер: \(app.api.baseURL.absoluteString)")
                }
            }
            .navigationTitle("Настройки")
            .offlineIndicator()
            .refreshable { await store.sync(month: nil) }
            .sheet(isPresented: $isChangingPassword) { ChangePasswordView() }
            .confirmationDialog("Убрать валюту?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible, presenting: removing) { code in
                Button("Убрать \(code)", role: .destructive) { Task { await remove(code) } }
            } message: { code in
                Text("Все операции в \(code) будут пересчитаны в EUR. Это нельзя отменить.")
            }
            .confirmationDialog("Выйти из аккаунта?", isPresented: $isConfirmingLogout, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { Task { await app.logout() } }
            } message: {
                let pending = store.pendingCount
                Text(pending > 0 ? "\(pending) опер. ещё не отправлены на сервер и будут потеряны." : "Данные на устройстве будут удалены.")
            }
            .errorAlert($error)
            .alert("Готово", isPresented: Binding(get: { info != nil }, set: { if !$0 { info = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(info ?? "") }
        }
    }

    private var displayCurrency: Binding<String> {
        Binding(get: { store.displayCurrency }, set: { value in
            Task { await run { try await store.updateSettings(UpdateSettingsBody(currency: value)) } }
        })
    }

    private var theme: Binding<AppTheme> {
        Binding(get: { store.settings?.theme ?? .system }, set: { value in
            Task { await run { try await store.updateSettings(UpdateSettingsBody(theme: value)) } }
        })
    }

    private func add(_ code: String) async {
        await run { try await store.addCurrency(code) }
    }

    private func remove(_ code: String) async {
        await run {
            let converted = try await store.removeCurrency(code)
            info = converted > 0 ? "Пересчитано в EUR: \(converted) опер." : "Валюта \(code) убрана."
            await store.sync(month: .current, includeReferenceData: false)
        }
    }

    private func run(_ action: () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do { try await action() } catch { self.error = APIError.from(error).localizedDescription }
    }
}

private struct ChangePasswordView: View {
    @Environment(SyncStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var current = ""
    @State private var new = ""
    @State private var repeated = ""
    @State private var isSaving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Текущий пароль", text: $current).textContentType(.password)
                }
                Section {
                    SecureField("Новый пароль", text: $new).textContentType(.newPassword)
                    SecureField("Повторите новый пароль", text: $repeated).textContentType(.newPassword)
                } footer: {
                    Text("От 8 до 72 символов. На других устройствах придётся войти заново.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Смена пароля")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving { ProgressView() } else {
                        Button("Сменить") { Task { await save() } }.disabled(!isValid)
                    }
                }
            }
        }
    }

    private var isValid: Bool {
        !current.isEmpty && (8...72).contains(new.count) && new == repeated && new != current
    }

    private func save() async {
        isSaving = true
        error = nil
        defer { isSaving = false }
        do {
            try await store.changePassword(current: current, new: new)
            dismiss()
        } catch let apiError as APIError where apiError.status == 400 {
            error = "Неверный текущий пароль"
        } catch {
            self.error = APIError.from(error).localizedDescription
        }
    }
}
