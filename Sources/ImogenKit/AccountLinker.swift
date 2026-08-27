import Foundation
import ImogenSDK

/// Where the operating system sends the browser back to. Registered in the Info.plist.
public let oauthRedirect = "imogen://oauth"

/// What the app asks for.
///
/// Not everything: an administrator's tools stay behind a browser session, deliberately,
/// so a lost phone is not a lost server.
public let mobileScopes = [
    "library:read", "library:write", "albums:read", "albums:write", "profile",
]

public enum LinkError: Error, LocalizedError {
    case notAnInvitation
    case noPendingSignIn
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notAnInvitation: "That is not an imogen pairing code."
        case .noPendingSignIn: "There is no sign-in waiting for this callback."
        case .server(let message): message
        }
    }
}

/// Adding an account, by either of the two routes.
///
/// Pairing is the one people should use: the browser they are already signed in to knows
/// the address and hands it over with the grant. The manual route exists because somebody
/// will want to install the app before they have a browser session anywhere, and because a
/// feature that only works one way is a feature that strands people.
public struct AccountLinker: Sendable {
    private let clientName: String
    private let deviceName: String
    private let pendingStore: Keychain

    public init(clientName: String, deviceName: String) {
        self.clientName = clientName
        self.deviceName = deviceName
        // The keychain rather than user defaults: this holds a PKCE verifier, and a
        // verifier is the only thing standing between an intercepted code and a token.
        self.pendingStore = Keychain(service: "com.imogen.ios", account: "pending-auth")
    }

    public func invitation(from scanned: String) -> PairingInvitation? {
        PairingInvitation(scanned: scanned)
    }

    /// The whole pairing sequence. Registers a client for this device, spends the code,
    /// and comes back with an account ready to use.
    public func pair(_ invitation: PairingInvitation) async throws -> Account {
        let oauth = OAuthClient(baseURL: invitation.serverURL)
        let paired = try await oauth.pair(
            pairingCode: invitation.code,
            clientName: clientName,
            redirectURI: oauthRedirect,
            deviceName: deviceName,
            scopes: mobileScopes
        )

        return try await finish(
            serverURL: invitation.serverURL,
            clientId: paired.clientId,
            tokens: TokenSet(
                accessToken: paired.tokens.tokens.accessToken,
                refreshToken: paired.tokens.tokens.refreshToken,
                obtainedAt: paired.tokens.obtainedAt,
                expiresIn: paired.tokens.tokens.expiresIn,
                scope: paired.scope
            )
        )
    }

    /// Begins the browser flow for a server somebody typed in. Returns the URL to open;
    /// everything needed to complete the exchange is held until the redirect comes back.
    ///
    /// Held in the keychain rather than in memory: the browser sheet is another process,
    /// and this one can be jettisoned while it is in front. A verifier lost that way turns
    /// into "nothing happened", which is the least debuggable failure there is.
    public func beginBrowserSignIn(server input: String) async throws -> URL {
        let serverURL = normalizeServerURL(input)
        let oauth = OAuthClient(baseURL: serverURL)
        let registered = try await oauth.register(
            name: clientName, redirectURIs: [oauthRedirect], scopes: mobileScopes
        )
        let pending = try await oauth.beginAuthorization(
            clientId: registered.clientId, redirectURI: oauthRedirect, scopes: mobileScopes
        )

        remember(
            Pending(
                serverURL: serverURL,
                clientId: pending.clientId,
                codeVerifier: pending.codeVerifier,
                state: pending.state,
                redirectURI: pending.redirectURI
            )
        )

        guard let url = URL(string: pending.authorizationURL) else {
            throw LinkError.server("The server gave an authorization URL that is not a URL.")
        }
        return url
    }

    /// Completes the browser flow from the callback the operating system delivered.
    public func completeBrowserSignIn(callback: String) async throws -> Account {
        guard let pending = recall() else { throw LinkError.noPendingSignIn }

        let oauth = OAuthClient(baseURL: pending.serverURL)
        let stored = try await oauth.completeAuthorization(
            PendingAuthorization(
                authorizationURL: "",
                codeVerifier: pending.codeVerifier,
                state: pending.state,
                redirectURI: pending.redirectURI,
                clientId: pending.clientId
            ),
            callbackURL: callback
        )
        pendingStore.delete()

        return try await finish(
            serverURL: pending.serverURL,
            clientId: pending.clientId,
            tokens: TokenSet(
                accessToken: stored.tokens.accessToken,
                refreshToken: stored.tokens.refreshToken,
                obtainedAt: stored.obtainedAt,
                expiresIn: stored.tokens.expiresIn,
                scope: stored.tokens.scope ?? ""
            )
        )
    }

    private func finish(
        serverURL: String, clientId: String, tokens: TokenSet
    ) async throws -> Account {
        // Who this is has to come from the server: the token says nothing about it, and an
        // account list showing "Account 2" would be useless the moment there are two.
        let client = ImogenClient(baseURL: serverURL, token: tokens.accessToken)
        let user = try await client.auth.me()

        return Account(
            serverURL: serverURL,
            userId: user.id,
            email: user.email,
            name: user.name,
            clientId: clientId,
            tokens: tokens
        )
    }

    private func remember(_ pending: Pending) {
        guard let data = try? JSONEncoder().encode(pending) else { return }
        pendingStore.write(data)
    }

    private func recall() -> Pending? {
        guard let data = pendingStore.read() else { return nil }
        return try? JSONDecoder().decode(Pending.self, from: data)
    }

    private struct Pending: Codable {
        let serverURL: String
        let clientId: String
        let codeVerifier: String
        let state: String
        let redirectURI: String
    }
}
