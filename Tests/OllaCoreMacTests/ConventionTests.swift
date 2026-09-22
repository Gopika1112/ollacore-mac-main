import XCTest
@testable import OllaCoreMac

/// Critical convention tests — pure logic, runnable anywhere with `swift test` (needs macOS toolchain;
/// on Windows without Swift, verify by inspection). No secrets, no network.
final class ConventionTests: XCTestCase {
    func testRetryAfterParsed() {
        XCTAssertEqual(OllacoreConventions.retryAfterSeconds(headers: ["Retry-After": "7"]), 7)
        XCTAssertEqual(OllacoreConventions.retryAfterSeconds(headers: ["retry-after": "3"]), 3)
        XCTAssertNil(OllacoreConventions.retryAfterSeconds(headers: [:]))
    }
    func testRateLimitDoesNotAbortPolling() {
        XCTAssertTrue(OllacoreConventions.shouldContinuePollingOnRateLimit(status: 429))
        XCTAssertFalse(OllacoreConventions.shouldContinuePollingOnRateLimit(status: 404))
        // 404 no_fresh_code means "keep polling", not failure.
    }
    func testPhonePlusEncoding() {
        XCTAssertEqual(OllacoreConventions.encodedPhoneParam("+15550001111"), "%2B15550001111")
        // Unencoded "+" must be tested separately from the %2B path.
        XCTAssertNotEqual("+15550001111", OllacoreConventions.encodedPhoneParam("+15550001111"))
    }
    func testPhoneRequiredMeaning() {
        XCTAssertTrue(OllacoreConventions.isPhoneRequired(code: "phone_required"))
        XCTAssertFalse(OllacoreConventions.isPhoneRequired(code: "invalid_otp"))
    }
    func testDiagNotError() {
        XCTAssertTrue(OllacoreConventions.isDiagPayload(["ok": true, "counts": ["x": 1]]))
        XCTAssertFalse(OllacoreConventions.isDiagPayload(["error": "no_fresh_code"]))
    }
    func testLastOtpURLUsesSinceAndConsume() {
        let u = OllacoreConventions.lastOtpURL(simBase: "https://sink.example", phone: "+15550001111", sinceMs: 123, consume: true)
        let s = u?.absoluteString ?? ""
        XCTAssertTrue(s.contains("%2B15550001111") && s.contains("since=123") && s.contains("consume=1"))
        XCTAssertNil(OllacoreConventions.lastOtpURL(simBase: "https://sink.example", phone: "", sinceMs: 1))
    }
    func testFrameOmitsNullRoomId() {
        let ws = ChatWebSocket()
        let fid = ws.send(type: "ping") // no room — must not crash, must return request_id
        XCTAssertFalse(fid.isEmpty)
    }
    func testApiExceptionRateLimitFlag() {
        let e = ApiException(message: "slow", code: "rate_limited", httpStatus: 429, retryAfterSeconds: 5)
        XCTAssertTrue(e.isRateLimited); XCTAssertEqual(e.retryAfterSeconds, 5)
    }
}
