import XCTest
@testable import OllaCoreMac

// Mirrors Android unit tests: MimeValidatorTest, ForwardSecrecyManagerTest, MlsMessageHandlerTest.
// macOS equivalents: model decoding + API request building (no SIM_TOKEN in repo).

final class ModelsTests: XCTestCase {
    func testOtpVerifyResponseDecoding() throws {
        let d = Data(#"{"session_token":"s","user_id":"u","display_name":"QA1"}"#.utf8)
        let r = try JSONDecoder().decode(OtpVerifyResponse.self, from: d)
        XCTAssertEqual(r.session_token, "s"); XCTAssertEqual(r.user_id, "u")
    }
    func testMessageKinds() {
        XCTAssertEqual(MessageKinds.text, "text"); XCTAssertEqual(MessageKinds.location, "location")
    }
    func testApiError() throws {
        let d = Data(#"{"code":"invalid_otp","message":"bad code"}"#.utf8)
        let e = try JSONDecoder().decode(ApiError.self, from: d)
        XCTAssertEqual(e.code, "invalid_otp")
    }
    func testMessageDecodesWithoutAttachmentIds() throws {
        // Docs' message.created payload omits attachment_ids for plain text — must not drop.
        let d = Data(#"{"id":"m1","room_id":"r","sender_id":"u","kind":"text","body":{"text":"hi"},"created_at":"2026-01-01T00:00:00Z","event_seq":1}"#.utf8)
        let m = try JSONDecoder().decode(MessageResponse.self, from: d)
        XCTAssertEqual(m.attachment_ids, [])
    }
    func testRoomTokenDecodesWithoutIceServers() throws {
        let d = Data(#"{"access_token":"t","expires_at":"e","chat_websocket_url":"w","rtc_websocket_url":"c"}"#.utf8)
        let r = try JSONDecoder().decode(RoomTokenResponse.self, from: d)
        XCTAssertEqual(r.ice_servers.count, 0)
    }
    func testNestedBodyDecodes() throws {
        let d = Data(#"{"id":"m2","room_id":"r","sender_id":"u","kind":"location","body":{"lat":12.5,"label":"here","tags":["a"]},"created_at":"2026-01-01T00:00:00Z","event_seq":2,"attachment_ids":[]}"#.utf8)
        let m = try JSONDecoder().decode(MessageResponse.self, from: d)
        XCTAssertEqual(m.body["lat"]?.value as? Double, 12.5)
    }
}
