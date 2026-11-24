import XCTest

final class VisionIntentTests: XCTestCase {
    func testKoreanVisualRequests() {
        for request in [
            "이거 뭐야?", "이거 뭐야", "이건 뭐지", "이게 뭐지?", "이거 봐줘", "이것 좀 봐줘", "저거 뭐야",
            "뭐가 보여?", "지금 뭐가 보여", "이거 읽어줘", "이것 좀 읽어 줘", "읽어줘", "좀 읽어줘", "봐줘",
            "이거 얼마야?", "이게 무슨 뜻이야", "이거 먹어도 돼?", "저 건물 이름이 뭐야? 내 앞에 있는 거",
            "사진 찍어서 알려줘", "눈앞에 있는 게 뭐야", "요거 어때", "이거 뭐야 진짜",
        ] {
            XCTAssertTrue(VisionIntent.needsPhoto(request), request)
        }
    }

    func testKoreanNonVisualRequests() {
        for request in [
            "오늘 일정 뭐야", "메일 읽어줘", "날씨 봐줘", "일정 좀 봐줘", "내일 날씨 어때",
            "이거 취소해줘", "내일이거든 알려줘", "지금 몇 시야", "문자 읽어줘", "음악 틀어줘",
            "이번 주 일정 알려줘", "", "  ",
        ] {
            XCTAssertFalse(VisionIntent.needsPhoto(request), request)
        }
    }

    func testEnglishVisualRequests() {
        for request in [
            "What is this?", "what's this", "What’s that?", "look at this", "Look at that and tell me",
            "What do you see?", "what am I looking at", "read this", "Read this for me", "Can you see this?",
            "take a photo", "how much is this?", "what is this thing", "what's this called", "is this safe to eat",
        ] {
            XCTAssertTrue(VisionIntent.needsPhoto(request), request)
        }
    }

    func testEnglishNonVisualRequests() {
        for request in [
            "what's this week's schedule", "what is this month's budget", "read my email",
            "is that right", "what is the weather", "what is that meeting about",
        ] {
            XCTAssertFalse(VisionIntent.needsPhoto(request), request)
        }
    }

    func testReasonIsAStableCategory() {
        XCTAssertEqual(VisionIntent.reason(for: "이거 뭐야"), .demonstrative)
        XCTAssertEqual(VisionIntent.reason(for: "뭐가 보여"), .seeingPhrase)
        XCTAssertEqual(VisionIntent.reason(for: "읽어줘"), .bareLookOrRead)
        XCTAssertEqual(VisionIntent.reason(for: "what is this"), .english)
        XCTAssertNil(VisionIntent.reason(for: "오늘 일정 뭐야"))
    }
}
