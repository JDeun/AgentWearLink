import AgentWearLinkOpenClaw
import AVFoundation
import Foundation

/// Speaks replies with the Gateway's TTS (a local model on the Gateway
/// computer, `tts.speak`) through the keep-alive engine, so the audio session
/// is never touched while a DAT session is live (dat-ios #292).
///
/// Sentences are requested as soon as they arrive and played in order, so
/// the next clip renders while the current one plays. A clip that fails or
/// takes longer than `firstClipDeadline` turns the rest of the reply over to
/// the system voice (`fallback`), so a slow Gateway never leaves silence.
@MainActor
final class GatewayVoice {
    /// Renders one sentence; nil when the Gateway is not connected.
    var render: ((String) async throws -> OpenClawSpeechClip)?
    /// Plays a decoded buffer; calls back when it finished.
    var play: ((AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Bool)?
    /// The engine's output format for decoded clips.
    var outputFormat: (() -> AVAudioFormat?)?
    var onLog: ((String) -> Void)?

    static let firstClipDeadline: Duration = .milliseconds(1500)
    static let clipDeadline: Duration = .seconds(6)

    private struct Item {
        let text: String
        let clip: Task<AVAudioPCMBuffer?, Never>
    }

    private var queue: [Item] = []
    private var draining = false
    private var generation = 0
    private(set) var isBusy = false

    /// Enqueues a sentence. Returns false when the Gateway voice cannot be
    /// used at all (caller speaks it with the system voice).
    func enqueue(
        _ text: String,
        fallback: @escaping (String) async -> Void,
        finished: @escaping () -> Void,
        onIdle: @escaping () -> Void
    ) -> Bool {
        guard let render, play != nil, let outputFormat, let format = outputFormat() else { return false }
        let deadline = queue.isEmpty && !isBusy ? Self.firstClipDeadline : Self.clipDeadline
        let clip = Task<AVAudioPCMBuffer?, Never> {
            await Self.fetch(text, render: render, format: format, deadline: deadline)
        }
        queue.append(Item(text: text, clip: clip))
        isBusy = true
        if !draining { drain(fallback: fallback, finished: finished, onIdle: onIdle) }
        return true
    }

    func stop() {
        generation += 1
        for item in queue { item.clip.cancel() }
        queue.removeAll()
        draining = false
        isBusy = false
    }

    private func drain(
        fallback: @escaping (String) async -> Void,
        finished: @escaping () -> Void,
        onIdle: @escaping () -> Void
    ) {
        draining = true
        let current = generation
        Task { @MainActor in
            var fellBack = false
            while generation == current, !queue.isEmpty {
                let item = queue.removeFirst()
                let buffer = fellBack ? nil : await item.clip.value
                guard generation == current else { return }
                if let buffer, let play, await Self.playAndWait(buffer, play: play) {
                    finished()
                    continue
                }
                if !fellBack { onLog?("gateway voice unavailable — system voice for the rest of this reply") }
                fellBack = true
                await fallback(item.text)
            }
            guard generation == current else { return }
            draining = false
            isBusy = false
            onIdle()
        }
    }

    private static func playAndWait(
        _ buffer: AVAudioPCMBuffer,
        play: (AVAudioPCMBuffer, @escaping @Sendable () -> Void) -> Bool
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let started = play(buffer) { continuation.resume(returning: true) }
            if !started { continuation.resume(returning: false) }
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
