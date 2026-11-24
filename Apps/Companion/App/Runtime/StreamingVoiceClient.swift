import AVFoundation
import Foundation
import Security

/// The streaming voice's URL and key in the Keychain (this device only,
/// readable after the first unlock). Never in UserDefaults, never logged.
enum VoiceStreamStore {
    private static let service = "dev.agentwearlink.companion.voicestream"
    private static let account = "config"

    static func load() -> VoiceStreamConfig? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return VoiceStreamConfig(url: stored.url, key: stored.key)
    }

    @discardableResult
    static func save(_ config: VoiceStreamConfig) -> Bool {
        guard let data = try? JSONEncoder().encode(Stored(url: config.baseURL.absoluteString, key: config.key)) else {
            return false
        }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let update = SecItemUpdate(base as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var item = base
        attributes.forEach { item[$0.key] = $0.value }
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    private struct Stored: Codable {
        let url: String
        let key: String
    }
}

/// Streams one sentence's PCM from the TTS server and converts it, chunk by
/// chunk, into the keep-alive engine's speech format. One converter per
/// sentence keeps its resampler state across chunks, so the converted
/// buffers are contiguous and play back to back without seams.
final class StreamingVoiceTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Handlers {
        /// Converted audio, in order. Runs on the main actor.
        let audio: @MainActor (AVAudioPCMBuffer) -> Void
        /// The stream ended: nil when complete, else why it failed.
        let finished: @MainActor (StreamFallbackReason?) -> Void
    }

    static let shared = StreamingVoiceTransport()

    private let queue: OperationQueue
    private var session: URLSession!
    private let lock = NSLock()
    private var downloads: [Int: Download] = [:]

    override init() {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "awl.voice-stream"
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        // Idle time between bytes. A prefetched sentence waits for the one
        // before it to finish rendering (the server renders one at a time).
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 120
        configuration.waitsForConnectivity = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    /// Starts a stream; returns a handle that cancels it.
    func start(_ text: String, config: VoiceStreamConfig, format: AVAudioFormat, handlers: Handlers) -> Cancellable? {
        var request = URLRequest(url: config.streamURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(config.authorization, forHTTPHeaderField: "Authorization")
        guard let body = try? JSONSerialization.data(withJSONObject: ["input": text]),
              let converter = PCMStreamConverter(output: format) else { return nil }
        request.httpBody = body
        let task = session.dataTask(with: request)
        lock.withLock { downloads[task.taskIdentifier] = Download(converter: converter, handlers: handlers) }
        task.resume()
        return Cancellable(task: task)
    }

    struct Cancellable {
        fileprivate let task: URLSessionDataTask
        func cancel() { task.cancel() }
    }

    private final class Download {
        let converter: PCMStreamConverter
        let handlers: Handlers
        var assembler = PCMSampleAssembler()
        var failure: StreamFallbackReason?

        init(converter: PCMStreamConverter, handlers: Handlers) {
            self.converter = converter
            self.handlers = handlers
        }
    }

    private func download(_ task: URLSessionTask) -> Download? {
        lock.withLock { downloads[task.taskIdentifier] }
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let download = download(dataTask) else { return completionHandler(.cancel) }
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let rate = http?.value(forHTTPHeaderField: "X-Audio-Sample-Rate").flatMap(Double.init)
        if status != 200 || (rate != nil && rate != VoiceStreamFormat.sampleRate) {
            download.failure = .http(status == 200 ? 415 : status)
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let download = download(dataTask) else { return }
        let samples = download.assembler.append(data)
        guard !samples.isEmpty, let buffer = download.converter.convert(samples) else { return }
        let deliver = download.handlers.audio
        let box = BufferBox(buffer)
        Task { @MainActor in deliver(box.buffer) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let download = lock.withLock({ downloads.removeValue(forKey: task.taskIdentifier) }) else { return }
        if (error as? URLError)?.code == .cancelled, download.failure == nil { return } // we cancelled it
        var reason = download.failure
        if reason == nil, error != nil { reason = .network }
        let tail = reason == nil ? download.converter.finish() : nil
        let handlers = download.handlers
        let box = tail.map(BufferBox.init)
        Task { @MainActor in
            if let box { handlers.audio(box.buffer) }
            handlers.finished(reason)
        }
    }

    private struct BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }
}

/// s16le 24 kHz mono → the engine's format (float, its rate, every channel
/// carrying the mono signal). Stateful: call `convert` per chunk, then
/// `finish` once to flush the resampler's tail.
final class PCMStreamConverter {
    private let output: AVAudioFormat
    private let monoIn: AVAudioFormat
    private let monoOut: AVAudioFormat
    private let resampler: AVAudioConverter?
    private var ended = false

    init?(output: AVAudioFormat) {
        guard output.commonFormat == .pcmFormatFloat32, !output.isInterleaved,
              let monoIn = AVAudioFormat(standardFormatWithSampleRate: VoiceStreamFormat.sampleRate, channels: 1),
              let monoOut = AVAudioFormat(standardFormatWithSampleRate: output.sampleRate, channels: 1) else { return nil }
        self.output = output
        self.monoIn = monoIn
        self.monoOut = monoOut
        if output.sampleRate == VoiceStreamFormat.sampleRate {
            resampler = nil
        } else {
            guard let converter = AVAudioConverter(from: monoIn, to: monoOut) else { return nil }
            converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            resampler = converter
        }
    }

    func convert(_ samples: [Int16]) -> AVAudioPCMBuffer? {
        guard !ended, let input = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = input.floatChannelData?[0] else { return nil }
        input.frameLength = AVAudioFrameCount(samples.count)
        for index in samples.indices { channel[index] = Float(samples[index]) / 32_768 }
        return resample(input, final: false)
    }

    /// The resampler's remaining frames (nil when there are none).
    func finish() -> AVAudioPCMBuffer? {
        guard !ended else { return nil }
        let tail = resampler == nil ? nil : resample(nil, final: true)
        ended = true
        return tail
    }

    private func resample(_ input: AVAudioPCMBuffer?, final: Bool) -> AVAudioPCMBuffer? {
        guard let resampler else { return input.flatMap(spread) }
        let ratio = monoOut.sampleRate / monoIn.sampleRate
        let capacity = AVAudioFrameCount(Double(input?.frameLength ?? 0) * ratio) + 2048
        var mono: [Float] = []
        var supplied = input == nil
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: capacity) else { return nil }
            var error: NSError?
            let status = resampler.convert(to: out, error: &error) { _, inputStatus in
                if !supplied, let input {
                    supplied = true
                    inputStatus.pointee = .haveData
                    return input
                }
                inputStatus.pointee = final ? .endOfStream : .noDataNow
                return nil
            }
            if error != nil || status == .error { return nil }
            if let data = out.floatChannelData?[0], out.frameLength > 0 {
                mono.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            }
            // .haveData: the output filled up and more is waiting.
            if status != .haveData { break }
        }
        guard !mono.isEmpty, let buffer = AVAudioPCMBuffer(pcmFormat: monoOut, frameCapacity: AVAudioFrameCount(mono.count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: mono.count) }
        return spread(buffer)
    }

    /// Mono → every channel of the output format.
    private func spread(_ mono: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let source = mono.floatChannelData?[0],
              let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: mono.frameLength),
              let channels = buffer.floatChannelData else { return nil }
        buffer.frameLength = mono.frameLength
        for index in 0..<Int(output.channelCount) {
            channels[index].update(from: source, count: Int(mono.frameLength))
        }
        return buffer
    }
}

/// One reply sentence from the stream: buffers arrive, playback starts once
/// the jitter buffer is full, later buffers are scheduled right behind the
/// ones playing (contiguous PCM, so no fades are needed).
@MainActor
final class StreamedSentence {
    enum Start {
        case ready
        case failed(StreamFallbackReason)
    }

    enum Outcome {
        case completed
        /// The stream broke after audio started; what arrived was played.
        case cut(StreamFallbackReason)
        case stopped
    }

    private let schedule: (AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Bool
    private var handle: StreamingVoiceTransport.Cancellable?
    private var pending: [AVAudioPCMBuffer] = []
    private var bufferedSeconds: TimeInterval = 0
    private var ended = false
    private var failure: StreamFallbackReason?
    private var playing = false
    private var stopped = false
    private var scheduled = 0
    private var played = 0
    /// Scheduling a buffer with nothing left queued: an audible gap.
    private(set) var underruns = 0
    private var expectedEnd = Date.distantPast
    private var startWaiter: CheckedContinuation<Start, Never>?
    private var endWaiter: CheckedContinuation<Outcome, Never>?
    private var watchdog: Task<Void, Never>?

    init(
        text: String, config: VoiceStreamConfig, format: AVAudioFormat,
        schedule: @escaping (AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Bool
    ) {
        self.schedule = schedule
        handle = StreamingVoiceTransport.shared.start(text, config: config, format: format, handlers: .init(
            audio: { [weak self] buffer in self?.received(buffer) },
            finished: { [weak self] reason in self?.streamEnded(reason) }
        ))
        if handle == nil {
            failure = .engine
            ended = true
        }
    }

    /// Waits until playback can start (jitter buffer full, or a short
    /// sentence fully arrived), the stream failed, or `deadline` passed.
    func waitForStart(deadline: Duration) async -> Start {
        if let start = startState { return start }
        return await withCheckedContinuation { continuation in
            startWaiter = continuation
            Task { [weak self] in
                try? await Task.sleep(for: deadline)
                self?.resumeStart(.failed(.deadline))
            }
        }
    }

    /// Schedules what has arrived and keeps scheduling until the stream
    /// ends; returns when the last buffer played.
    func play() async -> Outcome {
        guard !stopped else { return .stopped }
        playing = true
        let ready = pending
        pending.removeAll()
        bufferedSeconds = 0
        for buffer in ready where !enqueue(buffer) {
            fail(.engine)
            break
        }
        return await withCheckedContinuation { continuation in
            endWaiter = continuation
            checkDone()
            startWatchdog()
        }
    }

    /// Stops the download (the server stops rendering) and any waiting.
    func cancel() {
        stopped = true
        handle?.cancel()
        handle = nil
        watchdog?.cancel()
        resumeStart(.failed(.deadline))
        resumeEnd(.stopped)
    }

    /// A failure before playback fails the whole sentence (the fallback
    /// says it whole); after playback started it is a cut.
    private var startState: Start? {
        if let failure, !playing { return .failed(failure) }
        if StreamJitterPolicy.shouldStart(bufferedSeconds: bufferedSeconds, ended: ended) { return .ready }
        return ended ? .failed(.empty) : nil
    }

    private func received(_ buffer: AVAudioPCMBuffer) {
        guard !stopped, buffer.frameLength > 0 else { return }
        if playing {
            if !enqueue(buffer) { fail(.engine) }
            return
        }
        pending.append(buffer)
        bufferedSeconds += Double(buffer.frameLength) / buffer.format.sampleRate
        if let start = startState { resumeStart(start) }
    }

    private func streamEnded(_ reason: StreamFallbackReason?) {
        handle = nil
        ended = true
        if let reason { failure = playing ? .cut : reason }
        if let start = startState { resumeStart(start) }
        checkDone()
    }

    private func fail(_ reason: StreamFallbackReason) {
        failure = reason
        ended = true
        handle?.cancel()
        handle = nil
        checkDone()
    }

    private func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        if scheduled > 0, played == scheduled { underruns += 1 }
        let accepted = schedule(buffer) { [weak self] in
            Task { @MainActor in self?.bufferPlayed() }
        }
        guard accepted else { return false }
        scheduled += 1
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        expectedEnd = max(expectedEnd, Date()).addingTimeInterval(duration)
        return true
    }

    private func bufferPlayed() {
        played += 1
        checkDone()
    }

    private func checkDone() {
        guard playing, ended, played >= scheduled else { return }
        finish()
    }

    private func finish() {
        watchdog?.cancel()
        resumeEnd(failure.map(Outcome.cut) ?? .completed)
    }

    /// A restarted engine drops its player's callbacks: end the sentence
    /// once its audio must have finished. Also ends a stream that stalls.
    private func startWatchdog() {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            var lastScheduled = -1
            var stalledSince = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, !Task.isCancelled, self.endWaiter != nil else { return }
                let now = Date()
                if self.ended {
                    if now > self.expectedEnd.addingTimeInterval(1.5) { self.finish() }
                    continue
                }
                if self.scheduled != lastScheduled {
                    lastScheduled = self.scheduled
                    stalledSince = now
                } else if now.timeIntervalSince(stalledSince) > StreamJitterPolicy.stallTimeout {
                    self.fail(.cut)
                }
            }
        }
    }

    private func resumeStart(_ start: Start) {
        guard let waiter = startWaiter else { return }
        startWaiter = nil
        waiter.resume(returning: start)
    }

    private func resumeEnd(_ outcome: Outcome) {
        guard let waiter = endWaiter else { return }
        endWaiter = nil
        waiter.resume(returning: outcome)
    }
}
