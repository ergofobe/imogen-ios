import Security
import XCTest

@testable import ImogenKit

/// The pending sign-in that survives the browser round trip.
///
/// It is written to the keychain before the browser opens and read back from a process
/// that may be a cold start, so its encoding is a compatibility surface with the app's own
/// past — the only one this target has.
final class PendingSignInCodingTests: XCTestCase {

    /// An update can land while somebody is in the browser. The pending record they left
    /// behind has no `resource` key, and a decode failure there would strand them at a
    /// callback with nothing to complete it — so absent has to mean "unbound", not "throw".
    func testAPendingSignInWrittenBeforeResourcesExistedStillDecodes() throws {
        let json = Data(
            """
            {"serverURL":"https://photos.example.com","clientId":"client-1",
             "codeVerifier":"verifier","state":"state","redirectURI":"imogen://oauth"}
            """.utf8
        )

        let pending = try JSONDecoder().decode(AccountLinker.Pending.self, from: json)

        XCTAssertNil(pending.resource)
        XCTAssertEqual(pending.codeVerifier, "verifier")
        XCTAssertEqual(pending.clientId, "client-1")
    }

    /// The reason the SDK gives `resource` no default: the authorization and the token
    /// request have to name the same one, and this record is the only thing carrying it
    /// across the redirect.
    func testAResourceSurvivesTheRoundTripThroughTheStore() throws {
        let pending = AccountLinker.Pending(
            serverURL: "https://photos.example.com",
            clientId: "client-1",
            codeVerifier: "verifier",
            state: "state",
            redirectURI: "imogen://oauth",
            resource: "https://photos.example.com/mcp"
        )

        let decoded = try JSONDecoder().decode(
            AccountLinker.Pending.self, from: JSONEncoder().encode(pending)
        )

        XCTAssertEqual(decoded.resource, "https://photos.example.com/mcp")
    }
}

/// Storage that refuses every read, which is what a locked device or the keybag race at
/// launch looks like from here. The real refusals cannot be provoked portably.
private struct RefusingSecretStorage: SecretStorage {
    let status: OSStatus

    init(_ status: OSStatus = errSecInteractionNotAllowed) { self.status = status }

    func read() throws -> Data? { throw KeychainError(status: status) }
    func write(_ data: Data) throws { throw KeychainError(status: status) }
    func delete() {}
}

private final class MemorySecretStorage: SecretStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?

    init(_ stored: Data? = nil) { self.stored = stored }

    func read() throws -> Data? { lock.withLock { stored } }
    func write(_ data: Data) throws { lock.withLock { stored = data } }
    func delete() { lock.withLock { stored = nil } }
}

/// What the app says when the browser comes back and the record it left behind cannot be
/// read. The callback arrives exactly when the device is most likely to refuse — the app
/// is being woken for it — so this is not a corner.
final class PendingSignInReadTests: XCTestCase {

    private func linker(_ pendingStore: any SecretStorage) -> AccountLinker {
        AccountLinker(clientName: "imogen tests", deviceName: "Test Runner", pendingStore: pendingStore)
    }

    private func failure(completing pendingStore: any SecretStorage) async -> Error? {
        do {
            _ = try await linker(pendingStore).completeBrowserSignIn(
                callback: "imogen://oauth?code=abc&state=state"
            )
            return nil
        } catch {
            return error
        }
    }

    /// The whole of #46. A refused read used to say there was nothing waiting, so the
    /// authorization code went unspent and nobody was told why.
    func testARefusedReadSaysSoRatherThanThatNothingWasWaiting() async throws {
        let error = await failure(completing: RefusingSecretStorage())

        guard case .pendingSignInUnreadable = error as? LinkError else {
            return XCTFail("expected an unreadable pending sign-in, got \(String(describing: error))")
        }
    }

    /// The other half has to keep working: a callback with genuinely nothing behind it —
    /// a stale link, a second tap — is still "no sign-in waiting", and errSecItemNotFound
    /// is the only refusal that means it.
    func testADeviceWithNothingStoredIsStillNoSignInWaiting() async throws {
        let error = await failure(completing: MemorySecretStorage())

        guard case .noPendingSignIn = error as? LinkError else {
            return XCTFail("expected no pending sign-in, got \(String(describing: error))")
        }
    }

    /// A record that will not decode is the same dead end as one that could not be read,
    /// and the same remedy — not an empty result that ends the flow in silence.
    func testARecordThatCannotBeDecodedIsUnreadableRatherThanAbsent() async throws {
        let error = await failure(
            completing: MemorySecretStorage(Data("not a pending sign-in".utf8))
        )

        guard case .pendingSignInUnreadable = error as? LinkError else {
            return XCTFail("expected an unreadable pending sign-in, got \(String(describing: error))")
        }
        // The same dead end as a refusal, and not the same cause. Blaming a locked device
        // for a record that will not decode is the wrong diagnosis this case exists to
        // stop being given.
        let message = try XCTUnwrap((error as? LinkError)?.localizedDescription)
        XCTAssertFalse(message.contains("locked is the usual reason"))
        XCTAssertTrue(message.contains("could not be understood"))
    }

    /// Nothing is lost when this happens — the code in the callback expires unspent — so
    /// the message says so, and says what the device's refusal was while it is at it.
    func testTheMessageOffersTheRemedyAndCarriesWhatTheKeychainSaid() async throws {
        let error = await failure(completing: RefusingSecretStorage(errSecMissingEntitlement))
        let message = try XCTUnwrap((error as? LinkError)?.localizedDescription)

        XCTAssertTrue(message.contains("signing in again will work"))
        XCTAssertTrue(message.contains("-34018"))
        XCTAssertNotEqual(message, LinkError.noPendingSignIn.localizedDescription)
    }
}
