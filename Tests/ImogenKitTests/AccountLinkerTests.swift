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
