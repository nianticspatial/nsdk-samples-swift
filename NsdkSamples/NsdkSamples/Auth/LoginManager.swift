import AuthenticationServices

//
//  LoginManager.swift
//  NsdkSamples
//
//  Handles opening the web-page for login into the Enterprise Auth sample
//  and receiving the results.
//

class LoginManager: NSObject, ASWebAuthenticationPresentationContextProviding {

    let view: UIView

    init(view: UIView) {
        self.view = view
    }

    func startAuth() {
        // 1. The URL for the login page
        guard let authURL = URL(string: AuthConstants.EndPointUrls.SignIn + "?redirectType=ios-app") else { return }

        // 2. The scheme you defined in Info.plist
        let scheme = "nsdk-samples"

        let session = ASWebAuthenticationSession(
            url: authURL,
            callbackURLScheme: scheme
        ) { callbackURL, error in
            // Handle the response
            if let error = error {
                print("Auth error: \(error.localizedDescription)")
                return
            }

            if let callbackURL = callbackURL {
                self.handleCallback(url: callbackURL)
            }
        }

        // 3. Set the presentation context (usually the main window)
        session.presentationContextProvider = self
        session.start()
    }

    // Pass the view into your manager or keep a reference
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // If this code is inside a UIViewController:
        return self.view.window ?? ASPresentationAnchor()
    }

    private func handleCallback(url: URL) {
        let tokens = AuthUtils.extractTokens(from: url.absoluteString)
        UserSessionManager.setUserSession(refreshToken: tokens.refreshToken, accessToken: tokens.accessToken)
    }
}
