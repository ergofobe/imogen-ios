import Foundation
import ImogenSDK

/// Where the operating system sends the browser back to. Registered in the Info.plist.
public let oauthRedirect = "imogen://oauth"

/// Just the scheme of it, which is what an authentication session is told to watch for.
/// Derived rather than written twice, so the two cannot drift apart.
public let oauthCallbackScheme = URL(string: oauthRedirect)?.scheme ?? "imogen"

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
    /// The record of the sign-in in progress could not be read back.
    ///
    /// Not `noPendingSignIn`: "nothing was waiting" sends somebody off to start a sign-in
    /// that was already there, and says nothing about the device that refused. The two
    /// end the same flow and are not the same news — the distinction #44 drew for the
    /// account book, applied to the one record it deliberately left alone.
    case pendingSignInUnreadable(any Error)
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .notAnInvitation: "That is not an imogen pairing code."
        case .noPendingSignIn: "There is no sign-in waiting for this callback."
        case .pendingSignInUnreadable(let error):
            // Nothing is lost, and saying so is the point: the authorization code in the
            // callback simply expires unspent, so starting again is a complete remedy
            // rather than a shrug.
            //
            // "With the device unlocked", not "try again": a retry while the keychain is
            // still refusing is refused at the *write* that starts the next sign-in, and
            // comes back as a bare status with no remedy in it at all.
            "The sign-in you started could not be read back from this device, so it "
                + "cannot be completed. \(LinkError.cause(error)) Nothing has been lost — "
                + "with the device unlocked, signing in again will work."
        case .server(let message): message
        }
    }

    /// Why the record could not be read, in words that fit the reason there is.
    ///
    /// A refusal and a record that will not decode are the same dead end and not the same
    /// cause. Saying "a device that was locked" over a `DecodingError` would be a wrong
    /// diagnosis of exactly the kind this case exists to stop — and Foundation's own words
    /// for that one ("isn't in the correct format") name nothing a person can act on.
    private static func cause(_ error: any Error) -> String {
        guard let keychain = error as? KeychainError else {
            return "The record of it was there but could not be understood."
        }
        let detail = keychain.errorDescription ?? ""
        // Only the statuses that actually mean a locked device get told they do. A
        // permanent refusal — a stored item that is not data, a decode failure in
        // Security itself — would otherwise send somebody to unlock a device that is
        // already unlocked. The remedy below still holds for it: the next attempt
        // replaces the record rather than reading this one.
        guard KeychainAccountStorage.isTransient(keychain.status) else {
            return "The device would not give it back. \(detail)"
        }
        return "A device that was still locked is the usual reason. \(detail)"
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
    private let pendingStore: any SecretStorage

    /// The keychain rather than user defaults: this holds a PKCE verifier, and a verifier
    /// is the only thing standing between an intercepted code and a token. Injectable so
    /// a test can refuse the read, which is the failure this record used to hide.
    public init(
        clientName: String,
        deviceName: String,
        pendingStore: any SecretStorage = Keychain(
            service: "com.imogen.ios", account: "pending-auth"
        )
    ) {
        self.clientName = clientName
        self.deviceName = deviceName
        self.pendingStore = pendingStore
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
        // No resource indicator, so the token stays good at every surface. Pairing
        // cannot bind one — its claim endpoint mints the code server-side and records
        // no resource — and an account added by browser answering differently from a
        // paired one would cost more than the narrower token is worth here today.
        let pending = try await oauth.beginAuthorization(
            clientId: registered.clientId, redirectURI: oauthRedirect, scopes: mobileScopes
        )

        // Loudly, and before the browser opens. A verifier that could not be stored means
        // the callback has nothing to come back to, and letting the sheet appear anyway
        // spends somebody's sign-in on a flow that was already lost.
        try remember(
            Pending(
                serverURL: serverURL,
                clientId: pending.clientId,
                codeVerifier: pending.codeVerifier,
                state: pending.state,
                redirectURI: pending.redirectURI,
                resource: pending.resource
            )
        )

        guard let url = URL(string: pending.authorizationURL) else {
            throw LinkError.server("The server gave an authorization URL that is not a URL.")
        }
        return url
    }

    /// Completes the browser flow from the callback the operating system delivered.
    public func completeBrowserSignIn(callback: String) async throws -> Account {
        let pending = try recall()

        let oauth = OAuthClient(baseURL: pending.serverURL)
        let stored = try await oauth.completeAuthorization(
            PendingAuthorization(
                authorizationURL: "",
                codeVerifier: pending.codeVerifier,
                state: pending.state,
                redirectURI: pending.redirectURI,
                clientId: pending.clientId,
                resource: pending.resource
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

    private func remember(_ pending: Pending) throws {
        guard let data = try? JSONEncoder().encode(pending) else {
            throw LinkError.server("Could not prepare the sign-in to be stored.")
        }
        try pendingStore.write(data)
    }

    /// The sign-in that is waiting, or a refusal that says which kind it is.
    ///
    /// The browser can come back while the device is locked, or during the keybag race at
    /// launch — and the callback arrives exactly then, because that is when the app is
    /// woken. Flattening that into "nothing was waiting" left the code unspent and the
    /// person with no idea why.
    private func recall() throws -> Pending {
        let stored: Data?
        do {
            stored = try pendingStore.read()
        } catch {
            throw LinkError.pendingSignInUnreadable(error)
        }
        // Only "there is nothing stored" is an absent sign-in. `Keychain.read` throws
        // every other refusal rather than flattening it to nil, which is what makes this
        // distinction available here at all.
        guard let stored else { throw LinkError.noPendingSignIn }

        do {
            return try JSONDecoder().decode(Pending.self, from: stored)
        } catch {
            // A record this build cannot decode is the same dead end as one it could not
            // read, and the same remedy: start again, and the next attempt overwrites it.
            throw LinkError.pendingSignInUnreadable(error)
        }
    }

    /// Not private, so its encoding can be tested: it is written before the browser opens
    /// and read back by whatever process comes after, which makes it a compatibility
    /// surface rather than a detail.
    struct Pending: Codable {
        let serverURL: String
        let clientId: String
        let codeVerifier: String
        let state: String
        let redirectURI: String
        /// Whatever the authorization request named, so the token request can name the
        /// same one. Optional in the decoder's sense too: a record written before this
        /// field existed decodes as an unbound sign-in rather than failing and stranding
        /// somebody mid-flow.
        let resource: String?
    }
}
