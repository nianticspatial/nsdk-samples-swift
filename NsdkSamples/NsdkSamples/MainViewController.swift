import UIKit
import SwiftyNsdk

class MainViewController: UIViewController {

    private var entryModalDismissed = false
    private var loginCompleteObserver: NSObjectProtocol?

    private struct ViewControllerItem {
        let title: String
        let viewControllerType: UIViewController.Type
    }

    private let viewControllerItems: [ViewControllerItem] = [
        ViewControllerItem(title: "VPS2 Sites", viewControllerType: SitesViewController.self),
        ViewControllerItem(title: "Capture", viewControllerType: CaptureViewController.self),
        ViewControllerItem(title: "Meshing", viewControllerType: MeshingViewController.self),
        ViewControllerItem(title: "Device Mapping", viewControllerType: MappingViewController.self),
        ViewControllerItem(title: "Object Detection", viewControllerType: ObjectDetectionViewController.self),
        ViewControllerItem(title: "Depth", viewControllerType: DepthViewController.self),
        ViewControllerItem(title: "Occlusion", viewControllerType: OcclusionViewController.self),
        ViewControllerItem(title: "Scene Segmentation", viewControllerType: SceneSegmentationViewController.self),
        ViewControllerItem(title: "VPS2", viewControllerType: VPS2ViewController.self),
        ViewControllerItem(title: "Auth Management", viewControllerType: AuthViewController.self)
    ]

    private lazy var scrollView: UIScrollView = {
        let scrollView = UIScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        return scrollView
    }()

    private lazy var stackView: UIStackView = {
        let stackView = UIStackView()
        stackView.axis = .vertical
        stackView.spacing = 20
        stackView.translatesAutoresizingMaskIntoConstraints = false
        return stackView
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        setupButtons()
        setupLayout()
        observeLoginComplete()
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
            self?.entryModalDismissed = false
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        UserSessionManager.start()
        NianticSpatialAccessManager.start()
        presentAuthViewControllerIfNeeded()
    }

    private func setupButtons() {
        for (index, item) in viewControllerItems.enumerated() {
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
        button.tag = tag // Use tag to identify which view controller to launch
        button.addTarget(self, action: #selector(launchChildViewController(sender:)), for: .touchUpInside)
        return button
    }

    private func setupLayout() {
        // Add version label at top
        let versionLabel = UILabel()
        versionLabel.font = UIFont.systemFont(ofSize: 12, weight: .regular)
        versionLabel.textColor = .black
        versionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(versionLabel)

        let text = NsdkSession.version()
        versionLabel.text = text.isEmpty ? "NSDK" : "NSDK v\(text)"

        view.addSubview(scrollView)
        scrollView.addSubview(stackView)

        NSLayoutConstraint.activate([
            // Version label at top
            versionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            versionLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),

            // ScrollView constraints
            scrollView.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),

            // StackView constraints
            stackView.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 20),
            stackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 20),
            stackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor, constant: -20),
            stackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: -20),
            stackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40)
        ])
    }

    @objc private func launchChildViewController(sender: UIButton) {
        let itemIndex = sender.tag
        guard itemIndex >= 0 && itemIndex < viewControllerItems.count else {
            print("Error: Button tag out of bounds.")
            return
        }

        let item = viewControllerItems[itemIndex]
        let viewControllerClass = item.viewControllerType
        let childVC = viewControllerClass.init()
        navigationController?.pushViewController(childVC, animated: true)
    }

    private func presentAuthViewControllerIfNeeded() {
        guard !entryModalDismissed, nsdkNeedsAuth(), presentedViewController == nil else { return }

        let authVC = AuthViewController()
        let nav = UINavigationController(rootViewController: authVC)
        authVC.navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: "Done",
            style: .done,
            target: self,
            action: #selector(dismissAuthViewController)
        )
        present(nav, animated: true, completion: nil)
    }

    @objc private func dismissAuthViewController() {
        entryModalDismissed = true
        presentedViewController?.dismiss(animated: true, completion: nil)
    }

    private func nsdkNeedsAuth() -> Bool {
        if !AuthConstants.apiKey.isEmpty && AuthConstants.apiKey != "YOUR_API_KEY" {
            return false
        }

        if !AuthUtils.isTokenEmptyOrExpiring(AuthConstants.accessToken, minUnexpiredTimeLeft: 0) {
            return false;
        }

        if !AuthUtils.isTokenEmptyOrExpiring(AuthConstants.refreshToken, minUnexpiredTimeLeft: 0) {
            return false;
        }

        return !UserSessionManager.isSessionInProgress
    }
}
