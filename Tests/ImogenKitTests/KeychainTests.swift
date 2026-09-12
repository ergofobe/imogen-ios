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


    /// The whole of the bug: any refusal used to fall through to `SecItemAdd`, whose
    /// errSecDuplicateItem then stood in for whatever actually went wrong. A locked
    /// device is the commonest refusal and the one on every token refresh, so the status
    /// it reported was wrong exactly when somebody needed it.
    func testARefusedUpdateIsRaisedRatherThanRetriedAsAnInsert() {
        XCTAssertThrowsError(
            try Keychain.insertIsNext(afterUpdate: errSecInteractionNotAllowed)
        ) { error in
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecInteractionNotAllowed))
        }
    }

    func testNothingStoredYetIsTheOneCaseThatInserts() throws {
        XCTAssertTrue(try Keychain.insertIsNext(afterUpdate: errSecItemNotFound))
        XCTAssertFalse(try Keychain.insertIsNext(afterUpdate: errSecSuccess))
    }

    /// The encode was `try?`, so a book that would not serialise returned as though it
    /// had been written — and the store then cleared its own warning. A save that cannot
    /// save has to say so, whichever half of it failed.
    func testABookThatCannotBeEncodedIsARefusalRatherThanASilentNoOp() {
        let storage = KeychainAccountStorage(
            service: "com.imogen.tests", account: "case-\(UUID().uuidString)"
        )
        let unserialisable = TokenSet(
            accessToken: "at", refreshToken: nil, obtainedAt: .nan, expiresIn: 3600, scope: ""
        )
        let account = Account(
            serverURL: "https://a.example.com", userId: "u", email: "u@example.com",
            name: "u", clientId: "c", tokens: unserialisable
        )

        XCTAssertThrowsError(try storage.save(AccountBook(accounts: [account])))
    }
}
