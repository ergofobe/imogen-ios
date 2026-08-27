import Foundation

/// One signed-in account on one server.
///
/// The app is built around there being several of these, because a photo library on
/// hardware you control is usually not the only one you are in: a family server and a
/// personal one, or your own and the one a club runs. Switching between them should be a
/// tap, not a sign-out.
///
/// The identity is local and random rather than the server's user id: the same person on
/// two servers is two accounts here, and the same user id can legitimately appear twice.
public struct Account: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    /// Absolute, with no trailing slash. Everything the client does is built from it.
    public var serverURL: String
    public var userId: String
    public var email: String
    public var name: String
    /// Registered for this device through RFC 7591. Needed again on every refresh.
    public var clientId: String
    public var tokens: TokenSet
    /// Whether photographs taken on this device are copied here.
    public var backupEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        serverURL: String,
        userId: String,
        email: String,
        name: String,
        clientId: String,
        tokens: TokenSet,
        backupEnabled: Bool = false
    ) {
        self.id = id
        self.serverURL = serverURL
        self.userId = userId
        self.email = email
        self.name = name
        self.clientId = clientId
        self.tokens = tokens
        self.backupEnabled = backupEnabled
    }

    /// What to call the server when there is no better name than its address.
    public var serverLabel: String {
        URL(string: serverURL)?.host().map { host in
            URL(string: serverURL)?.port.map { "\(host):\($0)" } ?? host
        } ?? serverURL
    }
}

public struct TokenSet: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// Unix seconds. Expiry is computable without keeping the clock that read it.
    public var obtainedAt: Double
    public var expiresIn: Int
    public var scope: String

    public init(
        accessToken: String,
        refreshToken: String?,
        obtainedAt: Double,
        expiresIn: Int,
        scope: String
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.obtainedAt = obtainedAt
        self.expiresIn = expiresIn
        self.scope = scope
    }

    /// A minute of slack. A token that expires while a request is in flight costs a round
    /// trip and a retry; refreshing one a minute early costs nothing.
    public func isExpired(at now: Double, skewSeconds: Int = 60) -> Bool {
        now >= obtainedAt + Double(max(0, expiresIn - skewSeconds))
    }
}

/// Everything the app persists about accounts, in one document, because it is written as one.
public struct AccountBook: Codable, Hashable, Sendable {
    public var accounts: [Account]
    public var activeAccountId: String?

    public init(accounts: [Account] = [], activeAccountId: String? = nil) {
        self.accounts = accounts
        self.activeAccountId = activeAccountId
    }

    public var active: Account? {
        accounts.first { $0.id == activeAccountId } ?? accounts.first
    }

    public var backingUpTo: [Account] {
        accounts.filter(\.backupEnabled)
    }

    /// Adds an account, or replaces the one this device already has on that server.
    ///
    /// Signing in twice to the same account would otherwise leave two live grants and two
    /// rows saying the same thing, and backup would send everything to both of them.
    public mutating func upsert(_ account: Account) {
        var merged = account
        if let existing = accounts.first(where: {
            $0.serverURL == account.serverURL && $0.userId == account.userId
        }) {
            merged.id = existing.id
            merged.backupEnabled = existing.backupEnabled
            accounts.removeAll { $0.id == existing.id }
        }
        accounts.append(merged)
        activeAccountId = merged.id
    }

    public mutating func remove(id: String) {
        accounts.removeAll { $0.id == id }
        if activeAccountId == id { activeAccountId = accounts.first?.id }
    }

    public mutating func update(id: String, _ change: (inout Account) -> Void) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        change(&accounts[index])
    }
}

/// Turns what somebody typed into a URL.
///
/// People type `photos.example.com`, and a scheme is not something they should have to
/// think about. https, because a photo library reached over plain http is one whose
/// password crosses the network in the clear — except on a loopback address, which is
/// where somebody testing against a server on the same machine will be.
public func normalizeServerURL(_ input: String) -> String {
    var trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard !trimmed.isEmpty else { return trimmed }
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { return trimmed }

    let loopback = ["localhost", "127.0.0.1", "::1"]
    let host = trimmed.split(separator: ":").first.map(String.init) ?? trimmed
    return loopback.contains(host) ? "http://\(trimmed)" : "https://\(trimmed)"
}
