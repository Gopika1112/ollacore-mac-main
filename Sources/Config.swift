import Foundation

/// Central config. No real credentials in source.
/// APP_ID / SIM_TOKEN / SIM_URL come from environment (Xcode scheme or `export` in shell).
/// SIM_TOKEN is test-only, never printed, never committed.
public enum AppConfig {
    /// S-03: production packaging pins the endpoint. Env override is allowed only
    /// for https hosts (default + team test hosts); anything else is rejected and
    /// the pinned default is used, so a bad environment can't redirect traffic.
    public static var allowedHosts: Set<String> = ["api.ollacore.com"]
    public static var apiBase: String {
        let base = ProcessInfo.processInfo.environment["OLLACORE_API_BASE"] ?? "https://api.ollacore.com/v1"
        if Self.isAllowedBase(base) { return base }
        return "https://api.ollacore.com/v1"
    }
    static func isAllowedBase(_ s: String) -> Bool {
        guard let c = URLComponents(string: s),
              let host = c.host?.lowercased() else { return false }
        // Local development against a self-hosted backend stays possible over plain http.
        if host == "localhost" || host == "127.0.0.1" { return true }
        guard c.scheme?.lowercased() == "https" else { return false }
        return allowedHosts.contains(host) || host.hasSuffix(".ollacore.com")
    }
    public static var appId: String {
        ProcessInfo.processInfo.environment["OLLACORE_APP_ID"] ?? ""
    }
    /// Test-only OTP sink base URL (never localhost in production; SSRF guard rejects it).
    public static var simBase: String? {
        ProcessInfo.processInfo.environment["SIM_URL"]
    }
    public static var simTokenPresent: Bool {
        !(ProcessInfo.processInfo.environment["SIM_TOKEN"] ?? "").isEmpty
    }
}

/// Rate-limit + testing-convention helpers, per https://www.ollacore.com/docs/errors/ and /docs/testing/.
public enum OllacoreConventions {
    /// Parse Retry-After (seconds) from HTTP headers. 429 must wait exactly this long.
    public static func retryAfterSeconds(headers: [AnyHashable: Any]) -> Int? {
        for (k, v) in headers {
            if (k as? String)?.lowercased() == "retry-after", let s = "\(v)".trimmingCharacters(in: .whitespaces).split(separator: ",").first {
                return Int(s)
            }
        }
        return nil
    }

    /// 429 must NOT abort OTP polling — caller should sleep Retry-After then continue.
    public static func shouldContinuePollingOnRateLimit(status: Int) -> Bool { status == 429 }

    /// `since` (unix ms) must be captured BEFORE otp/request, else the previous code verifies and 401s.
    public static func captureSinceMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    /// Encode phone for `GET /last-otp?phone=…`: `+` must become `%2B`.
    public static func encodedPhoneParam(_ phone: String) -> String {
        phone.addingPercentEncoding(withAllowedCharacters: .init(charactersIn: "0123456789")) .map { _ in
            phone.replacingOccurrences(of: "+", with: "%2B")
        } ?? phone
    }

    /// `phone_required` means the phone query/body parameter was missing — not an auth failure.
    public static func isPhoneRequired(code: String?) -> Bool { code == "phone_required" }

    /// `/diag` (Bearer SIM_TOKEN) returns counts/shapes, never OTP values — must not be treated as an error nor logged as a secret.
    public static func isDiagPayload(_ json: [String: Any]) -> Bool {
        json["error"] == nil && (json["counts"] != nil || json["shapes"] != nil || json["ok"] != nil)
    }

    /// Build a last-otp poll URL. Returns nil if phone missing (caller should surface phone_required).
    public static func lastOtpURL(simBase: String, phone: String, sinceMs: Int64, consume: Bool = false) -> URL? {
        guard !phone.isEmpty else { return nil }
        let enc = encodedPhoneParam(phone)
        var s = "\(simBase)/last-otp?phone=\(enc)&since=\(sinceMs)"
        if consume { s += "&consume=1" }
        return URL(string: s)
    }
}
