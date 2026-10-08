import AgentWearLinkCore
import Foundation
import MWDATCamera
import MWDATCore

/// Separate, explicitly experimental DAT 1.0.0 standalone Photo surface.
/// Unlike the publishable-compatible Stream still capture, this path does
/// not start Camera.stream or require a first video frame.
final class MetaDATStandalonePhotoCapture: @unchecked Sendable {
    private enum Event: Sendable {
        case ready
        case image(Data)
    }

    private let generation = MetaDATListenerGeneration()
    private let lock = NSLock()
    private var tokens: [any AnyListenerToken] = []
    private var continuation: AsyncThrowingStream<Event, Error>.Continuation?

    /// Stop/suspend/registration loss synchronously retires all callbacks.
    func cancel() {
        generation.invalidate()
        let retired = lock.withLock { () -> (
            [any AnyListenerToken],
            AsyncThrowingStream<Event, Error>.Continuation?
        ) in
            let result = (tokens, continuation)
            tokens = []
            continuation = nil
            return result
        }
        retired.1?.finish(throwing: CancellationError())
        for token in retired.0 {
            Task { await token.cancel() }
        }
    }

    func capture(
        _ photo: Photo,
        timeout: Duration
    ) async throws -> Data {
        // A new attempt cannot inherit any observer or terminal byte from the
        // previous Photo generation. The parent snapshot controller enforces
        // single-flight admission and owns Camera teardown.
        cancel()
        let lease = generation.begin()

        // Register all three publishers BEFORE photo.start(). An immediate
        // .started or image callback is buffered rather than lost.
        let events = AsyncThrowingStream<Event, Error>(
            bufferingPolicy: .bufferingOldest(2)
        ) { continuation in
            self.lock.withLock {
                self.continuation = continuation
            }
            let stateToken = photo.statePublisher.listen { [weak self] state in
                guard let self, self.generation.isCurrent(lease) else { return }
                if state == .started {
                    _ = continuation.yield(.ready)
                }
                // Ignore the initial .stopped state before start(). Later
                // stalls remain bounded by the global photo timeout.
            }
            let dataToken = photo.photoDataPublisher.listen { [weak self] capture in
                guard let self, self.generation.isCurrent(lease) else { return }
                let outcome = continuation.yield(.image(capture.imageData))
                if case .dropped = outcome {
                    continuation.finish(throwing: AWLError.overloaded(
                        "Meta DAT standalone photo callback buffer exceeded"
                    ))
                } else {
                    continuation.finish()
                }
            }
            let errorToken = photo.errorPublisher.listen { [weak self] _ in
                guard let self, self.generation.isCurrent(lease) else { return }
                // Vendor errors may contain user/device context. Do not expose
                // SDK details or private photo bytes to Core/diagnostics.
                continuation.finish(throwing: AWLError.device(
                    "Meta DAT standalone photo capture failed"
                ))
            }
            let installed = self.lock.withLock { () -> Bool in
                guard self.generation.isCurrent(lease) else { return false }
                self.tokens = [stateToken, dataToken, errorToken]
                return true
            }
            if !installed {
                Task {
                    await stateToken.cancel()
                    await dataToken.cancel()
                    await errorToken.cancel()
                }
            }
            continuation.onTermination = { [weak self] _ in
                self?.cancel()
            }
        }

        photo.start()
        defer {
            cancel()
            photo.stop() // Stop Photo before parent Camera teardown.
        }

        do {
            return try await MetaDATPhotoRace.run(
                timeout: timeout,
                cancelTransfer: { [weak self] in
                    self?.cancel()
                    photo.stop()
                }
            ) {
                var shutterIssued = false
                for try await event in events {
                    switch event {
                    case .ready:
                        guard !shutterIssued else { continue }
                        try Task.checkCancellation()
                        shutterIssued = true
                        photo.capturePhoto(resolution: .medium, quality: .medium)
                    case let .image(bytes):
                        guard shutterIssued else {
                            throw AWLError.device(
                                "Meta DAT standalone photo arrived before shutter readiness"
                            )
                        }
                        return bytes
                    }
                }
                throw CancellationError()
            }
        } catch MetaDATPhotoRaceError.timeout {
            throw AWLError.device("Meta DAT standalone photo timed out")
        }
    }
}
