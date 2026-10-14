import Foundation

public enum OpenClawSetupCodeError: Error, Sendable, Equatable {
    case malformed
    case expired
}

/// The pairing setup code printed or shown as a QR by `openclaw qr`
/// (base64url JSON, optionally prefixed `oc-pair://`). It carries the Gateway
/// URL and a short-lived single-use `bootstrapToken`, never the shared Gateway
/// token, so a host can pair without the user typing a credential.
public struct OpenClawSetupCode: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible {
    public let url: URL
    public let bootstrapToken: String
    public let expiresAt: Date?

    public init(_ input: String, now: Date = Date()) throws {
        var code = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "oc-pair://"
        if code.lowercased().hasPrefix(prefix) {
            code = String(code.dropFirst(prefix.count))
        }
        guard !code.isEmpty,
              code.unicodeScalars.allSatisfy({ Self.base64URLAlphabet.contains($0) }) else {
            throw OpenClawSetupCodeError.malformed
        }
        var base64 = code
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = (object["url"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: rawURL),
              ["ws", "wss"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.isEmpty == false,
              let token = (object["bootstrapToken"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            throw OpenClawSetupCodeError.malformed
        }

        if let rawExpiry = object["expiresAtMs"] {
            guard let millis = (rawExpiry as? NSNumber)?.int64Value, millis >= 0 else {
                throw OpenClawSetupCodeError.malformed
            }
            let expiry = Date(timeIntervalSince1970: TimeInterval(millis) / 1000)
            guard expiry > now else { throw OpenClawSetupCodeError.expired }
            expiresAt = expiry
        } else {
            expiresAt = nil
        }
        self.url = url
        bootstrapToken = token
    }

    public var description: String {
        "OpenClawSetupCode(url: \(url.absoluteString), bootstrapToken: <redacted>)"
    }

    public var debugDescription: String { description }

    private static let base64URLAlphabet = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
}
