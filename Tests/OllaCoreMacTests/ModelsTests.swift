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
}
