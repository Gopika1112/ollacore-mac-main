import XCTest
@testable import OllaCoreMac

/// Keychain + logout tests. Require macOS (Security framework). Never print stored values.
final class KeychainTests: XCTestCase {
    func testSaveRead() {
        XCTAssertTrue(KeychainHelper.save("v1", account: "test_acct_save"))
        XCTAssertEqual(KeychainHelper.read(account: "test_acct_save"), "v1")
        KeychainHelper.delete(account: "test_acct_save")
    }
    func testUpdate() {
        KeychainHelper.save("old", account: "test_acct_upd")
        KeychainHelper.save("new", account: "test_acct_upd")
        XCTAssertEqual(KeychainHelper.read(account: "test_acct_upd"), "new")
        KeychainHelper.delete(account: "test_acct_upd")
    }
    func testDelete() {
        KeychainHelper.save("x", account: "test_acct_del")
        KeychainHelper.delete(account: "test_acct_del")
        XCTAssertNil(KeychainHelper.read(account: "test_acct_del"))
    }
    @MainActor func testLogoutClearsSecrets() {
        let s = SessionStore()
        s.save(token: "t", userId: "u")
        RoomTokenCache.shared.set(roomId: "r", token: "rt", wsURL: "w", rtcURL: "c")
        s.clear()
        XCTAssertNil(KeychainHelper.read(account: "session_token"))
        XCTAssertNil(RoomTokenCache.shared.get(roomId: "r"))
        XCTAssertFalse(s.isAuthenticated)
    }
    func testNoSensitivePrefsInUserDefaults() {
        XCTAssertNil(UserDefaults.standard.string(forKey: "session_token"))
        XCTAssertNil(UserDefaults.standard.data(forKey: "room_token_cache"))
    }
}
