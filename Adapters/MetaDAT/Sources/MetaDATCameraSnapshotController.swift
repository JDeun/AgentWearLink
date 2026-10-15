import AgentWearLinkCore
import Foundation
import MWDATCamera
import MWDATCore

/// Standalone Photo is experimental in pinned Meta DAT 1.0.0 and must be an
/// explicit opt-in. The compatible streaming still path remains the default.
public enum MetaDATSnapshotMode: String, Sendable, Equatable {
    case compatibleStreamStill = "stream"
    case experimentalStandalonePhoto = "standalone"
}

/// Stage durations of one capture, milliseconds (numbers only, never media).
/// Stream mode: attach → first frame (ready) → shutter to JPEG (photo) →
/// stream stop → re-encode. Standalone mode: attach → photo (start, ready
/// and transfer) → re-encode.
public struct MetaDATSnapshotTimings: Sendable, Equatable {
    public var mode: MetaDATSnapshotMode
    public var attachMilliseconds: Int?
    public var readyMilliseconds: Int?
    public var photoMilliseconds: Int?
    public var stopMilliseconds: Int?
    public var encodeMilliseconds: Int?
    public var totalMilliseconds: Int?
    public var rawBytes: Int?
    public var jpegBytes: Int?
    public var width: Int?
    public var height: Int?

    public init(mode: MetaDATSnapshotMode) { self.mode = mode }

    public var logLine: String {
        func ms(_ value: Int?) -> String { value.map { "\($0) ms" } ?? "—" }
        var line = "photo timings [\(mode.rawValue)]: attach \(ms(attachMilliseconds))"
        if mode == .compatibleStreamStill { line += ", first frame \(ms(readyMilliseconds))" }
        if mode == .experimentalStandalonePhoto { line += ", started \(ms(readyMilliseconds))" }
        line += ", photo \(ms(photoMilliseconds))"
        if mode == .compatibleStreamStill { line += ", stop \(ms(stopMilliseconds))" }
        line += ", encode \(ms(encodeMilliseconds)), total \(ms(totalMilliseconds))"
        if let width, let height { line += ", \(width)x\(height)" }
        if let rawBytes, let jpegBytes { line += ", \(rawBytes / 1024)→\(jpegBytes / 1024) KB" }
        return line
    }
}

public struct MetaDATSnapshotResult: Sendable, Equatable {
    public let image: ImageAttachment
    public let timings: MetaDATSnapshotTimings
}

/// First-set-wins instant, written from a vendor callback.
final class MetaDATOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ContinuousClock.Instant?
    func set() { lock.withLock { if value == nil { value = ContinuousClock.now } } }
    var instant: ContinuousClock.Instant? { lock.withLock { value } }
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
    private var activeMode: MetaDATSnapshotMode
    private var lastTimings: MetaDATSnapshotTimings?

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
        self.activeMode = snapshotMode
    }

    public func capture(from session: DeviceSession) async throws -> ImageAttachment {
        try await capture(from: session, mode: snapshotMode).image
    }

    /// Stage timings of the most recent attempt, also after a failure (the
    /// stages it reached). Numbers only.
    public var lastAttemptTimings: MetaDATSnapshotTimings? {
        lock.withLock { lastTimings }
    }

    /// One still in `mode`, re-encoded by `MetaDATStillEncoder` (long side
    /// capped, JPEG). The camera is attached for this capture only and torn
    /// down before returning on every path.
    public func capture(
        from session: DeviceSession,
        mode: MetaDATSnapshotMode
    ) async throws -> MetaDATSnapshotResult {
        let token: UInt64 = try lock.withLock {
            guard activeCapture == nil else {
                throw AWLError.device("Meta DAT snapshot capture is already in progress")
            }
            generation &+= 1
            activeCapture = generation
            activeMode = mode
            lastTimings = MetaDATSnapshotTimings(mode: mode)
            return generation
        }
        let clock = ContinuousClock()
        let began = clock.now
        var mark = began
        func lap(_ stage: WritableKeyPath<MetaDATSnapshotTimings, Int?>) {
            let now = clock.now
            let elapsed = Self.milliseconds(now - mark)
            mark = now
            lock.withLock {
                lastTimings?[keyPath: stage] = elapsed
                lastTimings?.totalMilliseconds = Self.milliseconds(now - began)
            }
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
        lap(\.attachMilliseconds)

        try ensureCurrent(token)

        let raw: Data
        if mode == .experimentalStandalonePhoto {
            #if DEBUG
            // Experimental and non-publishable per pinned DAT 1.0.0:
            // never enable without an explicit owner-selected mode.
            // No Stream.start(), video frames or audio transport in this path.
            let ready = MetaDATOnceFlag()
            let photoBegan = clock.now
            do {
                raw = try await standalonePhotoCapture.capture(
                    camera.photo,
                    timeout: timeout,
                    onReady: { ready.set() }
                )
            } catch {
                if let readyAt = ready.instant {
                    lock.withLock { lastTimings?.readyMilliseconds = Self.milliseconds(readyAt - photoBegan) }
                } else if !(error is CancellationError) {
                    // BirdSpotter: Photo.start() on a cold camera can sit at
                    // `starting` forever. Say which stage it never left.
                    throw AWLError.device("Meta DAT standalone photo never reached started (cold camera?)")
                }
                throw error
            }
            if let readyAt = ready.instant {
                lock.withLock { lastTimings?.readyMilliseconds = Self.milliseconds(readyAt - photoBegan) }
            }
            lap(\.photoMilliseconds)
            try ensureCurrent(token)
            try MetaDATPhotoNormalizer.validatePayload(
                raw,
                maximumBytes: MetaDATPhotoNormalizer.defaultMaximumBytes
            )
            #else
            throw AWLError.capabilityUnavailable(
                "Meta DAT standalone Photo is unavailable outside DEBUG builds"
            )
            #endif
        } else {
            let stream = camera.stream
            firstFrameReadiness.reset()
            photoResultListener.cancel()

            do {
                // waitForFirstFrame installs the first-frame listener and cancel
                // gate before stream.start() can synchronously deliver a frame.
                try await waitForFirstFrame(stream, token: token)
                lap(\.readyMilliseconds)
                try ensureCurrent(token)

                raw = try await capturePhoto(stream, token: token)
                lap(\.photoMilliseconds)
                try ensureCurrent(token)

                try MetaDATPhotoNormalizer.validateStreamJPEG(
                    raw,
                    maximumBytes: MetaDATPhotoNormalizer.defaultMaximumBytes
                )

                // Stop at once: every streamed second keeps the LED on, holds
                // the sensor and (dat-ios #256) may keep music paused.
                stream.stop()
                firstFrameReadiness.reset()
                photoResultListener.cancel()
                lap(\.stopMilliseconds)
            } catch {
                stream.stop()
                firstFrameReadiness.reset()
                photoResultListener.cancel()
                throw error
            }
        }

        let encoded: MetaDATStillEncoder.Output
        do {
            encoded = try MetaDATStillEncoder.jpeg(from: raw)
        } catch {
            throw AWLError.device("Meta DAT photo could not be decoded")
        }
        lap(\.encodeMilliseconds)
        try ensureCurrent(token)
        let image = try ImageAttachment(
            data: encoded.jpeg,
            format: .jpeg,
            maximumBytes: maximumBytes
        )
        let timings: MetaDATSnapshotTimings = lock.withLock {
            lastTimings?.rawBytes = raw.count
            lastTimings?.jpegBytes = encoded.jpeg.count
            lastTimings?.width = encoded.width
            lastTimings?.height = encoded.height
            return lastTimings ?? MetaDATSnapshotTimings(mode: mode)
        }
        return MetaDATSnapshotResult(image: image, timings: timings)
    }

    static func milliseconds(_ duration: Duration) -> Int {
        let parts = duration.components
        return Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000)
    }

    /// Synchronously invalidates the current media generation.
    ///
    /// This is safe to call from DeviceSession teardown while capture() is
    /// suspended. The pending wait is finished immediately and late callbacks
    /// are rejected by both the wait gate and generation checks.
    public func invalidate() {
        let (retiredCamera, mode): (Camera?, MetaDATSnapshotMode) = lock.withLock {
            generation &+= 1
            let retired = camera
            camera = nil
            return (retired, activeMode)
        }

        waitGate.cancel()
        firstFrameReadiness.reset()
        photoResultListener.cancel()
        #if DEBUG
        standalonePhotoCapture.cancel()
        if mode == .experimentalStandalonePhoto {
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
        let (retiredCamera, mode): (Camera?, MetaDATSnapshotMode) = lock.withLock {
            guard activeCapture == token else { return (nil, activeMode) }
            activeCapture = nil
            let retired = camera
            camera = nil
            return (retired, activeMode)
        }
        // Idempotent with invalidate(): whichever boundary retires Camera
        // first owns the stop, so late capture completion cannot stop a new
        // generation's camera or keep a previous one alive between captures.
        #if DEBUG
        if mode == .experimentalStandalonePhoto {
            retiredCamera?.photo.stop()
        }
        #else
        _ = mode
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
