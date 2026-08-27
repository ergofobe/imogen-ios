import AuthenticationServices
import UIKit

/// The authorization step, in a browser that knows how to catch the redirect back.
///
/// `SFSafariViewController` cannot do this, which is not obvious until it bites: the
/// consent page's Allow button submits, the server answers with a redirect to
/// `imogen://oauth?code=…`, and a Safari view controller silently refuses to follow a
/// redirect to a scheme it does not consider web. Nothing happens, no error appears, and
/// the button looks broken.
///
/// `ASWebAuthenticationSession` is built for this and is what RFC 8252 asks for on iOS.
/// It is told the callback scheme up front, watches for it itself, and hands the URL back
/// rather than routing it out through the operating system and hoping the app is asked to
/// open it.
@MainActor
final class WebAuthenticator: NSObject, ASWebAuthenticationPresentationContextProviding {

    /// Held for the life of the session: releasing it cancels the sheet.
    private var session: ASWebAuthenticationSession?

    /// Returns the callback URL, or `nil` if the person cancelled or it could not start.
    func authorize(at url: URL, callbackScheme: String) async -> URL? {
        await withCheckedContinuation { continuation in
            var resumed = false
            let finish: (URL?) -> Void = { callback in
                // A continuation resumed twice is a crash, and the failure paths below
                // can otherwise overlap.
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: callback)
            }

            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: callbackScheme
            ) { callback, _ in
                // A cancellation and a failure are the same thing here: there is no
                // account, and the screen behind is already the one to try again from.
                finish(callback)
            }

            session.presentationContextProvider = self
            // Not ephemeral: the browser's own session and password manager are the point
            // of sending somebody out to it, and a person already signed in to imogen in
            // Safari should not have to do it again.
            session.prefersEphemeralWebBrowserSession = false

            self.session = session
            if !session.start() { finish(nil) }
        }
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }?
                .keyWindow ?? ASPresentationAnchor()
        }
    }
}
