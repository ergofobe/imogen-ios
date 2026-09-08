import Foundation
import ImogenKit
import ImogenSDK
import Observation
import SwiftUI
import UIKit

/// What is happening while an account is being added, so a screen can say so.
enum LinkState: Equatable {
    case idle
    case working
    case failed(String)
    case linked
}

/// The container, and the state every screen needs.
///
/// Hand-wired rather than injected. There are half a dozen things in it, they are all
/// singletons, and none of them needs swapping out at runtime; a dependency-injection
/// framework here would be ceremony in exchange for nothing.
@MainActor
@Observable
final class AppModel {
    let accounts: AccountStore
    let backup: BackupSettings
    private(set) var link: LinkState = .idle

    /// Live sessions, one per account, built lazily and kept.
    ///
    /// Rebuilding a client per screen would mean a fresh connection pool and a cold image
    /// cache every time somebody moved between tabs.
    private var sessions: [String: Session] = [:]

    private let linker: AccountLinker

    init(
        storage: AccountStorage = KeychainAccountStorage(),
        backup: BackupSettings = BackupSettings()
    ) {
        self.accounts = AccountStore(storage: storage)
        self.backup = backup
        self.linker = AccountLinker(
            clientName: "imogen for iOS (\(UIDevice.current.model))",
            deviceName: UIDevice.current.name
        )
    }

    var active: Account? { accounts.active }

    func session(for account: Account) -> Session {
        if let existing = sessions[account.id] { return existing }

        let store = accounts
        let session = Session(account: account) { id, tokens in
            // Hops back to the main actor because the account store is the thing every
            // view is observing, and a refresh can land on any thread.
            Task { @MainActor in store.setTokens(id, tokens) }
        }
        sessions[account.id] = session
        return session
    }

    func switchTo(_ id: String) {
        accounts.setActive(id)
    }

    func signOut(_ account: Account) {
        // The grant is revoked server-side first: an account removed from the phone but
        // left live on the server is a token nobody can see and nobody can stop.
        let serverURL = account.serverURL
        let tokens = account.tokens
        Task.detached {
            let oauth = OAuthClient(baseURL: serverURL)
            try? await oauth.revoke(tokens.accessToken)
            if let refresh = tokens.refreshToken { try? await oauth.revoke(refresh) }
            await ThumbnailCache.shared.forget(accountId: account.id)
        }

        sessions[account.id] = nil
        accounts.remove(account.id)
    }

    func setBackupEnabled(_ account: Account, _ enabled: Bool) {
        accounts.setBackupEnabled(account.id, enabled)
        if enabled { PhotoBackup.shared.runSoon(self) }
    }

    // MARK: - Adding an account

    /// Anything the operating system delivered to the app: a pairing link, or the OAuth
    /// redirect coming back from the browser.
    ///
    /// Ignores a URL that is neither, so a share sheet sending something odd this way does
    /// not turn into an error somebody has to dismiss.
    func open(_ url: URL) {
        let text = url.absoluteString
        if linker.invitation(from: text) != nil {
            pair(text)
        } else if text.hasPrefix(oauthRedirect) {
            completeBrowserSignIn(text)
        }
    }

    func pair(_ scanned: String) {
        guard let invitation = linker.invitation(from: scanned) else {
            link = .failed(LinkError.notAnInvitation.localizedDescription)
            return
        }
        link = .working
        Task {
            do {
                accounts.add(try await linker.pair(invitation))
                link = .linked
            } catch {
                link = .failed(describe(error))
            }
        }
    }

    func beginBrowserSignIn(server: String, open: @escaping (URL) -> Void) {
        link = .working
        Task {
            do {
                let url = try await linker.beginBrowserSignIn(server: server)
                // Back to idle: the browser is in front now, and leaving a spinner behind
                // it would still be spinning if somebody backed out.
                link = .idle
                open(url)
            } catch {
                link = .failed(describe(error))
            }
        }
    }

    private func completeBrowserSignIn(_ callback: String) {
        link = .working
        Task {
            do {
                accounts.add(try await linker.completeBrowserSignIn(callback: callback))
                link = .linked
            } catch {
                link = .failed(describe(error))
            }
        }
    }

    func clearLinkState() {
        link = .idle
    }

    /// A message worth putting in front of somebody.
    ///
    /// The SDK's errors already carry what the server said; everything else usually means
    /// the address was wrong or the server was not there, and saying so is more use than
    /// the name of a socket failure.
    private func describe(_ error: Error) -> String {
        if let imogen = error as? ImogenError { return imogen.message }
        if let oauth = error as? OAuthError { return oauth.message }
        if let link = error as? LinkError { return link.localizedDescription }
        // Anything that took the trouble to describe itself gets to. Without this a
        // KeychainError — the very failure this app now raises rather than swallows —
        // came out as "could not reach that server", which is the same lie in a new coat.
        if let described = (error as? LocalizedError)?.errorDescription { return described }
        return "Could not reach that server. Check the address and try again."
    }
}
