import UIKit

final class AuthViewController: UIViewController {

    private let notLoggedInLabel: UILabel = {
        let label = UILabel()
        label.text = "Not Logged In"
        label.font = UIFont.systemFont(ofSize: 22, weight: .medium)
        label.textColor = .systemOrange
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let developerLoginButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Developer Login", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let sampleEnterpriseLoginButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Sample Enterprise Login", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemPurple
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let chooseLoginHintLabel: UILabel = {
        let label = UILabel()
        label.text = "Choose a login method to authenticate"
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .systemGray
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let loginStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    // Logged-in state UI
    private let loggedInLabel: UILabel = {
        let label = UILabel()
        label.text = "Logged In"
        label.font = UIFont.systemFont(ofSize: 22, weight: .medium)
        label.textColor = .systemGreen
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let flowTypeLabel: UILabel = {
        let label = UILabel()
        label.font = UIFont.systemFont(ofSize: 22, weight: .medium)
        label.textColor = .systemGray
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let logoutButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Logout", for: .normal)
        button.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .medium)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = .systemRed
        button.layer.cornerRadius = 8
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let sessionHintLabel: UILabel = {
        let label = UILabel()
        label.text = "Session tokens are stored securely"
        label.font = UIFont.systemFont(ofSize: 13, weight: .regular)
        label.textColor = .systemGray
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }()

    private let loggedInStackView: UIStackView = {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()

    private lazy var loginManager: LoginManager = { LoginManager(view: view) }()

    private var loginCompleteObserver: NSObjectProtocol?

    private let helpButton: UIButton = {
        let button = UIButton(type: .system)
        button.setTitle("Help", for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.setTitleColor(.lightGray, for: .disabled)
        button.backgroundColor = .systemBlue
        button.layer.cornerRadius = 8
        button.clipsToBounds = true
        button.titleLabel?.font = .boldSystemFont(ofSize: 16)
        button.isEnabled = true
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Auth Management"
        view.backgroundColor = .systemBackground
        setupHelpButton()
        setupLayout()
        setupButtonActions()
        updateLoginUI()
        observeLoginComplete()
    }

    private func setupHelpButton() {
        helpButton.addTarget(self, action: #selector(showHelpModal), for: .touchUpInside)
        let helpBarButton = UIBarButtonItem(customView: helpButton)
        if helpBarButton.responds(to: Selector(("setHidesSharedBackground:"))) {
            helpBarButton.setValue(true, forKey: "hidesSharedBackground")
        }
        navigationItem.rightBarButtonItem = helpBarButton
        NSLayoutConstraint.activate([
            helpButton.widthAnchor.constraint(equalToConstant: 80),
            helpButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func showHelpModal() {
        let overlay = UIView()
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.alpha = 0
        overlay.accessibilityIdentifier = "HelpOverlay"

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(dismissHelpModal(_:)))
        overlay.addGestureRecognizer(tapGesture)
        overlay.isUserInteractionEnabled = true

        let container = UIView()
        container.backgroundColor = UIColor.systemGray.withAlphaComponent(0.95)
        container.layer.cornerRadius = 12
        container.clipsToBounds = true
        container.translatesAutoresizingMaskIntoConstraints = false
        let containerTap = UITapGestureRecognizer(target: self, action: #selector(dismissHelpModal(_:)))
        container.addGestureRecognizer(containerTap)
        container.isUserInteractionEnabled = true

        let titleLabel = UILabel()
        titleLabel.text = "Auth Management"
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.textColor = .label
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let bodyText = "This screen allows you to manage your authentication and authorization session.\n\n" +
            "• Developer Login: Uses the standard developer auth flow\n" +
            "• Sample Enterprise Login: Uses sample enterprise auth endpoints\n" +
            "• Logout: Clears your current session tokens"
        let bodyLabel = UILabel()
        bodyLabel.text = bodyText
        bodyLabel.font = .systemFont(ofSize: 15, weight: .regular)
        bodyLabel.textColor = .label
        bodyLabel.numberOfLines = 0
        bodyLabel.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(titleLabel)
        container.addSubview(bodyLabel)
        overlay.addSubview(container)
        view.window?.addSubview(overlay)

        guard let window = view.window else { return }
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: window.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: window.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: window.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: window.bottomAnchor),

            container.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            container.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
            container.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32),

            titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),

            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            bodyLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            bodyLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            bodyLabel.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -20),
        ])

        overlay.tag = 9000
        UIView.animate(withDuration: 0.2) { overlay.alpha = 1 }
    }

    @objc private func dismissHelpModal(_ gesture: UITapGestureRecognizer) {
        view.window?.viewWithTag(9000)?.removeFromSuperview()
    }

    deinit {
        if let observer = loginCompleteObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func observeLoginComplete() {
        loginCompleteObserver = NotificationCenter.default.addObserver(
            forName: nianticSpatialAccessUserSessionDidSetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, self.view.window != nil else { return }

            self.updateLoginUI()

            if self.isCoveringMainViewController {
                self.navigationController?.dismiss(animated: true, completion: {
                })
            }
        }
    }

    /// True when this auth screen was presented modally by MainViewController (e.g. on launch when auth was required).
    private var isCoveringMainViewController: Bool {
        // The presenting view controller might be a UINavigationController containing MainViewController
        if let presentingNav = navigationController?.presentingViewController as? UINavigationController {
            return presentingNav.topViewController is MainViewController
        }
        return navigationController?.presentingViewController is MainViewController
    }

    private func setupButtonActions() {
        developerLoginButton.addTarget(self, action: #selector(developerLoginTapped), for: .touchUpInside)
        sampleEnterpriseLoginButton.addTarget(self, action: #selector(sampleEnterpriseLoginTapped), for: .touchUpInside)
        logoutButton.addTarget(self, action: #selector(logoutTapped), for: .touchUpInside)
    }

    @objc private func logoutTapped() {
        UserSessionManager.stopUserSession()
        updateLoginUI()
    }

    @objc private func developerLoginTapped() {
        NianticSpatialAccessManager.useSampleBackend = false
        loginManager.startAuth()
    }

    @objc private func sampleEnterpriseLoginTapped() {
        NianticSpatialAccessManager.useSampleBackend = true
        loginManager.startAuth()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateLoginUI()
    }

    private func setupLayout() {
        loginStackView.addArrangedSubview(notLoggedInLabel)
        loginStackView.addArrangedSubview(developerLoginButton)
        loginStackView.addArrangedSubview(sampleEnterpriseLoginButton)
        loginStackView.addArrangedSubview(chooseLoginHintLabel)

        loginStackView.setCustomSpacing(32, after: notLoggedInLabel)
        loginStackView.setCustomSpacing(28, after: sampleEnterpriseLoginButton)

        NSLayoutConstraint.activate([
            sampleEnterpriseLoginButton.widthAnchor.constraint(equalTo: developerLoginButton.widthAnchor),
            sampleEnterpriseLoginButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            developerLoginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
            sampleEnterpriseLoginButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])

        loggedInStackView.addArrangedSubview(loggedInLabel)
        loggedInStackView.addArrangedSubview(flowTypeLabel)
        loggedInStackView.addArrangedSubview(logoutButton)
        loggedInStackView.addArrangedSubview(sessionHintLabel)

        loggedInStackView.setCustomSpacing(32, after: loggedInLabel)
        loggedInStackView.setCustomSpacing(28, after: logoutButton)

        NSLayoutConstraint.activate([
            logoutButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
            logoutButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 48),
        ])
    }

    private func updateLoginUI() {
        if UserSessionManager.isSessionInProgress {
            loginStackView.removeFromSuperview()
            flowTypeLabel.text = NianticSpatialAccessManager.useSampleBackend ? "Sample Enterprise Flow" : "Developer Flow"
            if loggedInStackView.superview == nil {
                view.addSubview(loggedInStackView)
                NSLayoutConstraint.activate([
                    loggedInStackView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
                    loggedInStackView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                    loggedInStackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
                    loggedInStackView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
                ])
            }
        } else {
            loggedInStackView.removeFromSuperview()
            if loginStackView.superview == nil {
                view.addSubview(loginStackView)
                NSLayoutConstraint.activate([
                    loginStackView.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
                    loginStackView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
                    loginStackView.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 32),
                    loginStackView.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -32),
                ])
            }
        }
    }
}
