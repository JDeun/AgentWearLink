/// Gateway error.code originates outside the trust boundary. Never echo an
/// arbitrary provider/session/credential string into error descriptions or
/// exported diagnostics; retain only verified protocol categories.
enum OpenClawGatewayErrorCodePolicy {
    private static let allowed: Set<String> = [
        "AUTH_FAILED", "DEVICE_TOKEN_REJECTED", "PAIRING_REQUIRED",
        "BUSY", "INVALID_REQUEST", "UNAUTHORIZED", "FORBIDDEN",
        "RATE_LIMITED", "UNAVAILABLE", "TIMEOUT", "RUN_NOT_FOUND"
    ]

    static func safeCode(_ code: String?) -> String {
        guard let code, allowed.contains(code) else { return "UNKNOWN" }
        return code
    }
}
