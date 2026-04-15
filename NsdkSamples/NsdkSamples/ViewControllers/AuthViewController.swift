// Copyright 2026 Niantic Spatial.

import UIKit

final class AuthViewController: UIViewController {

    enum AuthState {
        case loggedOut
        case loggingIn
        case loggedIn(email: String?)
        /// A built-in access token is configured — login/logout controls are hidden.
        case loggedInWithToken
    }

    private var authState: AuthState
    private let loginManager: LoginManager

    init(authState: AuthState, loginManager: LoginManager) {
        self.authState = authState
        self.loginManager = loginManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        setupUI()
    }

    private func setupUI() {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32),
        ])

        switch authState {
        case .loggedOut, .loggingIn:
            let statusLabel = makeLabel("Not Logged In", font: .systemFont(ofSize: 20, weight: .semibold), color: .systemOrange)
            let loginButton = makeActionButton(title: "Login", color: .systemBlue, action: #selector(loginTapped))
            stack.addArrangedSubview(statusLabel)
            stack.addArrangedSubview(loginButton)
            NSLayoutConstraint.activate([
                loginButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
                loginButton.heightAnchor.constraint(equalToConstant: 48),
            ])

        case .loggedIn(let email):
            let statusLabel = makeLabel("Logged In", font: .systemFont(ofSize: 20, weight: .semibold), color: .systemGreen)
            stack.addArrangedSubview(statusLabel)

            if let email {
                let emailLabel = makeLabel(email, font: .systemFont(ofSize: 15, weight: .regular), color: .secondaryLabel)
                stack.addArrangedSubview(emailLabel)
            }

            let logoutButton = makeActionButton(title: "Logout", color: .systemRed, action: #selector(logoutTapped))
            stack.addArrangedSubview(logoutButton)
            NSLayoutConstraint.activate([
                logoutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
                logoutButton.heightAnchor.constraint(equalToConstant: 48),
            ])

        case .loggedInWithToken:
            let statusLabel = makeLabel("Logged In (Access Token)", font: .systemFont(ofSize: 20, weight: .semibold), color: .systemGreen)
            stack.addArrangedSubview(statusLabel)
        }
    }

    private func makeLabel(_ text: String, font: UIFont, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.textAlignment = .center
        return label
    }

    private func makeActionButton(title: String, color: UIColor, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = color
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func loginTapped() {
        dismiss(animated: true) {
            self.loginManager.startAuth()
        }
    }

    @objc private func logoutTapped() {
        NSSampleSessionManager.stopNSSampleSession()
        dismiss(animated: true)
    }
}
