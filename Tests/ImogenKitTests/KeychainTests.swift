import XCTest

@testable import ImogenKit

/// A keychain write that fails without saying so is what turned a broken sign-in into
/// "there is no sign-in waiting for this callback" — an error naming the wrong thing
/// entirely, and pointing away from the cause.
final class KeychainTests: XCTestCase {

    private func keychain() -> Keychain {
        Keychain(service: "com.imogen.tests", account: "case-\(UUID().uuidString)")
    }

    func testWritingThenReadingReturnsWhatWasWritten() throws {
        let keychain = self.keychain()
        defer { keychain.delete() }

        try keychain.write(Data("verifier".utf8))

        XCTAssertEqual(keychain.read(), Data("verifier".utf8))
    }

    func testWritingTwiceReplacesRatherThanFailing() throws {
        let keychain = self.keychain()
        defer { keychain.delete() }

        try keychain.write(Data("first".utf8))
        try keychain.write(Data("second".utf8))

        // The update path is the one that runs on every token refresh, so a second write
        // that silently kept the first would strand an account on a stale token.
        XCTAssertEqual(keychain.read(), Data("second".utf8))
    }

    func testReadingWhatWasNeverWrittenIsNil() {
        XCTAssertNil(keychain().read())
    }

    func testDeletingRemovesIt() throws {
        let keychain = self.keychain()

        try keychain.write(Data("verifier".utf8))
        keychain.delete()

        XCTAssertNil(keychain.read())
    }

    func testTheErrorCarriesTheStatusThatExplainsIt() {
        let failure = KeychainError(status: errSecMissingEntitlement)

        XCTAssertEqual(failure.status, errSecMissingEntitlement)
        // The status is the whole point: -34018 on a simulator build without entitlements
        // is a different problem from a locked device, and the old code could say neither.
        XCTAssertEqual(failure.errorDescription?.contains("-34018"), true)
    }

    func testTheErrorReadsAsSomethingAPersonCanActOn() {
        let failure = KeychainError(status: errSecMissingEntitlement)

        XCTAssertEqual(failure.errorDescription?.isEmpty, false)
        XCTAssertNotEqual(failure.errorDescription, "The operation couldn\u{2019}t be completed.")
    }

}
