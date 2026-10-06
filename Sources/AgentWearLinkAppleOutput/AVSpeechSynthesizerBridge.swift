#if canImport(AVFoundation)
import AVFoundation
import Foundation

/// Native Apple speech implementation for the iOS reference host.
///
/// AVSpeechSynthesizer is intentionally isolated behind SpeechSynthesizing so
/// Core and non-Apple adapters never depend on AVFoundation.
public actor AVSpeechSynthesizerBridge: SpeechSynthesizing {
    private let synthesizer = AVSpeechSynthesizer()
    private let language: String?

    public init(language: String? = nil) {
        self.language = language
    }

    public func speak(_ text: String) async {
        guard !text.isEmpty else { return }
        let utterance = AVSpeechUtterance(string: text)
        if let language {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        synthesizer.speak(utterance)
    }

    public func stop() async {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
#endif
