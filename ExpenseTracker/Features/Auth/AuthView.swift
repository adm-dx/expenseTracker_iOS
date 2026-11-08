import SwiftUI

struct AuthView: View {
    enum Mode: String, CaseIterable { case login = "Вход", register = "Регистрация" }

    @Environment(AppState.self) private var app
    @State private var mode: Mode = .login
    @State private var name = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "wallet.bifold.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)
                        Text("Учёт расходов").font(.title2.bold())
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                }

                if app.sessionExpiredNotice {
                    Section {
                        Label("Сессия истекла, войдите снова", systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(.orange)
                    }
                }

                Picker("Режим", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                Section {
                    if mode == .register {
                        TextField("Имя", text: $name)
                            .textContentType(.name)
                    }
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Пароль", text: $password)
                        .textContentType(mode == .login ? .password : .newPassword)
                } footer: {
                    if mode == .register { Text("Пароль — от 8 до 72 символов.") }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }

                Section {
                    Button {
                        Task { await submit() }
                    } label: {
                        HStack {
                            Spacer()
                            if isLoading { ProgressView() } else { Text(mode == .login ? "Войти" : "Создать аккаунт").bold() }
                            Spacer()
                        }
                    }
                    .disabled(!isValid || isLoading)
                }
            }
            .onChange(of: mode) { error = nil }
        }
    }

    private var isValid: Bool {
        let emailOK = email.contains("@") && email.contains(".")
        switch mode {
        case .login: return emailOK && !password.isEmpty
        case .register:
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            return emailOK && !trimmed.isEmpty && trimmed.count <= 100 && (8...72).contains(password.count)
        }
    }

    private func submit() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            switch mode {
            case .login: try await app.login(email: email, password: password)
            case .register: try await app.register(name: name, email: email, password: password)
            }
        } catch let apiError as APIError {
            error = switch apiError {
            case .server(401, _): "Неверный email или пароль"
            case .server(409, _): "Пользователь с таким email уже есть"
            default: apiError.localizedDescription
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
