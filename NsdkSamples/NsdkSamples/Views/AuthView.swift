// Copyright 2026 Niantic Spatial.

import SwiftUI

struct AuthView: View {

    enum AuthState {
        case loggedOut
        case loggingIn
        case loggedIn(email: String?)
        /// A built-in access token is configured — login/logout controls are hidden.
        case loggedInWithToken
    }

    let authState: AuthState
    let loginManager: LoginManager
    let onLogin: () -> Void
    let onLogout: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            switch authState {
            case .loggedOut:
                Text("Not Logged In")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.orange)
                loginButton

            case .loggingIn:
                ProgressView()

            case .loggedIn(let email):
                Text("Logged In")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.green)
                if let email {
                    Text(email)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(.secondary)
                }
                logoutButton

            case .loggedInWithToken:
                Text("Logged In (Access Token)")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(.green)
            }
        }
        .padding(32)
    }

    private var loginButton: some View {
        Button(action: onLogin) {
            Text("Login")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(minWidth: 240, minHeight: 48)
                .background(Color.blue)
                .cornerRadius(8)
        }
    }

    private var logoutButton: some View {
        Button(action: onLogout) {
            Text("Logout")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(.white)
                .frame(minWidth: 240, minHeight: 48)
                .background(Color.red)
                .cornerRadius(8)
        }
    }
}
