import Foundation
import Security

/// Keychain wrapper for sensitive auth secrets. Never prints values.
public enum KeychainHelper {
    private static let service = "com.ollacore.mac"

    @discardableResult
    public static func save(_ value: String, account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
        let add = q.merging([kSecValueData as String: data]) { $1 }
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    public static func read(account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(account: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }

    public static func clearAuth() {
        for a in ["session_token", "user_id", "room_token_cache"] { delete(account: a) }
    }
}

/// In-memory room-token cache. Room access tokens are short-lived secrets:
/// never written to UserDefaults, never logged.
public final class RoomTokenCache {
    public static let shared = RoomTokenCache()
    private static let expiryMargin: TimeInterval = 60
    private var cache: [String: (token: String, wsURL: String, rtcURL: String, expiresAt: Date?)] = [:]
    private let lock = NSLock()
    public func get(roomId: String, now: Date = Date()) -> (token: String, wsURL: String, rtcURL: String)? {
        lock.lock(); defer { lock.unlock() }
        guard let e = cache[roomId] else { return nil }
        // Expired tokens are treated as absent so callers re-mint instead of 401-looping.
        if let exp = e.expiresAt, now.addingTimeInterval(Self.expiryMargin) >= exp {
            cache.removeValue(forKey: roomId)
            return nil
        }
        return (e.token, e.wsURL, e.rtcURL)
    }
    public func set(roomId: String, token: String, wsURL: String, rtcURL: String, expiresAt: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        let exp = expiresAt.flatMap { ISO8601DateFormatter().date(from: $0) }
        cache[roomId] = (token, wsURL, rtcURL, exp)
    }
    public func clear() { lock.lock(); defer { lock.unlock() }; cache.removeAll() }
}
