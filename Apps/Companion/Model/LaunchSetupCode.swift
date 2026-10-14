import Foundation

/// USB pairing: `Tools/install-and-pair.sh` launches the app from the gateway
/// computer with `-AWLSetupCode <code>`. Launch arguments are volatile (never
/// written to defaults) and only developer tools on a connected, trusted
/// computer can set them.
enum LaunchSetupCode {
    static let flag = "-AWLSetupCode"

    static func value(in arguments: [String]) -> String? {
        LaunchArgument.value(flag, in: arguments)
    }
}

/// Settings the install script can hand over from the gateway computer, so
/// nothing long has to be typed on the phone.
enum LaunchArgument {
    static let sessionKey = "-AWLSessionKey"
    static let telegramChatID = "-AWLTelegramChatID"

    static func value(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        let code = arguments[index + 1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, !code.hasPrefix("-") else { return nil }
        return code
    }
}
