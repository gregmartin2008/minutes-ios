import Foundation

/// Whether the app is in the foreground, readable from any thread. Set from the app-state
/// notifications in `AppModel`; read by work that should not wait on things iOS withholds from a
/// background app, such as the language model.
final class AppState: @unchecked Sendable {
    static let shared = AppState()
    private let lock = NSLock()
    private var active = true

    var isActive: Bool {
        get { lock.lock(); defer { lock.unlock() }; return active }
        set { lock.lock(); active = newValue; lock.unlock() }
    }
}
