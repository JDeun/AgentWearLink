import XCTest

final class VoiceCatalogTests: XCTestCase {
    private let voices = [
        VoiceOption(id: "com.apple.voice.compact.ko-KR.Yuna", name: "Yuna", language: "ko-KR", quality: .standard, gender: .female),
        VoiceOption(id: "com.apple.voice.premium.ko-KR.Minsu", name: "Minsu", language: "ko-KR", quality: .premium, gender: .male),
        VoiceOption(id: "com.apple.voice.enhanced.ko-KR.Jian", name: "Jian", language: "ko-KR", quality: .enhanced, gender: .male),
        VoiceOption(id: "com.apple.voice.compact.en-US.Samantha", name: "Samantha", language: "en-US", quality: .standard, gender: .female),
        VoiceOption(id: "com.apple.speech.synthesis.voice.Bells", name: "Bells", language: "ko-KR", quality: .standard, gender: .unspecified),
    ]

    func testKeepsTheReplyLanguageBestQualityFirst() {
        XCTAssertEqual(VoiceCatalog.options(from: voices, language: "ko-KR").map(\.name), ["Minsu", "Jian", "Yuna"])
    }

    func testPrimarySubtagMatches() {
        XCTAssertEqual(VoiceCatalog.options(from: voices, language: "en").map(\.name), ["Samantha"])
    }

    func testStoredChoiceResolvesOnlyWhileInstalled() {
        let options = VoiceCatalog.options(from: voices, language: "ko-KR")
        XCTAssertEqual(VoiceCatalog.resolved("com.apple.voice.enhanced.ko-KR.Jian", in: options)?.name, "Jian")
        XCTAssertNil(VoiceCatalog.resolved("com.apple.voice.premium.ko-KR.Gone", in: options))
        XCTAssertNil(VoiceCatalog.resolved("", in: options))
    }

    func testEloquenceVoicesGetAGenderFromTheirName() {
        let eddy = VoiceOption(id: "com.apple.eloquence.ko-KR.Eddy", name: "Eddy", language: "ko-KR", quality: .standard, gender: .unspecified)
        let flo = VoiceOption(id: "com.apple.eloquence.ko-KR.Flo", name: "Flo", language: "ko-KR", quality: .standard, gender: .unspecified)
        XCTAssertEqual(VoiceCatalog.gender(for: eddy), .male)
        XCTAssertEqual(VoiceCatalog.gender(for: flo), .female)
    }
}
