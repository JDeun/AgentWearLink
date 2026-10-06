import Foundation
import AgentWearLinkCore

struct OpenClawChatRequest: Encodable {
    struct Message: Encodable {
        let role: String
        let content: String
    }

    let model: String
    let user: String
    let stream: Bool
    let messages: [Message]
}

struct OpenClawChatChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: String?
        }

        let delta: Delta
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    let choices: [Choice]
}

enum OpenClawSSEEvent: Equatable {
    case delta(String)
    case done
    case ignored
}

enum OpenClawSSEParser {
    static func parse(
        line: String,
        maximumEventBytes: Int
    ) throws -> OpenClawSSEEvent {
        guard line.hasPrefix("data:") else {
            return .ignored
        }

        let payload = line
            .dropFirst("data:".count)
            .trimmingCharacters(in: .whitespaces)

        guard !payload.isEmpty else { return .ignored }

        guard payload.utf8.count <= maximumEventBytes else {
            throw AWLError.transport("SSE event exceeds configured byte limit")
        }

        if payload == "[DONE]" {
            return .done
        }

        guard let data = payload.data(using: .utf8) else {
            throw AWLError.agent("invalid UTF-8 SSE payload")
        }

        let chunk: OpenClawChatChunk
        do {
            chunk = try JSONDecoder().decode(OpenClawChatChunk.self, from: data)
        } catch {
            throw AWLError.agent("invalid OpenClaw streaming payload")
        }

        let text = chunk.choices
            .compactMap { $0.delta.content }
            .joined()

        return text.isEmpty ? .ignored : .delta(text)
    }
}
