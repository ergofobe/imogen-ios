import Foundation
import ImogenSDK

/// One account, ready to use: a client that authenticates itself, and a way to fetch
/// image bytes with the same credentials.
///
/// The refresh lives here rather than in a screen because every screen would otherwise
/// need to know about it. A request that comes back 401 asks this for a new token and is
/// sent again exactly once; a token already known to be stale is replaced before the
/// request goes out at all.
public actor Session {
    public nonisolated let accountId: String
    public nonisolated let serverURL: String

    private var tokens: TokenSet
    private let clientId: String
    private let onTokensRenewed: @Sendable (String, TokenSet) -> Void
    private let urlSession: URLSession

    /// Set while a refresh is in flight, so ten concurrent 401s cause one exchange rather
    /// than ten — nine of which would present an already-rotated token and revoke the
    /// whole family.
    private var refreshing: Task<String?, Never>?

    public private(set) lazy var client: ImogenClient = {
        ImogenClient(
            options: ClientOptions(
                baseURL: serverURL,
                token: { [weak self] in await self?.accessToken() },
                onUnauthorized: { [weak self] in await self?.forceRefresh() },
                session: urlSession
            )
        )
    }()

    public init(
        account: Account,
        urlSession: URLSession = .shared,
        onTokensRenewed: @escaping @Sendable (String, TokenSet) -> Void
    ) {
        self.accountId = account.id
        self.serverURL = account.serverURL
        self.tokens = account.tokens
        self.clientId = account.clientId
        self.urlSession = urlSession
        self.onTokensRenewed = onTokensRenewed
    }

    public nonisolated func assetURL(_ assetId: String, variant: String) -> URL? {
        URL(string: "\(serverURL)/api/v1/assets/\(assetId)/\(variant)")
    }

    public nonisolated func faceThumbnailURL(_ faceId: String) -> URL? {
        URL(string: "\(serverURL)/api/v1/people/thumbnail/\(faceId)")
    }

    public func accessToken() async -> String? {
        if !tokens.isExpired(at: Date().timeIntervalSince1970) { return tokens.accessToken }
        return await forceRefresh() ?? tokens.accessToken
    }

    /// Exchanges the refresh token. `nil` when there is nothing to exchange or the server
    /// refused, which means the grant is gone and the account needs signing in again.
    @discardableResult
    public func forceRefresh() async -> String? {
        if let refreshing { return await refreshing.value }

        let task = Task<String?, Never> { [self] in
            guard let refreshToken = currentRefreshToken() else { return nil }
            let oauth = OAuthClient(baseURL: serverURL, session: urlSession)
            guard let renewed = try? await oauth.refresh(
                clientId: clientId, refreshToken: refreshToken
            ) else {
                return nil
            }
            return adopt(renewed, fallbackRefreshToken: refreshToken)
        }

        refreshing = task
        let result = await task.value
        refreshing = nil
        return result
    }

    private func currentRefreshToken() -> String? { tokens.refreshToken }

    private func adopt(_ renewed: StoredTokens, fallbackRefreshToken: String) -> String {
        let updated = TokenSet(
            accessToken: renewed.tokens.accessToken,
            // Rotation: the server hands back a new refresh token and retires the old one.
            // Keeping the old one would revoke the whole family on next use.
            refreshToken: renewed.tokens.refreshToken ?? fallbackRefreshToken,
            obtainedAt: renewed.obtainedAt,
            expiresIn: renewed.tokens.expiresIn,
            scope: renewed.tokens.scope ?? tokens.scope
        )
        tokens = updated
        onTokensRenewed(accountId, updated)
        return updated.accessToken
    }

    /// Image bytes, with the bearer token attached.
    ///
    /// Thumbnails come from ordinary API routes and want ordinary authentication, which is
    /// also why `AsyncImage` cannot fetch them: it has nowhere to put a header.
    public func data(from url: URL) async throws -> Data {
        try await fetch(url, allowingRetry: true)
    }

    private func fetch(_ url: URL, allowingRetry: Bool) async throws -> Data {
        var request = URLRequest(url: url)
        if let token = await accessToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let (body, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { return body }

        // One retry, and only one: a server that keeps refusing a token it just issued is
        // saying something other than "that token was stale".
        if http.statusCode == 401, allowingRetry, await forceRefresh() != nil {
            return try await fetch(url, allowingRetry: false)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ImogenError.from(status: http.statusCode, body: body)
        }
        return body
    }

    /// Headers for something that fetches on its own — the video player, which streams
    /// rather than handing back a `Data`.
    public func authorizationHeaders() async -> [String: String] {
        guard let token = await accessToken() else { return [:] }
        return ["Authorization": "Bearer \(token)"]
    }
}
