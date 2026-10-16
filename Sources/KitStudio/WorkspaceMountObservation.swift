import Foundation

/// NotificationCenter supports registration/removal from any thread. The opaque
/// tokens are immutable, never exposed, and only handed back to their center at
/// teardown; they do not transfer any AppKit or model state across actors.
final class WorkspaceMountObservation: @unchecked Sendable {
    private let center: NotificationCenter
    private let tokens: [NSObjectProtocol]

    init(center: NotificationCenter, names: [Notification.Name],
         handler: @escaping @Sendable (Notification) -> Void) {
        self.center = center
        tokens = names.map { center.addObserver(forName: $0, object: nil, queue: .main, using: handler) }
    }

    deinit { for token in tokens { center.removeObserver(token) } }
}
