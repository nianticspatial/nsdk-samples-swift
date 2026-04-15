// Copyright 2026 Niantic Spatial.

import UIKit
import NSDK
import Combine

final class MainViewController: UIViewController {

    // MARK: - Nav list

    private struct MenuItem {
        let title: String
        let makeViewController: (ARManager) -> UIViewController
    }

    private let menuItems: [MenuItem] = [
        MenuItem(title: "VPS2 (with Sites)") { SitesViewController(arManager: $0) },
        MenuItem(title: "VPS2 (with anchor payload)") { VPS2ViewController(arManager: $0) },
        MenuItem(title: "Depth") { DepthViewController(arManager: $0) },
        MenuItem(title: "Occlusion") { OcclusionViewController(arManager: $0) },
        MenuItem(title: "Scene Segmentation") { SceneSegmentationViewController(arManager: $0) },
        MenuItem(title: "Capture") { CaptureViewController(arManager: $0) },
        MenuItem(title: "Device Mapping") { DeviceMappingViewController(arManager: $0) },
        MenuItem(title: "Meshing") { MeshingViewController(arManager: $0) },
    ]

    // MARK: - Auth button

    private let authStatusButton: UIButton = {
        let button = UIButton(type: .custom)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }()

    private let authSpinner: UIActivityIndicatorView = {
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        return spinner
    }()

    private var authState: AuthViewController.AuthState = .loggedOut {
        didSet { updateAuthButton() }
    }

    // MARK: - Scroll / stack

    private lazy var scrollView: UIScrollView = {
        let sv = UIScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    private lazy var stackView: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 20
        sv.translatesAutoresizingMaskIntoConstraints = false
        return sv
    }()

    // MARK: - Observers

    private var sessionSetObserver: NSObjectProtocol?
    private var sessionStopObserver: NSObjectProtocol?
    private var authSubscription: AnyCancellable?

    private lazy var loginManager: LoginManager = { LoginManager(view: view) }()

    private var hasAutoPromptedLogin = false

    // MARK: - Initialization

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupButtons()
        setupLayout()
        setupAuthButton()
        observeSessionChanges()
        refreshAuthState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        authSubscription = nil
        NSSampleSessionManager.start()
        refreshAuthState()
        promptLoginIfNeeded()
    }

    private func promptLoginIfNeeded() {
        guard !hasAutoPromptedLogin else { return }
        hasAutoPromptedLogin = true
        guard nsdkNeedsAuth(), presentedViewController == nil else { return }
        authButtonTapped()
    }

    private func nsdkNeedsAuth() -> Bool {
        if !AuthUtils.isTokenEmptyOrExpiring(AuthConstants.accessToken, minUnexpiredTimeLeft: 0) {
            return false
        }
        return !NSSampleSessionManager.isSessionInProgress
    }

    deinit {
        [sessionSetObserver, sessionStopObserver].compactMap { $0 }.forEach {
            NotificationCenter.default.removeObserver($0)
        }
    }

    // MARK: - Auth state

    private func refreshAuthState() {
        if AuthUtils.isValidJwt(AuthConstants.accessToken) {
            authState = .loggedInWithToken
        } else if NSSampleSessionManager.isSessionInProgress {
            let email = AuthUtils.jwtEmail(for: NSSampleSessionManager.sampleToken)
            authState = .loggedIn(email: email)
        } else {
            authState = .loggedOut
        }
    }

    private func observeSessionChanges() {
        sessionSetObserver = NotificationCenter.default.addObserver(
            forName: nsSampleSessionDidSetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshAuthState()
        }

        sessionStopObserver = NotificationCenter.default.addObserver(
            forName: nsSampleSessionDidStopNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.authState = .loggedOut
        }
    }

    // MARK: - Auth button setup

    private func setupAuthButton() {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(authStatusButton)
        container.addSubview(authSpinner)

        NSLayoutConstraint.activate([
            authStatusButton.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            authStatusButton.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            authStatusButton.topAnchor.constraint(equalTo: container.topAnchor),
            authStatusButton.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            authStatusButton.widthAnchor.constraint(equalToConstant: 32),
            authStatusButton.heightAnchor.constraint(equalToConstant: 32),

            authSpinner.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            authSpinner.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        authStatusButton.addTarget(self, action: #selector(authButtonTapped), for: .touchUpInside)
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: container)

        updateAuthButton()
    }

    private func updateAuthButton() {
        switch authState {
        case .loggedOut:
            authSpinner.stopAnimating()
            authStatusButton.isHidden = false
            let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            let image = UIImage(systemName: "person.crop.circle", withConfiguration: config)?
                .withTintColor(.systemGray, renderingMode: .alwaysOriginal)
            authStatusButton.setImage(image, for: .normal)

        case .loggingIn:
            authStatusButton.isHidden = true
            authSpinner.startAnimating()

        case .loggedIn, .loggedInWithToken:
            authSpinner.stopAnimating()
            authStatusButton.isHidden = false
            let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .medium)
            let image = UIImage(systemName: "person.crop.circle.badge.checkmark", withConfiguration: config)?
                .withTintColor(.systemGreen, renderingMode: .alwaysOriginal)
            authStatusButton.setImage(image, for: .normal)
        }
    }

    // MARK: - Auth panel

    @objc private func authButtonTapped() {
        let panel = AuthViewController(authState: authState, loginManager: loginManager)
        if let sheet = panel.sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = false
        }
        present(panel, animated: true)
    }

    // MARK: - Nav list setup

    private func setupButtons() {
        for (index, item) in menuItems.enumerated() {
            let button = createViewButton(title: item.title, tag: index)
            stackView.addArrangedSubview(button)
        }
    }

    private func createViewButton(title: String, tag: Int) -> UIButton {
        var config = UIButton.Configuration.filled()
        config.title = title
        config.baseBackgroundColor = .systemBlue
        config.baseForegroundColor = .white
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 20, bottom: 12, trailing: 20)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = UIFont.systemFont(ofSize: 18, weight: .medium)
            return outgoing
        }

        let button = UIButton(configuration: config)
        button.layer.cornerRadius = 8
        button.tag = tag
        button.addTarget(self, action: #selector(launchChildViewController(sender:)), for: .touchUpInside)
        return button
    }

    private func setupLayout() {
        let versionLabel = UILabel()
        versionLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .black
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(versionLabel)

        let text = NSDKSession.version()
        versionLabel.text = text.isEmpty ? "NSDK" : "NSDK v\(text)"

        view.addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            versionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            scrollView.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
        ])
    }

    @objc private func launchChildViewController(sender: UIButton) {
        let itemIndex = sender.tag
        guard itemIndex >= 0 && itemIndex < menuItems.count else { return }
        let arManager = createARManager()
        let vc = menuItems[itemIndex].makeViewController(arManager)
        navigationController?.pushViewController(vc, animated: true)
    }

    private func createARManager() -> ARManager {
        let session = NSDKSession(
            accessToken: AuthConstants.accessToken,
            useLidar: ARUtils.isLidarAvailable()
        )
        authSubscription = NSSampleSessionManager.setupSessionAccess(for: session)
        return ARManager(nsdkSession: session)
    }
}
