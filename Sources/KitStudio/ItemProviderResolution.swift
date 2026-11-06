import Foundation
import UniformTypeIdentifiers

/// NSItemProvider callbacks may arrive on any queue, more than once, or never.
/// This small bridge owns one continuation and one Progress, both protected by
/// the lock. Cancellation releases the waiting task without trusting the provider
/// to acknowledge Progress.cancel(); subsequent callbacks have no effect.
final class ItemProviderResolution: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var progress: Progress?

    @MainActor
    func resolve(_ provider: NSItemProvider, index: Int) async throws -> URL {
        try await resolve(index: index) { callback in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier, completionHandler: callback)
        }
    }

    @MainActor
    func resolve(index: Int, load: (@escaping @Sendable (Data?, Error?) -> Void) -> Progress) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard install(continuation) else { return }
                let progress = load { [self] data, error in
                    let prefix = String(localized: "Impossible de lire le fichier déposé \(index + 1).")
                    if let error {
                        finish(.failure(StudioError.message("\(prefix) \(error.localizedDescription)")))
                    } else if let data, let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
                        finish(.success(url))
                    } else {
                        finish(.failure(StudioError.message(prefix)))
                    }
                }
                install(progress)
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() { finish(.failure(CancellationError()), cancelProgress: true) }

    private func install(_ value: CheckedContinuation<URL, Error>) -> Bool {
        lock.lock()
        let completed = result
        if completed == nil { continuation = value }
        lock.unlock()
        if let completed { value.resume(with: completed); return false }
        return true
    }

    private func install(_ value: Progress) {
        lock.lock()
        let completed = result != nil
        let cancelled: Bool
        if case .failure(let error) = result { cancelled = error is CancellationError }
        else { cancelled = false }
        if !completed { progress = value }
        lock.unlock()
        // Cancellation can win before loadDataRepresentation returns its Progress.
        if cancelled { value.cancel() }
    }

    private func finish(_ value: Result<URL, Error>, cancelProgress: Bool = false) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let waiting = continuation
        let loading = progress
        continuation = nil
        progress = nil
        lock.unlock()
        if cancelProgress { loading?.cancel() }
        waiting?.resume(with: value)
    }
}
