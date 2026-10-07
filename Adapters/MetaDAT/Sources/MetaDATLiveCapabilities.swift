import AgentWearLinkCore
import Foundation

public struct MetaDATLiveCapabilities: Sendable, Equatable {
    public var sessionReady = false
    public var speechReady = false
    public var cameraReady = false
    public var voiceInvocationReady = false

    public init() {}

    public var value: CapabilitySet {
        var result: CapabilitySet = []

        // Speech and camera are DeviceSession-owned surfaces. They are not
        // operational unless the concrete session is currently ready.
        if sessionReady {
            if speechReady { result.insert(.speechInput) }
            if cameraReady { result.insert(.cameraSnapshot) }
        }

        // Voice Invocation is intentionally independent from DeviceSession.
        // Its listener follows registration/device-link readiness on its own.
        if voiceInvocationReady {
            result.insert(.voiceInvocation)
        }

        return result
    }
}

/// Thread-safe snapshot used by the actor-backed production adapter to expose
/// synchronous DeviceAdapter.capabilities without freezing readiness at init.
final class MetaDATLiveCapabilitySource: @unchecked Sendable {
    private let lock = NSLock()
    private var state = MetaDATLiveCapabilities()

    var value: CapabilitySet {
        lock.lock()
        let value = state.value
        lock.unlock()
        return value
    }

    func update(
        sessionReady: Bool? = nil,
        speechReady: Bool? = nil,
        cameraReady: Bool? = nil,
        voiceInvocationReady: Bool? = nil
    ) {
        lock.lock()
        if let sessionReady {
            state.sessionReady = sessionReady
        }
        if let speechReady {
            state.speechReady = speechReady
        }
        if let cameraReady {
            state.cameraReady = cameraReady
        }
        if let voiceInvocationReady {
            state.voiceInvocationReady = voiceInvocationReady
        }
        lock.unlock()
    }

    func reset() {
        lock.lock()
        state = MetaDATLiveCapabilities()
        lock.unlock()
    }
}
