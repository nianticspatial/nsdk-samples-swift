// Copyright 2026 Niantic Spatial.
//
// Opens a browser-based login page and handles the deep-link callback.
// The redirectType "nsdk-samples" can be replaced with your own URL scheme when reusing this code
// (update CFBundleURLSchemes in Info.plist accordingly).

import AuthenticationServices
import UIKit

class LoginManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    override init() {
        super.init()
    }

    func startAuth() {
        // On success, the "nsdk-samples" redirectType returns a callback with "nsdk-samples://..." scheme.
        // NOTE: This can be replaced with your own URL scheme if reusing this code (so as not to conflict).
        guard let authURL = URL(string: AuthConstants.EndPointUrls.SignIn + "?redirectType=\(AuthConstants.callbackUrlScheme)") else { return }

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: AuthConstants.callbackUrlScheme
        ) { callbackURL, error in
            if let error = error {
                print("Auth error: \(error.localizedDescription)")
                return
            }
            if let callbackURL = callbackURL {
                self.handleCallback(url: callbackURL)
            }
        }

        session.presentationContextProvider = self
        session.start()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scene = UIApplication.shared.connectedScenes
            .first { $0.activationState == .foregroundActive } as? UIWindowScene
        return scene?.keyWindow ?? ASPresentationAnchor()
    }

    private func handleCallback(url: URL) {
        let tokens = AuthUtils.extractTokens(from: url.absoluteString)
        NSSampleSessionManager.setNSSampleSession(sessionToken: tokens.refreshToken)
    }
}
