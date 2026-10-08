import AgentWearLinkCore
import Foundation
import MWDATCamera
import MWDATCore

/// Standalone Photo is experimental in pinned Meta DAT 1.0.0 and must be an
/// explicit opt-in. The compatible streaming still path remains the default.
public enum MetaDATSnapshotMode: Sendable, Equatable {
    case compatibleStreamStill
    case experimentalStandalonePhoto
}

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
    private let snapshotMode: MetaDATSnapshotMode

    private var generation: UInt64 = 0
    private var activeCapture: UInt64?
    private var camera: Camera?

    private let firstFrameReadiness = MetaDATFirstFrameReadiness()
    private let photoResultListener = MetaDATPhotoResultListener()
    #if DEBUG
    private let standalonePhotoCapture = MetaDATStandalonePhotoCapture()
    #endif
    private let waitGate = MetaDATCaptureWaitGate()

    public init(
        timeout: Duration = .seconds(5),
        maximumBytes: Int = ImageAttachment.defaultMaximumBytes,
        snapshotMode: MetaDATSnapshotMode = .compatibleStreamStill
    ) {
        precondition(timeout > .zero)
        precondition(maximumBytes > 0)
        precondition(maximumBytes <= ImageAttachment.defaultMaximumBytes)
        self.timeout = timeout
        self.maximumBytes = maximumBytes
        self.snapshotMode = snapshotMode
    }

    public func capture(from session: DeviceSession) async throws -> ImageAttachment {
        let token: UInt64 = try lock.withLock {
            guard activeCapture == nil else {
                throw AWLError.device("Meta DAT snapshot capture is already in progress")
            }
            generation &+= 1
            activeCapture = generation
            return generation
        }

        // A photo-only camera must not survive across captures. The pinned DAT
        // release has an upstream report of retained camera-stream heap buffers;
        // even a stopped stream may retain vendor-owned allocations. Always
        // tear down Camera ownership at this one-shot boundary.
        defer { finishCapture(token) }

        guard let camera = try MetaDATCameraConfiguration.attach(to: session) else {
            throw AWLError.capabilityUnavailable(
                "Meta DAT camera is unavailable for the selected device"
            )
        }

        let accepted = lock.withLock {
            guard generation == token, activeCapture == token else {
                return false
            }
            self.camera = camera
            return true
        }
        guard accepted else {
            camera.stop()
            throw CancellationError()
        }

        try ensureCurrent(token)

        if snapshotMode == .experimentalStandalonePhoto {
            #if DEBUG
            // Experimental and non-publishable per pinned DAT 1.0.0:
            // never enable without an explicit owner-selected mode.
            // No Stream.start(), video frames or audio transport in this path.
            let bytes = try await standalonePhotoCapture.capture(
                camera.photo,
                timeout: timeout
            )
            try ensureCurrent(token)
            // AWL's SDK-neutral photo contract accepts JPEG only. Fail closed
            // on HEIC/unknown payloads; do not mislabel media as image/jpeg.
            try MetaDATPhotoNormalizer.validateStreamJPEG(
                bytes,
                maximumBytes: maximumBytes
            )
            return try ImageAttachment(
                data: bytes,
                format: .jpeg,
                maximumBytes: maximumBytes
            )
            #else
            throw AWLError.capabilityUnavailable(
                "Meta DAT standalone Photo is unavailable outside DEBUG builds"
            )
            #endif
        }

        let stream = camera.stream
        firstFrameReadiness.reset()
        photoResultListener.cancel()

        do {
            // waitForFirstFrame installs the first-frame listener and cancel
            // gate before stream.start() can synchronously deliver a frame.
            try await waitForFirstFrame(stream, token: token)
            try ensureCurrent(token)

            let bytes = try await capturePhoto(stream, token: token)
            try ensureCurrent(token)

            try MetaDATPhotoNormalizer.validateStreamJPEG(
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
        #if DEBUG
        standalonePhotoCapture.cancel()
        if snapshotMode == .experimentalStandalonePhoto {
            retiredCamera?.photo.stop()
        }
        #endif
        retiredCamera?.stream.stop()
        retiredCamera?.stop()
    }

    private func waitForFirstFrame(
        _ stream: MWDATCamera.Stream,
        token: UInt64
    ) async throws {
        let readiness = firstFrameReadiness
        let gate = waitGate

        let events = MetaDATCameraStartOrder.armBeforeStart(
            observe: {
                AsyncThrowingStream<Data, Error>(
                    bufferingPolicy: .bufferingNewest(1)
                ) { continuation in
                    let frameLease = readiness.observe(stream) {
                        _ = continuation.yield(Data())
                        continuation.finish()
                    }

                    let waitToken = gate.install {
                        readiness.reset(ifCurrent: frameLease)
                        continuation.finish(throwing: CancellationError())
                    }
                    continuation.onTermination = { _ in
                        gate.clear(waitToken)
                        readiness.reset(ifCurrent: frameLease)
                    }
                }
            },
            start: { stream.start() }
        )

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
            let photoLease = listener.arm(
                stream,
                onData: { data in
                    _ = continuation.yield(data)
                    continuation.finish()
                },
                onError: {
                    continuation.finish(throwing: AWLError.device(
                        "Meta DAT camera stream failed during photo capture"
                    ))
                }
            )

            let waitToken = gate.install {
                listener.cancel(ifCurrent: photoLease)
                continuation.finish(throwing: CancellationError())
            }
            continuation.onTermination = { _ in
                gate.clear(waitToken)
                listener.cancel(ifCurrent: photoLease)
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
        let retiredCamera: Camera? = lock.withLock {
            guard activeCapture == token else { return nil }
            activeCapture = nil
            let retired = camera
            camera = nil
            return retired
        }
        // Idempotent with invalidate(): whichever boundary retires Camera
        // first owns the stop, so late capture completion cannot stop a new
        // generation's camera or keep a previous one alive between captures.
        #if DEBUG
        if snapshotMode == .experimentalStandalonePhoto {
            retiredCamera?.photo.stop()
        }
        #endif
        retiredCamera?.stream.stop()
        retiredCamera?.stop()
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
