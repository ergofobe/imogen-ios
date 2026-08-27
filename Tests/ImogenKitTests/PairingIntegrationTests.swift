import ImogenSDK
import XCTest

@testable import ImogenKit

/// The pairing sequence, against a real server.
///
/// Everything else in this suite is arithmetic and can be checked anywhere. This cannot:
/// pairing is four requests that have to agree with each other and with the server —
/// dynamic registration, the claim, the token exchange, and then actually using what comes
/// out — and a mock of that would only prove the mock agrees with itself.
///
/// Skipped unless `IMOGEN_TEST_SERVER` is set, so an ordinary `swift test` needs nothing:
///
/// ```
/// IMOGEN_TEST_SERVER=http://127.0.0.1:3100 \
/// IMOGEN_TEST_EMAIL=tester@example.com \
/// IMOGEN_TEST_PASSWORD=… swift test
/// ```
final class PairingIntegrationTests: XCTestCase {

    private var server: String?
    private var email: String = ""
    private var password: String = ""

    override func setUp() {
        super.setUp()
        let environment = ProcessInfo.processInfo.environment
        server = environment["IMOGEN_TEST_SERVER"]
        email = environment["IMOGEN_TEST_EMAIL"] ?? ""
        password = environment["IMOGEN_TEST_PASSWORD"] ?? ""
    }

    /// The whole thing, exactly as the app runs it: a browser makes a ticket, and a device
    /// that knows nothing turns it into an account.
    func testPairingProducesAUsableAccount() async throws {
        let server = try require()

        let ticket = try await makeTicket(on: server)
        let invitation = try XCTUnwrap(PairingInvitation(scanned: ticket.uri))
        XCTAssertEqual(invitation.serverURL, server)

        let linker = AccountLinker(clientName: "imogen tests", deviceName: "Test Runner")
        let account = try await linker.pair(invitation)

        XCTAssertEqual(account.serverURL, server)
        XCTAssertEqual(account.email, email)
        XCTAssertFalse(account.tokens.accessToken.isEmpty)
        // Without a refresh token the account is good for an hour and then gone.
        XCTAssertNotNil(account.tokens.refreshToken)

        // The grant has to be worth something: the point of pairing is a working client,
        // not a token that decodes.
        let session = Session(account: account) { _, _ in }
        let stats = try await session.client.assets.stats()
        XCTAssertGreaterThanOrEqual(stats.assetCount, 0)
    }

    /// A ticket is single-use. The second attempt must fail, or a photographed QR code is
    /// a permanent key rather than a one-time one.
    func testATicketCannotBeSpentTwice() async throws {
        let server = try require()

        let ticket = try await makeTicket(on: server)
        let invitation = try XCTUnwrap(PairingInvitation(scanned: ticket.uri))
        let linker = AccountLinker(clientName: "imogen tests", deviceName: "Test Runner")

        _ = try await linker.pair(invitation)

        do {
            _ = try await linker.pair(invitation)
            XCTFail("a spent pairing code was accepted a second time")
        } catch {
            // Any refusal will do; what matters is that it is one.
        }
    }

    func testAnInventedCodeIsRefused() async throws {
        let server = try require()

        let linker = AccountLinker(clientName: "imogen tests", deviceName: "Test Runner")
        let invitation = PairingInvitation(
            serverURL: server, code: "imog_pair_not-a-real-code"
        )

        do {
            _ = try await linker.pair(invitation)
            XCTFail("an invented pairing code was accepted")
        } catch {}
    }

    /// The timeline endpoint is what the grid's whole design rests on, so it is worth
    /// checking that a real server's answer indexes the way the arithmetic assumes.
    func testTheDayIndexAgreesWithTheServer() async throws {
        let server = try require()

        let ticket = try await makeTicket(on: server)
        let invitation = try XCTUnwrap(PairingInvitation(scanned: ticket.uri))
        let linker = AccountLinker(clientName: "imogen tests", deviceName: "Test Runner")
        let session = Session(account: try await linker.pair(invitation)) { _, _ in }

        let timeline = try await session.client.assets.timeline()
        let index = TimelineIndex(buckets: timeline.buckets)
        let stats = try await session.client.assets.stats()

        // The index's total is what sizes the grid. If it disagrees with the library, the
        // scrollbar is lying and the scrubber lands in the wrong place.
        XCTAssertEqual(index.photoCount, stats.assetCount)

        guard index.dayCount > 1 else { return }

        // Every photograph position maps back into the day it came from.
        for photo in [0, index.photoCount / 2, index.photoCount - 1] {
            let day = index.day(ofPhoto: photo)
            XCTAssertTrue(photo >= index.firstPhoto(ofDay: day))
            XCTAssertTrue(photo < index.firstPhoto(ofDay: day) + index.count(ofDay: day))
        }

        // And fetching one day returns exactly the number the index promised.
        let day = index.dayCount / 2
        let bounds = dayBounds(index.date(ofDay: day))
        let page = try await session.client.assets.list(
            AssetQuery(limit: 500, takenAfter: bounds.after, takenBefore: bounds.before)
        )
        XCTAssertEqual(page.items.count, index.count(ofDay: day))
    }

    // MARK: - Helpers

    private func require() throws -> String {
        guard let server, !email.isEmpty, !password.isEmpty else {
            throw XCTSkip("Set IMOGEN_TEST_SERVER, IMOGEN_TEST_EMAIL and IMOGEN_TEST_PASSWORD")
        }
        return server
    }

    /// What the web interface does: sign in, then ask for a ticket.
    private func makeTicket(on server: String) async throws -> PairingTicket {
        // Its own session, so the cookie jar is not shared with anything else.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        let http = URLSession(configuration: configuration)

        var login = URLRequest(url: URL(string: "\(server)/api/v1/auth/login")!)
        login.httpMethod = "POST"
        login.setValue("application/json", forHTTPHeaderField: "Content-Type")
        login.httpBody = try JSONEncoder().encode(
            LoginRequest(email: email, password: password)
        )
        let (_, loginResponse) = try await http.data(for: login)
        let loginStatus = (loginResponse as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(loginStatus, 200, "could not sign in to the test server")

        var make = URLRequest(url: URL(string: "\(server)/api/v1/pairing")!)
        make.httpMethod = "POST"
        let (data, response) = try await http.data(for: make)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        XCTAssertEqual(status, 201, "could not make a pairing ticket")

        return try JSONDecoder().decode(PairingTicket.self, from: data)
    }
}

extension PairingInvitation {
    /// For the invented-code case, which has no URI to parse.
    fileprivate init(serverURL: String, code: String) {
        self.init(scanned: "imogen://pair?server=\(serverURL)&code=\(code)")!
    }
}
