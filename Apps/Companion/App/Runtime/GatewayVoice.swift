import AgentWearLinkOpenClaw
import AVFoundation
import Foundation

/// Speaks replies in the Gateway computer's local voice through the
/// keep-alive engine, so the audio session is never touched while a DAT
/// session is live (dat-ios #292).
///
/// Per sentence, in order of preference:
/// 1. the streaming server (`streamConfig`): PCM over the tailnet, first
///    audio ~0.3 s; no audio within `StreamJitterPolicy.firstAudioDeadline`
///    hands this sentence and the rest of the reply down the chain;
/// 2. the Gateway's `tts.speak` (whole clips, ~1.5-1.9 s per sentence);
/// 3. the system voice (`fallback`).
/// Sentences are fetched ahead of the one playing and always played in
/// order; a new reply starts at the top of the chain again.
@MainActor
final class GatewayVoice {
    /// Renders one sentence; nil when the Gateway is not connected.
    var render: ((String) async throws -> OpenClawSpeechClip)?
    /// The streaming server; nil when not configured.
    var streamConfig: VoiceStreamConfig?
    /// Plays a decoded buffer; calls back when it finished.
    var play: ((AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Bool)?
    /// The engine's output format for decoded clips.
    var outputFormat: (() -> AVAudioFormat?)?
    /// Stops the clip that is playing now.
    var stopPlayback: (() -> Void)?
    /// A clip was scheduled and the player started (latency metric).
    var onPlaybackStarted: ((TurnStages.Voice) -> Void)?
    /// A streamed sentence started this long after it was needed.
    var onStreamFirstAudio: ((TimeInterval) -> Void)?
    /// A sentence left the stream for the fallback chain.
    var onStreamFallback: ((StreamFallbackReason) -> Void)?
    var onLog: ((String) -> Void)?
    /// Clips rendered ahead of the one playing; nil renders every queued
    /// sentence at once. MODERATE heat sets 1 (ThermalWorkPolicy). Streams
    /// always run at most one sentence ahead (the server renders one at a
    /// time, so more would only queue there).
    var prefetchLimit: Int?

    /// The Gateway's local TTS (tts.speak) returns whole clips: ~1.5-1.9 s per
    /// sentence on the Mac mini (2026-10-15). 3 s keeps the first sentence in
    /// the same voice.
    static let firstClipDeadline: Duration = .seconds(3)
    static let clipDeadline: Duration = .seconds(6)

    private struct Item {
        let text: String
        let enqueuedAt: Date
        /// First sentence of a reply (the short clip deadline applies).
        let first: Bool
        var clip: Task<AVAudioPCMBuffer?, Never>?
        var stream: StreamedSentence?
    }

    private var queue: [Item] = []
    private var draining = false
    private var generation = 0
    private var route: ReplyVoiceRoute = .system
    /// The sentence streaming or playing now (cancelled by `stop`).
    private var current: StreamedSentence?
    private(set) var isBusy = false

    /// Enqueues a sentence. Returns false when neither the stream nor the
    /// Gateway voice can be used (caller speaks it with the system voice).
    func enqueue(
        _ text: String,
        fallback: @escaping (String) async -> Void,
        finished: @escaping () -> Void,
        onIdle: @escaping () -> Void
    ) -> Bool {
        guard streamConfig != nil || render != nil, play != nil, outputFormat?() != nil else { return false }
        let first = queue.isEmpty && !isBusy
        if first { route = .start(streamConfigured: streamConfig != nil, gatewayAvailable: render != nil) }
        queue.append(Item(text: text, enqueuedAt: Date(), first: first))
        startPrefetches()
        isBusy = true
        if !draining { drain(fallback: fallback, finished: finished, onIdle: onIdle) }
        return true
    }

    func stop() {
        generation += 1
        for item in queue {
            item.clip?.cancel()
            item.stream?.cancel()
        }
        queue.removeAll()
        current?.cancel()
        current = nil
        let wasBusy = isBusy
        draining = false
        isBusy = false
        if wasBusy { stopPlayback?() }
    }

    private func drain(
        fallback: @escaping (String) async -> Void,
        finished: @escaping () -> Void,
        onIdle: @escaping () -> Void
    ) {
        draining = true
        let generationAtStart = generation
        Task { @MainActor in
            while generation == generationAtStart, !queue.isEmpty {
                var item = queue.removeFirst()
                let neededAt = max(item.enqueuedAt, Date())
                var spoken = false
                var fellFromStream = false

                if route == .stream {
                    let stream = item.stream ?? startStream(item.text)
                    item.stream = nil
                    startPrefetches()
                    if let stream {
                        current = stream
                        let outcome = await playStream(stream, neededAt: neededAt)
                        current = nil
                        guard generation == generationAtStart else { return }
                        switch outcome {
                        case .played:
                            spoken = true
                        case let .cut(reason):
                            // Played up to the cut; the rest of the reply falls back.
                            spoken = true
                            leaveStream(reason)
                        case let .failed(reason):
                            leaveStream(reason)
                            fellFromStream = true
                        }
                    } else {
                        leaveStream(.engine)
                        fellFromStream = true
                    }
                }

                if !spoken, route == .gateway {
                    let clip = item.clip ?? renderClip(item.text, first: item.first || fellFromStream)
                    item.clip = nil
                    startPrefetches()
                    let buffer = await clip?.value
                    guard generation == generationAtStart else { return }
                    if let buffer, let play, await Self.playAndWait(buffer, play: play, started: { [weak self] in
                        self?.onPlaybackStarted?(.gateway)
                    }) {
                        spoken = true
                    } else {
                        onLog?("gateway voice unavailable — system voice for the rest of this reply")
                        route = .system
                        cancelPrefetches()
                    }
                }

                if spoken {
                    finished()
                } else {
                    await fallback(item.text)
                }
            }
            guard generation == generationAtStart else { return }
            draining = false
            isBusy = false
            onIdle()
        }
    }

    private enum StreamResult {
        case played
        case cut(StreamFallbackReason)
        case failed(StreamFallbackReason)
    }

    private func playStream(_ stream: StreamedSentence, neededAt: Date) async -> StreamResult {
        switch await stream.waitForStart(deadline: StreamJitterPolicy.firstAudioDeadline) {
        case let .failed(reason):
            stream.cancel()
            return .failed(reason)
        case .ready:
            let waited = max(0, Date().timeIntervalSince(neededAt))
            onLog?("voice: stream first audio \(Int((waited * 1000).rounded())) ms")
            onStreamFirstAudio?(waited)
            onPlaybackStarted?(.stream)
            let outcome = await stream.play()
            if stream.underruns > 0 { onLog?("voice: stream underruns \(stream.underruns)") }
            switch outcome {
            case .completed, .stopped: return .played
            case let .cut(reason): return .cut(reason)
            }
        }
    }

    /// The stream failed for this reply: the rest goes down the chain.
    private func leaveStream(_ reason: StreamFallbackReason) {
        onLog?(reason.logLine)
        onStreamFallback?(reason)
        route = route.next(gatewayAvailable: render != nil)
        cancelPrefetches()
        startPrefetches()
    }

    private func startStream(_ text: String) -> StreamedSentence? {
        guard let streamConfig, let play, let format = outputFormat?() else { return nil }
        return StreamedSentence(text: text, config: streamConfig, format: format, schedule: play)
    }

    private func renderClip(_ text: String, first: Bool) -> Task<AVAudioPCMBuffer?, Never>? {
        guard let render, let format = outputFormat?() else { return nil }
        let deadline = first ? Self.firstClipDeadline : Self.clipDeadline
        return Task<AVAudioPCMBuffer?, Never> {
            await Self.fetch(text, render: render, format: format, deadline: deadline)
        }
    }

    /// Starts fetching ahead for the current route: one stream, or the
    /// first `prefetchLimit` gateway clips (all when nil).
    private func startPrefetches() {
        switch route {
        case .stream:
            if let index = queue.indices.first, queue[index].stream == nil {
                queue[index].stream = startStream(queue[index].text)
            }
        case .gateway:
            let limit = min(prefetchLimit ?? queue.count, queue.count)
            for index in 0..<limit where queue[index].clip == nil {
                queue[index].clip = renderClip(queue[index].text, first: queue[index].first)
            }
        case .system:
            break
        }
    }

    /// Drops fetches made for a route this reply no longer uses.
    private func cancelPrefetches() {
        for index in queue.indices {
            if route != .stream, let stream = queue[index].stream {
                stream.cancel()
                queue[index].stream = nil
            }
            if route != .gateway, let clip = queue[index].clip {
                clip.cancel()
                queue[index].clip = nil
            }
        }
    }

    private static func playAndWait(
        _ buffer: AVAudioPCMBuffer,
        play: (AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Bool,
        started: () -> Void
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let playing = play(buffer) { continuation.resume(returning: true) }
            if playing { started() } else { continuation.resume(returning: false) }
        }
    }

    private static func fetch(
        _ text: String,
        render: @escaping (String) async throws -> OpenClawSpeechClip,
        format: AVAudioFormat,
        deadline: Duration
    ) async -> AVAudioPCMBuffer? {
        let clip: OpenClawSpeechClip? = await withTaskGroup(of: OpenClawSpeechClip?.self) { group in
            group.addTask { try? await render(text) }
            group.addTask {
                try? await Task.sleep(for: deadline)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let clip, let data = clip.audio else { return nil }
        return decode(data, fileExtension: clip.fileExtension, to: format)
    }

    /// Decodes a clip (wav, mp3, m4a, caf …) into the engine's format.
    nonisolated static func decode(_ data: Data, fileExtension: String?, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ext = (fileExtension ?? ".wav").trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("awl-tts-\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil,
              let file = try? AVAudioFile(forReading: url),
              let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: source)) != nil else { return nil }
        if source.format == format { return source }
        guard let converter = AVAudioConverter(from: source.format, to: format) else { return nil }
        let ratio = format.sampleRate / source.format.sampleRate
        let capacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed {
                status.pointee = .endOfStream
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? output : nil
    }
}
