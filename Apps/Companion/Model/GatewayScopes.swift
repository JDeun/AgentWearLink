import Foundation

/// Operator scopes the companion asks the Gateway for.
///
/// Read+write is enough for glasses turns. `operator.admin` is opt-in
/// ("관리자 권한(대화 공유)"): it makes glasses turns owner turns, so they get
/// the same tool set as the owner's Telegram turns and reuse that agent
/// thread, but the token it unlocks can also change the Gateway's config and
/// run commands. Off again, the next connect asks for read+write only.
public enum GatewayScopes {
    public static let read = "operator.read"
    public static let write = "operator.write"
    public static let admin = "operator.admin"

    public static func requested(adminEnabled: Bool) -> [String] {
        adminEnabled ? [read, write, admin] : [read, write]
    }
}
