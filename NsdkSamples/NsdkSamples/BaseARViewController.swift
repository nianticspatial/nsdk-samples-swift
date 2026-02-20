import UIKit
import RealityKit
import ARKit
import SwiftyNsdk // Assuming NsdkManager is from here
import Combine

class BaseARViewController: UIViewController, ARSessionDelegate {
    // MARK: - UI Properties
    public let arView: ARView
    public let sessionInfoView: UIView
    public let sessionInfoLabel: UILabel //Used to display the status of NSDK sessions
    public let sampleInfoLabel: UILabel // Used to display info relevant to the current sample
    public let helpLabel: UILabel
    internal let helpButton: UIButton
    internal let backButton: UIButton
    internal var accessTokenSubscription: AnyCancellable?
    internal var userSessionTokenSubscription: AnyCancellable?

    // MARK: - NSDK Properties
    public var nsdkManager: NsdkManager?

    // MARK: - Initialization
    init() {
        self.arView = ARView()
        self.sessionInfoView = UIView()
        self.sessionInfoLabel = UILabel()
        self.sampleInfoLabel = UILabel()
        self.helpLabel = UILabel()
        self.helpButton = UIButton()
        self.backButton = UIButton()
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("not supported")
    }

    deinit {
        accessTokenSubscription?.cancel()
        userSessionTokenSubscription?.cancel()
    }

    // MARK: - View Life Cycle
    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupNsdk()
    }

    internal func setupUI() {
        view.backgroundColor = .darkGray

        arView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(arView)

        sessionInfoView.translatesAutoresizingMaskIntoConstraints = false
        sessionInfoView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        sessionInfoView.layer.cornerRadius = 10
        sessionInfoView.clipsToBounds = true
        view.addSubview(sessionInfoView)

        sessionInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionInfoLabel.textColor = .white
        sessionInfoLabel.textAlignment = .center
        sessionInfoLabel.font = .systemFont(ofSize: 14)
        sessionInfoLabel.text = "Initializing AR session..."
        sessionInfoView.addSubview(sessionInfoLabel)

        helpButton.setTitle("Help", for: .normal)
        helpButton.setTitleColor(.white, for: .normal)
        helpButton.setTitleColor(.lightGray, for: .disabled)
        helpButton.backgroundColor = .systemBlue
        helpButton.layer.cornerRadius = 8
        helpButton.clipsToBounds = true
        helpButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        helpButton.isEnabled = true
        helpButton.addTarget(self, action: #selector(handleHelpButtonTap), for: .touchUpInside)
        helpButton.translatesAutoresizingMaskIntoConstraints = false

        let helpBarButton = UIBarButtonItem(customView: helpButton)
        if helpBarButton.responds(to: Selector(("setHidesSharedBackground:"))) {
            helpBarButton.setValue(true, forKey: "hidesSharedBackground")
        }
        navigationItem.rightBarButtonItem = helpBarButton

        backButton.setTitle("< Back", for: .normal)
        backButton.setTitleColor(.white, for: .normal)
        backButton.setTitleColor(.lightGray, for: .disabled)
        backButton.backgroundColor = .systemBlue
        backButton.layer.cornerRadius = 8
        backButton.clipsToBounds = true
        backButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        backButton.isEnabled = true
        backButton.addTarget(self, action: #selector(handleBackButtonTap), for: .touchUpInside)
        backButton.translatesAutoresizingMaskIntoConstraints = false

        let backBarButton = UIBarButtonItem(customView: backButton)
        if backBarButton.responds(to: Selector(("setHidesSharedBackground:"))) {
            backBarButton.setValue(true, forKey: "hidesSharedBackground")
        }
        navigationItem.leftBarButtonItem = backBarButton

        sampleInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        sampleInfoLabel.textColor = .white
        sampleInfoLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        sampleInfoLabel.textAlignment = .center
        sampleInfoLabel.font = .systemFont(ofSize: 15)
        sampleInfoLabel.numberOfLines = 0
        sampleInfoLabel.layer.cornerRadius = 8
        sampleInfoLabel.clipsToBounds = true
        sampleInfoLabel.text = ""
        sampleInfoLabel.isHidden = true
        view.addSubview(sampleInfoLabel)

        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        helpLabel.textColor = .white
        helpLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        helpLabel.textAlignment = .natural
        helpLabel.font = .systemFont(ofSize: 15)
        helpLabel.numberOfLines = 0
        helpLabel.layer.cornerRadius = 8
        helpLabel.clipsToBounds = true
        helpLabel.isUserInteractionEnabled = true
        helpLabel.text = "TODO: Help Info for sample"
        helpLabel.isHidden = true
        view.addSubview(helpLabel)

        NSLayoutConstraint.activate([
            arView.topAnchor.constraint(equalTo: view.topAnchor),
            arView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            arView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            arView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            sessionInfoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            sessionInfoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            sessionInfoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            sessionInfoView.heightAnchor.constraint(equalToConstant: 44),

            sessionInfoLabel.topAnchor.constraint(equalTo: sessionInfoView.topAnchor, constant: 4),
            sessionInfoLabel.bottomAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: -4),
            sessionInfoLabel.leadingAnchor.constraint(equalTo: sessionInfoView.leadingAnchor, constant: 8),
            sessionInfoLabel.trailingAnchor.constraint(equalTo: sessionInfoView.trailingAnchor, constant: -8),

            sampleInfoLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            sampleInfoLabel.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            sampleInfoLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 25),
            sampleInfoLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -25),
            sampleInfoLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),

            helpLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            helpLabel.topAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: 10),
            helpLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
            helpLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 15),
            helpLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -15),

            helpButton.widthAnchor.constraint(equalToConstant: 80),
            helpButton.heightAnchor.constraint(equalToConstant: 44),

            backButton.widthAnchor.constraint(equalToConstant: 80),
            backButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    // Default button constructor places it above the sampleInfoLabel on the right side of the screen
    internal func addButton(buttonTitle : String, onClickAction: Selector) -> UIButton {
        let newButton = addButton(buttonTitle: buttonTitle, onClickAction: onClickAction, xAnchor: view.safeAreaLayoutGuide.trailingAnchor, xOffset: -20, yAnchor: sampleInfoLabel.topAnchor, yOffset: -20)

        return newButton
    }

    internal func addButton(buttonTitle : String, onClickAction: Selector, xAnchor: NSLayoutXAxisAnchor, xOffset: CGFloat, yAnchor: NSLayoutYAxisAnchor, yOffset: CGFloat) -> UIButton {
        let newButton = UIButton()
        newButton.setTitle(buttonTitle, for: .normal)
        newButton.setTitleColor(.white, for: .normal)
        newButton.setTitleColor(.lightGray, for: .disabled)
        newButton.backgroundColor = .systemBlue
        newButton.layer.cornerRadius = 8
        newButton.titleLabel?.font = .boldSystemFont(ofSize: 16)
        newButton.isEnabled = true
        newButton.addTarget(self, action: onClickAction, for: .touchUpInside)
        newButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(newButton)

        NSLayoutConstraint.activate([
            newButton.trailingAnchor.constraint(equalTo: xAnchor, constant: xOffset),
            newButton.bottomAnchor.constraint(equalTo: yAnchor, constant: yOffset),
            newButton.widthAnchor.constraint(equalToConstant: 120),
            newButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        return newButton
    }

    // Helper function to request a runtime refresh token and set it on the session
    private func requestAndSetRuntimeRefreshToken(userSessionRefreshToken: String, session: NsdkSession) {
        Task {
            do {
                let result = try await RequestRuntimeRefreshToken.execute(userSessionRefreshToken: userSessionRefreshToken)
                session.setRefreshToken(result.refreshToken)
            } catch {
                print("setupNsdkAuth: failed to request runtime refresh token: \(error)")
            }
        }
    }

    // Utility to initialize auth through the various means supported by the NsdkManager.
    private func setupNsdk() {
        if nsdkManager != nil {
            return
        }

        // Only subscribe to access token updates if there is no api key or valid access token
        // In the case that there is an api key, we don't need any updates
        // In the case that an access token and refresh token are provided, native nsdk will manage the auth itself.
        var needsAccessTokenSubscription = true
        if !AuthConstants.apiKey.isEmpty && AuthConstants.apiKey != "YOUR_API_KEY" {
            needsAccessTokenSubscription = false
            nsdkManager = NsdkManager(apiKey: AuthConstants.apiKey, useLidar: ARUtils.isLidarAvailable())
        } else {
            let accessToken = AuthAccessManager.accessToken ?? AuthConstants.accessToken
            needsAccessTokenSubscription = accessToken.isEmpty && AuthConstants.refreshToken.isEmpty
            nsdkManager = NsdkManager(accessToken: accessToken, refreshToken: AuthConstants.refreshToken, useLidar: ARUtils.isLidarAvailable())

            if let session = nsdkManager?.session {
                if NianticSpatialAccessManager.useSampleBackend {
                    // Sample backend on: clear session refresh token and set session access token from AuthAccessManager.
                    session.setRefreshToken("")
                    if let currentToken = AuthAccessManager.accessToken, !currentToken.isEmpty {
                        session.setAccessToken(currentToken)
                    }
                    accessTokenSubscription = AuthAccessManager.accessTokenUpdated.sink { [weak self] accessToken in
                        self?.nsdkManager?.session.setAccessToken(accessToken)
                    }
                } else {
                    // useSampleBackend is false: runtime refresh path — set the session refresh token.
                    if let userRefreshToken = UserSessionManager.refreshToken,
                       !AuthUtils.isTokenEmptyOrExpiring(userRefreshToken, minUnexpiredTimeLeft: 0) {
                        session.setAccessToken("")
                        requestAndSetRuntimeRefreshToken(userSessionRefreshToken: userRefreshToken, session: session)
                    } else {
                        userSessionTokenSubscription = UserSessionManager.refreshTokenAvailable
                            .first()
                            .sink { [weak self] userRefreshToken in
                                guard let self = self, let session = self.nsdkManager?.session else { return }
                                session.setAccessToken("")
                                self.requestAndSetRuntimeRefreshToken(userSessionRefreshToken: userRefreshToken, session: session)
                            }
                    }
                }
            }
        }

        // Subscribe to get token updates if there is no api key or valid access token
        // This relies on the LoginManager being invoked from the MainViewController and
        //   invoking the AuthAccessManager.accessTokenUpdated event when the login is complete.
        // Note: PassthroughSubject doesn't replay the last value, so we check for an existing
        //   token when subscribing and apply it immediately if available.
        if needsAccessTokenSubscription {
            // Apply current token immediately if one exists (PassthroughSubject doesn't replay)
            if let currentToken = AuthAccessManager.accessToken, !currentToken.isEmpty {
                nsdkManager?.session.setAccessToken(currentToken)
            }

            // Subscribe to future token updates
            self.accessTokenSubscription = AuthAccessManager.accessTokenUpdated.sink { [weak self] accessToken in
                self?.nsdkManager?.session.setAccessToken(accessToken)
            }
        }

        nsdkManager?.startLocationService()
     }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        if (ARUtils.isLidarAvailable()) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        arView.session.run(configuration)
        arView.session.delegate = self
        UIApplication.shared.isIdleTimerDisabled = true
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        arView.session.pause()
    }

    // MARK: - Entity Management
    func addAnchorEntity(for anchor: ARAnchor) -> AnchorEntity {
        let anchorEntity = AnchorEntity(anchor: anchor)
        arView.scene.addAnchor(anchorEntity)
        return anchorEntity
    }

    func updateAnchorEntity(_ entity: Entity, for anchor: ARAnchor) {}
    // MARK: - ARSessionDelegate

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        guard let frame = session.currentFrame else { return }
        updateSessionInfoLabel(for: frame, trackingState: frame.camera.trackingState)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        guard let frame = session.currentFrame else { return }
        updateSessionInfoLabel(for: frame, trackingState: frame.camera.trackingState)
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        updateSessionInfoLabel(for: session.currentFrame!, trackingState: camera.trackingState)
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        nsdkManager?.sendFrame(frame)
    }

    // MARK: - ARSessionObserver

    func sessionWasInterrupted(_ session: ARSession) {
        // Inform the user that the session has been interrupted, for example, by presenting an overlay.
        sessionInfoLabel.text = "Session was interrupted"
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        // Reset tracking and/or remove existing anchors if consistent tracking is required.
        sessionInfoLabel.text = "Session interruption ended"
        resetTracking()
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        sessionInfoLabel.text = "Session failed: \(error.localizedDescription)"
        guard error is ARError else { return }

        let errorWithInfo = error as NSError
        let messages = [
            errorWithInfo.localizedDescription,
            errorWithInfo.localizedFailureReason,
            errorWithInfo.localizedRecoverySuggestion
        ]

        // Remove optional error messages.
        let errorMessage = messages.compactMap({ $0 }).joined(separator: "\n")

        DispatchQueue.main.async {
            // Present an alert informing about the error that has occurred.
            let alertController = UIAlertController(title: "The AR session failed.", message: errorMessage, preferredStyle: .alert)
            let restartAction = UIAlertAction(title: "Restart Session", style: .default) { _ in
                alertController.dismiss(animated: true, completion: nil)
                self.resetTracking()
            }
            alertController.addAction(restartAction)
            self.present(alertController, animated: true, completion: nil)
        }
    }

    private func updateSessionInfoLabel(for frame: ARFrame, trackingState: ARCamera.TrackingState) {
        // Update the UI to provide feedback on the state of the AR experience.
        let message: String

        switch trackingState {
//        case .normal where frame.anchors.isEmpty:
//            // No planes detected; provide instructions for this app's AR interactions.
//            message = "Move the device around to detect horizontal and vertical surfaces."
//
        case .notAvailable:
            message = "Tracking unavailable."

        case .limited(.excessiveMotion):
            message = "Tracking limited - Move the device more slowly."

        case .limited(.insufficientFeatures):
            message = "Tracking limited - Point the device at an area with visible surface detail, or improve lighting conditions."

        case .limited(.initializing):
            message = "Initializing AR session."

        default:
            // No feedback needed when tracking is normal and planes are visible.
            // (Nor when in unreachable limited-tracking states.)
            message = ""

        }

        sessionInfoLabel.text = message
        sessionInfoView.isHidden = message.isEmpty
    }

    private func resetTracking() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        arView.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }

    internal func updateInfoLabel(text: String, color:UIColor = .white) {
        sampleInfoLabel.text = text
        sampleInfoLabel.isHidden = text.isEmpty
        sampleInfoLabel.textColor = color
    }

    @objc internal func handleHelpButtonTap() {
        helpLabel.isHidden.toggle()
        view.bringSubviewToFront(helpLabel)
    }

    @objc internal func handleBackButtonTap() {
        self.navigationController?.popViewController(animated: true)
    }
}
