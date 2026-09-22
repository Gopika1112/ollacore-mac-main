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
    private var cache: [String: (token: String, wsURL: String, rtcURL: String)] = [:]
    private let lock = NSLock()
    public func get(roomId: String) -> (token: String, wsURL: String, rtcURL: String)? {
        lock.lock(); defer { lock.unlock() }; return cache[roomId]
    }
    public func set(roomId: String, token: String, wsURL: String, rtcURL: String) {
        lock.lock(); defer { lock.unlock() }; cache[roomId] = (token, wsURL, rtcURL)
    }
    public func clear() { lock.lock(); defer { lock.unlock() }; cache.removeAll() }
}
