import SwiftData
import SwiftUI

@main
struct ExpenseTrackerApp: App {
    private let container: ModelContainer
    @State private var app: AppState

    init() {
        // UI tests start signed out with an empty cache.
        let isUITest = CommandLine.arguments.contains("-uitest-reset")
        if isUITest { KeychainTokenStore().clear() }
        let container = CacheSchema.makeContainer(inMemory: isUITest)
        self.container = container
        _app = State(initialValue: AppState(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(app)
                .environment(app.store)
                .modelContainer(container)
        }
    }
}

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(SyncStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch app.phase {
            case .signedOut: AuthView()
            case .signedIn: MainTabView()
            }
        }
        .preferredColorScheme(colorScheme)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && app.phase == .signedIn {
                Task { await store.sync(month: nil) }
            }
        }
    }

    private var colorScheme: ColorScheme? {
        switch store.settings?.theme {
        case .light: .light
        case .dark: .dark
        default: nil
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            Tab("Операции", systemImage: "list.bullet.rectangle") { TransactionsView() }
            Tab("Сводка", systemImage: "chart.pie") { SummaryView() }
            Tab("Справочники", systemImage: "square.grid.2x2") { CatalogView() }
            Tab("Настройки", systemImage: "gearshape") { SettingsView() }
        }
    }
}
