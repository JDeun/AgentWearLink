import AgentWearLinkCore
import Foundation
import MWDATCamera
import MWDATCore

/// Production one-shot camera owner used by MetaDATDeviceAdapter.
///
/// The controller is deliberately not an actor: the owning device adapter
/// already serializes admission, while this type needs synchronous invalidation
/// from teardown paths even when a capture is suspended at an await. A small
/// lock protects capture generation/camera ownership across actor reentrancy.
public final class MetaDATCameraSnapshotController: @unchecked Sendable {
    private let lock = NSLock()
    private let timeout: Duration
    private let maximumBytes: Int

    private var generation: UInt64 = 0
    private var activeCapture: UInt64?
    private var camera: Camera?

    private let firstFrameReadiness = MetaDATFirstFrameReadiness()
    private let photoResultListener = MetaDATPhotoResultListener()
    private let waitGate = MetaDATCaptureWaitGate()

    public init(
        timeout: Duration = .seconds(5),
        maximumBytes: Int = ImageAttachment.defaultMaximumBytes
    ) {
        precondition(timeout > .zero)
        precondition(maximumBytes > 0)
        precondition(maximumBytes <= ImageAttachment.defaultMaximumBytes)
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    public func capture(from session: DeviceSession) async throws -> ImageAttachment {
        let token: UInt64
        let existingCamera: Camera?

        (token, existingCamera) = try lock.withLock {
            guard activeCapture == nil else {
                throw AWLError.device("Meta DAT snapshot capture is already in progress")
            }
            generation &+= 1
            let token = generation
            activeCapture = token
            return (token, self.camera)
        }

        defer { finishCapture(token) }

        let camera: Camera
        if let existingCamera {
            camera = existingCamera
        } else {
            guard let attached = try MetaDATCameraConfiguration.attach(to: session) else {
                throw AWLError.capabilityUnavailable(
                    "Meta DAT camera is unavailable for the selected device"
                )
            }

            let accepted = lock.withLock {
                guard generation == token, activeCapture == token else {
                    return false
                }
                self.camera = attached
                return true
            }
            guard accepted else {
                attached.stop()
                throw CancellationError()
            }
            camera = attached
        }

        try ensureCurrent(token)

        let stream = camera.stream
        firstFrameReadiness.reset()
        photoResultListener.cancel()
        stream.start()

        do {
            try await waitForFirstFrame(stream, token: token)
            try ensureCurrent(token)

            let bytes = try await capturePhoto(stream, token: token)
            try ensureCurrent(token)

            try MetaDATPhotoNormalizer.validatePayload(
                bytes,
                maximumBytes: maximumBytes
            )

            stream.stop()
            firstFrameReadiness.reset()
            photoResultListener.cancel()

            return try ImageAttachment(
                data: bytes,
                format: .jpeg,
                maximumBytes: maximumBytes
            )
        } catch {
            stream.stop()
            firstFrameReadiness.reset()
            photoResultListener.cancel()
            throw error
        }
    }

    /// Synchronously invalidates the current media generation.
    ///
    /// This is safe to call from DeviceSession teardown while capture() is
    /// suspended. The pending wait is finished immediately and late callbacks
    /// are rejected by both the wait gate and generation checks.
    public func invalidate() {
        let retiredCamera: Camera? = lock.withLock {
            generation &+= 1
            let retired = camera
            camera = nil
            return retired
        }

        waitGate.cancel()
        firstFrameReadiness.reset()
        photoResultListener.cancel()
        retiredCamera?.stream.stop()
        retiredCamera?.stop()
    }

    private func waitForFirstFrame(
        _ stream: MWDATCamera.Stream,
        token: UInt64
    ) async throws {
        let readiness = firstFrameReadiness
        let gate = waitGate

        let events = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            readiness.observe(stream) {
                _ = continuation.yield(Data())
                continuation.finish()
            }

            let waitToken = gate.install {
                readiness.reset()
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in
                gate.clear(waitToken)
                readiness.reset()
            }
        }

        do {
            _ = try await MetaDATPhotoRace.run(
                timeout: timeout,
                cancelTransfer: {
                    gate.cancel()
                }
            ) {
                for try await marker in events {
                    return marker
                }
                throw CancellationError()
            }
            try ensureCurrent(token)
        } catch MetaDATPhotoRaceError.timeout {
            throw AWLError.device(
                "Meta DAT camera did not produce a first frame before timeout"
            )
        }
    }

    private func capturePhoto(
        _ stream: MWDATCamera.Stream,
        token: UInt64
    ) async throws -> Data {
        let listener = photoResultListener
        let gate = waitGate

        let events = AsyncThrowingStream<Data, Error>(
            bufferingPolicy: .bufferingNewest(1)
        ) { continuation in
            listener.arm(stream) { data in
                _ = continuation.yield(data)
                continuation.finish()
            }

            let waitToken = gate.install {
                listener.cancel()
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in
                gate.clear(waitToken)
                listener.cancel()
            }
        }

        guard MetaDATPhotoShutter.trigger(stream) else {
            gate.cancel()
            throw AWLError.device("Meta DAT camera rejected the photo shutter request")
        }

        do {
            let data = try await MetaDATPhotoRace.run(
                timeout: timeout,
                cancelTransfer: {
                    gate.cancel()
                    stream.stop()
                }
            ) {
                for try await data in events {
                    return data
                }
                throw CancellationError()
            }
            try ensureCurrent(token)
            return data
        } catch MetaDATPhotoRaceError.timeout {
            throw AWLError.device(
                "Meta DAT photo transfer did not complete before timeout"
            )
        }
    }

    private func ensureCurrent(_ token: UInt64) throws {
        let current = lock.withLock {
            generation == token && activeCapture == token
        }
        guard current else { throw CancellationError() }
    }

    private func finishCapture(_ token: UInt64) {
        lock.withLock {
            if activeCapture == token {
                activeCapture = nil
            }
        }
    }
}

private final class MetaDATCaptureWaitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var cancellation: (@Sendable () -> Void)?

    func install(
        _ cancellation: @escaping @Sendable () -> Void
    ) -> UInt64 {
        lock.withLock {
            generation &+= 1
            self.cancellation = cancellation
            return generation
        }
    }

    func clear(_ token: UInt64) {
        lock.withLock {
            guard generation == token else { return }
            cancellation = nil
        }
    }

    func cancel() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            generation &+= 1
            let action = cancellation
            cancellation = nil
            return action
        }
        action?()
    }
}
