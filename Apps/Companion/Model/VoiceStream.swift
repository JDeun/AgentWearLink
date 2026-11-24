import Foundation

/// Where the streaming voice lives: the Gateway computer's local TTS,
/// published on the tailnet (`tailscale serve`, never funnel) and guarded by
/// a bearer key. The key stays in the Keychain; nothing here is logged.
public struct VoiceStreamConfig: Equatable, Sendable, Codable {
    public let baseURL: URL
    public let key: String

    public static let streamPath = "v1/audio/speech/stream"
    public static let minimumKeyLength = 32

    /// nil unless the URL is https with a host and the key looks like one.
    public init?(url: String, key: String) {
        let trimmedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              trimmedKey.count >= Self.minimumKeyLength,
              trimmedKey.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }) else { return nil }
        components.query = nil
        components.fragment = nil
        if components.path == "/" { components.path = "" }
        guard let base = components.url else { return nil }
        baseURL = base
        self.key = trimmedKey
    }

    public var streamURL: URL { baseURL.appendingPathComponent(Self.streamPath) }
    public var authorization: String { "Bearer \(key)" }
}

/// The server's stream format: raw PCM s16le, 24 kHz, mono.
public enum VoiceStreamFormat {
    public static let sampleRate: Double = 24_000
    public static let bytesPerSample = 2
}

/// Cuts arbitrary network chunks into whole 16-bit samples, carrying a
/// split sample over to the next chunk so nothing is lost or shifted.
public struct PCMSampleAssembler: Sendable {
    private var carry: UInt8?
    public private(set) var totalSamples = 0

    public init() {}

    /// Whole little-endian 16-bit samples from `data` (plus any carried byte).
    public mutating func append(_ data: Data) -> [Int16] {
        guard !data.isEmpty else { return [] }
        var bytes = [UInt8]()
        bytes.reserveCapacity(data.count + 1)
        if let carry { bytes.append(carry) }
        bytes.append(contentsOf: data)
        if bytes.count.isMultiple(of: 2) {
            carry = nil
        } else {
            carry = bytes.removeLast()
        }
        var samples = [Int16](repeating: 0, count: bytes.count / 2)
        for index in samples.indices {
            samples[index] = Int16(bitPattern: UInt16(bytes[2 * index]) | UInt16(bytes[2 * index + 1]) << 8)
        }
        totalSamples += samples.count
        return samples
    }

    /// A dangling half sample at the end of the stream (dropped).
    public var hasDanglingByte: Bool { carry != nil }
}

/// When a streamed sentence starts playing: after `jitterSeconds` of audio
/// has arrived (so a Tailscale hiccup does not cut it), or as soon as the
/// stream ended if it is shorter than that.
public enum StreamJitterPolicy {
    public static let jitterSeconds: TimeInterval = 0.25
    /// No first audio by then: this sentence and the rest of the reply fall
    /// back (Gateway `tts.speak`, then the system voice).
    public static let firstAudioDeadline: Duration = .milliseconds(1200)
    /// Longest silence allowed between chunks once playing.
    public static let stallTimeout: TimeInterval = 4

    public static func shouldStart(bufferedSeconds: TimeInterval, ended: Bool) -> Bool {
        ended ? bufferedSeconds > 0 : bufferedSeconds >= jitterSeconds
    }
}

/// Why a sentence did not play from the stream (numbers and codes only).
public enum StreamFallbackReason: Equatable, Sendable {
    case deadline
    case http(Int)
    case network
    case empty
    case cut
    case engine

    public var code: String {
        switch self {
        case .deadline: "deadline"
        case let .http(status): "http-\(status)"
        case .network: "network"
        case .empty: "empty"
        case .cut: "cut"
        case .engine: "engine"
        }
    }

    public var logLine: String { "voice: stream fallback \(code)" }
}

/// Which voice speaks the next sentence of a reply. A failure moves the
/// rest of the reply down the chain; a new reply starts at the top again.
public enum ReplyVoiceRoute: Equatable, Sendable {
    case stream
    case gateway
    case system

    public static func start(streamConfigured: Bool, gatewayAvailable: Bool) -> ReplyVoiceRoute {
        if streamConfigured { return .stream }
        return gatewayAvailable ? .gateway : .system
    }

    public func next(gatewayAvailable: Bool) -> ReplyVoiceRoute {
        switch self {
        case .stream: gatewayAvailable ? .gateway : .system
        case .gateway, .system: .system
        }
    }
}

extension LaunchArgument {
    static let voiceStreamURL = "-AWLVoiceStreamURL"
    static let voiceStreamKey = "-AWLVoiceStreamKey"

    /// Like `value`, but a value may start with "-" (a base64url key can).
    /// Validation is left to the caller (`VoiceStreamConfig`).
    static func rawValue(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        let value = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
