import SwiftUI

/// The API's category icons are lucide names; each one is drawn with the closest SF Symbol.
enum CategoryIcon {
    /// In the API's order (`CATEGORY_ICONS` in packages/types), which groups them by meaning.
    static let all: [(lucide: String, symbol: String)] = [
        ("utensils", "fork.knife"), ("coffee", "cup.and.saucer.fill"),
        ("pizza", "takeoutbag.and.cup.and.straw.fill"), ("shopping-cart", "cart.fill"), ("apple", "carrot.fill"),
        ("car", "car.fill"), ("bus", "bus.fill"), ("train-front", "tram.fill"), ("fuel", "fuelpump.fill"),
        ("plane", "airplane"),
        ("house", "house.fill"), ("lightbulb", "lightbulb.fill"), ("wifi", "wifi"), ("smartphone", "iphone"),
        ("receipt", "doc.plaintext.fill"),
        ("heart-pulse", "waveform.path.ecg"), ("pill", "pills.fill"), ("stethoscope", "stethoscope"),
        ("clapperboard", "movieclapper.fill"), ("gamepad-2", "gamecontroller.fill"), ("music", "music.note"),
        ("tv", "tv.fill"),
        ("shopping-bag", "bag.fill"), ("shirt", "tshirt.fill"), ("gift", "gift.fill"), ("scissors", "scissors"),
        ("banknote", "banknote.fill"), ("wallet", "wallet.bifold.fill"), ("piggy-bank", "dollarsign.bank.building.fill"),
        ("credit-card", "creditcard.fill"), ("trending-up", "chart.line.uptrend.xyaxis"),
        ("hand-coins", "dollarsign.circle.fill"), ("landmark", "building.columns.fill"), ("briefcase", "briefcase.fill"),
        ("graduation-cap", "graduationcap.fill"), ("book-open", "book.fill"),
        ("baby", "figure.and.child.holdinghands"), ("paw-print", "pawprint.fill"), ("dumbbell", "dumbbell.fill"),
        ("wrench", "wrench.and.screwdriver.fill"), ("circle-ellipsis", "ellipsis.circle.fill"),
    ]

    static let fallback = "questionmark.circle.fill"

    static func symbol(for lucide: String) -> String {
        all.first { $0.lucide == lucide }?.symbol ?? fallback
    }
}

struct CategoryBadge: View {
    let icon: String
    let color: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: CategoryIcon.symbol(for: icon))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Color(hex: color), in: Circle())
    }
}

/// Small marker in a navigation bar while there is no connection.
struct OfflineIndicator: ViewModifier {
    @Environment(AppState.self) private var app

    func body(content: Content) -> some View {
        content.toolbar {
            if !app.isOnline {
                ToolbarItem(placement: .topBarLeading) {
                    Label("Офлайн", systemImage: "wifi.slash")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
            }
        }
    }
}

extension View {
    func offlineIndicator() -> some View { modifier(OfflineIndicator()) }
}

/// Error alert bound to an optional message.
extension View {
    func errorAlert(_ message: Binding<String?>) -> some View {
        alert("Ошибка", isPresented: Binding(get: { message.wrappedValue != nil }, set: { if !$0 { message.wrappedValue = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message.wrappedValue ?? "")
        }
    }
}
