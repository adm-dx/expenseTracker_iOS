import Foundation
import Network
import Observation

@Observable
final class NetworkMonitor {
    private(set) var isOnline = true
    /// Called each time the connection comes back.
    @ObservationIgnored var onReconnect: (() -> Void)?
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.update(online) }
        }
        monitor.start(queue: DispatchQueue(label: "network-monitor"))
    }

    private func update(_ online: Bool) {
        let cameBack = online && !isOnline
        isOnline = online
        if cameBack { onReconnect?() }
    }
}
