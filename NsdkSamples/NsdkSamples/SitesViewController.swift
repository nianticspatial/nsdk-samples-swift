// Copyright Niantic Spatial.

import UIKit
import SwiftyNsdk
import Combine

class SitesViewController: UIViewController {
    // MARK: - NSDK & Auth
    var nsdkManager: NsdkManager?
    private var accessTokenSubscription: AnyCancellable?
    private var userSessionTokenSubscription: AnyCancellable?

    // MARK: - Top bar & Help
    private let sessionInfoView = UIView()
    private let sessionInfoLabel = UILabel()
    private let helpLabel = UILabel()
    private let helpButton = UIButton()
    private let backButton = UIButton()

    // MARK: - Sites
    private var sitesManager: SitesManager?
    private var loadingTask: Task<Void, Never>?
    private var retryHelper: AuthRetryHelper?

    // UI Components
    private let infoLabel = UILabel()
    private let searchTextField = UITextField()
    private let scrollView = UIScrollView()
    private let buttonStackView = UIStackView()

    // State
    private var currentUser: UserInfo?
    private var currentOrganizations: [OrganizationInfo] = []
    private var filterProduction = true
    private var currentSitesWithAssets: [(SiteInfo, AssetInfo)] = []
    private var filterText: String = ""
    private weak var sitesLoadingIndicator: UIView?

    override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        accessTokenSubscription?.cancel()
        userSessionTokenSubscription?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Sites Manager"

        setupUI()
        setupNsdk()
        setupSitesManager()
        loadInitialData()

        helpLabel.text = "VPS2 Sites Sample Help\n\n" +
            "This sample demonstrates the Sites Manager API for browsing organizations and sites.\n\n" +
            "TO USE:\n" +
            "1. Select an organization from your user's organizations\n" +
            "2. Select a site (only sites with a Production VPS asset are shown)\n" +
            "3. VPS2 localization starts immediately for the selected site\n\n" +
            "You can filter items by name using the search field. "
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadingTask?.cancel()
    }

    // MARK: - UI Setup

    private func setupUI() {
        // Top bar
        sessionInfoView.translatesAutoresizingMaskIntoConstraints = false
        sessionInfoView.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        sessionInfoView.layer.cornerRadius = 10
        sessionInfoView.clipsToBounds = true
        view.addSubview(sessionInfoView)

        sessionInfoLabel.translatesAutoresizingMaskIntoConstraints = false
        sessionInfoLabel.textColor = .white
        sessionInfoLabel.textAlignment = .center
        sessionInfoLabel.font = .systemFont(ofSize: 14)
        sessionInfoLabel.text = "Sites Manager"
        sessionInfoView.addSubview(sessionInfoLabel)

        // Help button
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

        // Back button
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

        // Help label (hidden until Help tapped)
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

        // Info label container
        let infoContainer = UIView()
        infoContainer.translatesAutoresizingMaskIntoConstraints = false
        infoContainer.backgroundColor = UIColor.systemGray6
        infoContainer.layer.cornerRadius = 8
        infoContainer.clipsToBounds = true
        view.addSubview(infoContainer)

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.textColor = .label
        infoLabel.backgroundColor = .clear
        infoLabel.textAlignment = .left
        infoLabel.font = .systemFont(ofSize: 14)
        infoLabel.numberOfLines = 0
        infoLabel.text = ""
        infoContainer.addSubview(infoLabel)

        // Search text field
        searchTextField.translatesAutoresizingMaskIntoConstraints = false
        searchTextField.placeholder = "Filter..."
        searchTextField.borderStyle = .roundedRect
        searchTextField.backgroundColor = .systemGray6
        searchTextField.clearButtonMode = .whileEditing
        searchTextField.returnKeyType = .done
        searchTextField.addTarget(self, action: #selector(filterTextChanged), for: .editingChanged)
        searchTextField.delegate = self
        view.addSubview(searchTextField)

        // Scroll view for buttons
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = true
        view.addSubview(scrollView)

        buttonStackView.axis = .vertical
        buttonStackView.spacing = 12
        buttonStackView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(buttonStackView)

        NSLayoutConstraint.activate([
            // Top bar
            sessionInfoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            sessionInfoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            sessionInfoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            sessionInfoView.heightAnchor.constraint(equalToConstant: 44),

            sessionInfoLabel.topAnchor.constraint(equalTo: sessionInfoView.topAnchor, constant: 4),
            sessionInfoLabel.bottomAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: -4),
            sessionInfoLabel.leadingAnchor.constraint(equalTo: sessionInfoView.leadingAnchor, constant: 8),
            sessionInfoLabel.trailingAnchor.constraint(equalTo: sessionInfoView.trailingAnchor, constant: -8),

            helpLabel.topAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 15),
            helpLabel.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -15),
            helpLabel.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),

            helpButton.widthAnchor.constraint(equalToConstant: 80),
            helpButton.heightAnchor.constraint(equalToConstant: 44),
            backButton.widthAnchor.constraint(equalToConstant: 80),
            backButton.heightAnchor.constraint(equalToConstant: 44),

            // Info container
            infoContainer.topAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: 20),
            infoContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            infoContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            infoContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            infoContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            infoLabel.topAnchor.constraint(equalTo: infoContainer.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: -12),

            searchTextField.topAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: 12),
            searchTextField.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            searchTextField.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            searchTextField.heightAnchor.constraint(equalToConstant: 44),

            scrollView.topAnchor.constraint(equalTo: searchTextField.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

            buttonStackView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            buttonStackView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            buttonStackView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            buttonStackView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            buttonStackView.widthAnchor.constraint(equalTo: scrollView.widthAnchor)
        ])
    }

    @objc private func handleHelpButtonTap() {
        helpLabel.isHidden.toggle()
        view.bringSubviewToFront(helpLabel)
    }

    @objc private func handleBackButtonTap() {
        navigationController?.popViewController(animated: true)
    }

    // MARK: - NSDK Setup

    private func setupNsdk() {
        setupNsdkAuth()
        nsdkManager?.startLocationService()
    }

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

    private func setupNsdkAuth() {
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
                    session.setRefreshToken("")
                    if let currentToken = AuthAccessManager.accessToken, !currentToken.isEmpty {
                        session.setAccessToken(currentToken)
                    }
                    accessTokenSubscription = AuthAccessManager.accessTokenUpdated.sink { [weak self] accessToken in
                        self?.nsdkManager?.session.setAccessToken(accessToken)
                    }
                } else {
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

        if needsAccessTokenSubscription {
            if let currentToken = AuthAccessManager.accessToken, !currentToken.isEmpty {
                nsdkManager?.session.setAccessToken(currentToken)
            }
            accessTokenSubscription = AuthAccessManager.accessTokenUpdated.sink { [weak self] accessToken in
                self?.nsdkManager?.session.setAccessToken(accessToken)
            }
        }
    }

    // MARK: - Filter

    @objc private func filterTextChanged() {
        filterText = searchTextField.text ?? ""
        applyFilter()
    }

    private func clearFilter() {
        filterText = ""
        searchTextField.text = ""
    }

    private func applyFilter() {
        for subview in buttonStackView.arrangedSubviews {
            if let button = subview as? UIButton {
                let title = button.title(for: .normal) ?? ""
                let isBackButton = title.hasPrefix("←")
                if filterText.isEmpty || isBackButton {
                    button.isHidden = false
                } else {
                    button.isHidden = !title.lowercased().contains(filterText.lowercased())
                }
            }
        }
    }

    // MARK: - Sites Manager

    private func setupSitesManager() {
        guard let nsdkSession = nsdkManager?.session else {
            print("Error: NSDK session not available")
            return
        }
        sitesManager = SitesManager(nsdk: nsdkSession)
        retryHelper = AuthRetryHelper(session: nsdkSession)
    }

    private func loadInitialData() {
        loadingTask = Task {
            do {
                await MainActor.run {
                    infoLabel.text = "⏳ Loading user info..."
                }

                let userResult = try await retryHelper?.withRetry {
                    try await sitesManager?.requestSelfUserInfo()
                }

                try Task.checkCancellation()

                guard let user = userResult?.user else {
                    await MainActor.run {
                        infoLabel.text = "❌ Failed to retrieve user information. Make sure you're authenticated."
                    }
                    return
                }

                await MainActor.run {
                    currentUser = user
                    updateInfoBox(with: user)
                }

                let orgsResult = try await retryHelper?.withRetry {
                    try await sitesManager?.requestOrganizationsForUser(userId: user.id)
                }

                try Task.checkCancellation()

                await MainActor.run {
                    if let orgs = orgsResult?.organizations {
                        currentOrganizations = orgs
                        createOrganizationButtons(orgs)
                    } else {
                        infoLabel.text = (infoLabel.text ?? "") + "\n\n⚠️ No organizations found"
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    infoLabel.text = "❌ Error loading data: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Info Box Updates

    private func updateInfoBox(with user: UserInfo) {
        var text = "👤 USER INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(user.firstName) \(user.lastName)\n"
        text += "ID: \(user.id)\n"
        text += "Email: \(user.email)\n"
        text += "Status: \(user.status)\n"
        text += "Created: \(formatTimestamp(user.createdTimestamp))\n"
        if let orgId = user.organizationId {
            text += "Organization ID: \(orgId)\n"
        }
        infoLabel.text = text
    }

    private func updateInfoBox(with org: OrganizationInfo) {
        var text = "🏢 ORGANIZATION INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(org.name)\n"
        text += "ID: \(org.id)\n"
        text += "Status: \(org.status)\n"
        text += "Created: \(formatTimestamp(org.createdTimestamp))\n"
        infoLabel.text = text
    }

    private func updateInfoBox(with site: SiteInfo) {
        var text = "📍 SITE INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(site.name)\n"
        text += "ID: \(site.id)\n"
        text += "Status: \(site.status)\n"
        text += "Organization ID: \(site.organizationId)\n"
        if site.hasLocation {
            text += "Location: (\(String(format: "%.6f", site.latitude)), \(String(format: "%.6f", site.longitude)))\n"
        } else {
            text += "Location: Not available\n"
        }
        if let parentId = site.parentSiteId {
            text += "Parent Site ID: \(parentId)\n"
        }
        infoLabel.text = text
    }

    private func updateInfoBox(with asset: AssetInfo) {
        var text = "📦 ASSET INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(asset.name)\n"
        text += "ID: \(asset.id)\n"
        text += "Type: \(asset.assetType)\n"
        text += "Status: \(asset.assetStatus)\n"
        text += "Site ID: \(asset.siteId)\n"
        if let desc = asset.description_ {
            text += "Description: \(desc)\n"
        }
        if asset.deployment != .unspecified {
            text += "Deployment: \(asset.deployment)\n"
        }
        if let jobId = asset.pipelineJobId {
            text += "Pipeline Job ID: \(jobId)\n"
        }
        if asset.pipelineJobStatus != .unspecified {
            text += "Pipeline Status: \(asset.pipelineJobStatus)\n"
        }
        if let meshData = asset.meshData {
            text += "Mesh Root Node ID: \(meshData.rootNodeId)\n"
            text += "Mesh Coverage: \(meshData.meshCoverage) m²\n"
            if !meshData.nodeIds.isEmpty {
                text += "Node IDs (\(meshData.nodeIds.count)): \(meshData.nodeIds.joined(separator: ", "))\n"
            }
        }
        if let splatData = asset.splatData {
            text += "Splat Root Node ID: \(splatData.rootNodeId)\n"
        }
        if let vpsData = asset.vpsData {
            text += "VPS Anchor Payload: \(vpsData.anchorPayload)\n"
        }
        if !asset.sourceScanIds.isEmpty {
            text += "Source Scan IDs (\(asset.sourceScanIds.count)): \(asset.sourceScanIds.joined(separator: ", "))\n"
        }
        infoLabel.text = text
    }

    private func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    // MARK: - Button Creation

    private func clearButtons() {
        buttonStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
    }

    private func createOrganizationButtons(_ orgs: [OrganizationInfo]) {
        clearButtons()

        let headerLabel = UILabel()
        headerLabel.text = "Select an Organization:"
        headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .label
        buttonStackView.addArrangedSubview(headerLabel)

        for org in orgs {
            let button = createStyledButton(title: org.name) { [weak self] in
                self?.organizationTapped(org)
            }
            buttonStackView.addArrangedSubview(button)
        }
    }

    private func createBackToOrganizationsOnly() {
        clearButtons()
        sitesLoadingIndicator = nil
        currentSitesWithAssets = []
        let backBtn = createStyledButton(title: "← Back to Organizations", color: .systemGray) { [weak self] in
            self?.backToOrganizations()
        }
        buttonStackView.addArrangedSubview(backBtn)
    }

    private func createSiteButtons(_ siteAssetPairs: [(SiteInfo, AssetInfo)]) {
        clearButtons()
        sitesLoadingIndicator = nil

        let backBtn = createStyledButton(title: "← Back to Organizations", color: .systemGray) { [weak self] in
            self?.backToOrganizations()
        }
        buttonStackView.addArrangedSubview(backBtn)

        let headerLabel = UILabel()
        headerLabel.text = "Select a Site (Localize):"
        headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .label
        buttonStackView.addArrangedSubview(headerLabel)

        for (site, _) in siteAssetPairs {
            let button = createStyledButton(title: site.name) { [weak self] in
                self?.siteTapped(site)
            }
            buttonStackView.addArrangedSubview(button)
        }
    }

    private func prepareSiteListIncremental(sitesToCheckCount: Int) {
        clearButtons()
        currentSitesWithAssets = []

        let backBtn = createStyledButton(title: "← Back to Organizations", color: .systemGray) { [weak self] in
            self?.backToOrganizations()
        }
        buttonStackView.addArrangedSubview(backBtn)

        let headerLabel = UILabel()
        headerLabel.text = "Select a Site (Localize):"
        headerLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        headerLabel.textColor = .label
        buttonStackView.addArrangedSubview(headerLabel)

        let loadingLabel = UILabel()
        loadingLabel.text = "Checking \(sitesToCheckCount) site(s)..."
        loadingLabel.font = .systemFont(ofSize: 14)
        loadingLabel.textColor = .secondaryLabel
        loadingLabel.translatesAutoresizingMaskIntoConstraints = false
        buttonStackView.addArrangedSubview(loadingLabel)
        sitesLoadingIndicator = loadingLabel
    }

    private func appendSiteButtonIncremental(site: SiteInfo, asset: AssetInfo) {
        currentSitesWithAssets.append((site, asset))
        let button = createStyledButton(title: site.name) { [weak self] in
            self?.siteTapped(site)
        }
        let insertIndex = max(0, buttonStackView.arrangedSubviews.count - 1)
        buttonStackView.insertArrangedSubview(button, at: insertIndex)
    }

    private func finishSitesLoading(totalChecked: Int) {
        sitesLoadingIndicator?.removeFromSuperview()
        sitesLoadingIndicator = nil
        if currentSitesWithAssets.isEmpty {
            infoLabel.text = (infoLabel.text ?? "") + "\n\n⚠️ No sites with Production VPS asset found"
        } else {
            infoLabel.text = (infoLabel.text ?? "") + "\n\nFound \(currentSitesWithAssets.count) site(s) (checked \(totalChecked))"
        }
    }

    private func createStyledButton(title: String, color: UIColor = .systemBlue, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = color
        button.layer.cornerRadius = 8
        button.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
        button.titleLabel?.numberOfLines = 0
        button.titleLabel?.textAlignment = .center
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 50).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    // MARK: - Navigation Actions

    private func organizationTapped(_ org: OrganizationInfo) {
        clearFilter()
        clearButtons()
        updateInfoBox(with: org)

        Task { [weak self] in
            guard let self else { return }
            do {
                await MainActor.run { self.infoLabel.text = (self.infoLabel.text ?? "") + "\n\n⏳ Loading sites for \(org.name)..." }

                let result = try await retryHelper?.withRetry {
                    try await sitesManager?.requestSitesForOrganization(orgId: org.id)
                }
                try Task.checkCancellation()

                guard let sites = result?.sites else {
                    await MainActor.run { self.infoLabel.text = (self.infoLabel.text ?? "") + "\n\n⚠️ No sites found" }
                    return
                }

                await MainActor.run {
                    self.prepareSiteListIncremental(sitesToCheckCount: sites.count)
                }

                try await withThrowingTaskGroup(of: (SiteInfo, AssetInfo)?.self) { group in
                    for site in sites {
                        group.addTask { [weak self] in
                            guard let self else { return nil }
                            let filterProduction = await MainActor.run { self.filterProduction }
                            try Task.checkCancellation()
                            do {
                                let assetsResult = try await self.retryHelper?.withRetry {
                                    try await self.sitesManager?.requestAssetsForSite(siteId: site.id)
                                }
                                guard let assets = assetsResult?.assets else { return nil }
                                if let vpsAsset = assets.first(where: { asset in
                                    guard let vps = asset.vpsData, !vps.anchorPayload.isEmpty else { return false }
                                    return asset.deployment == .production || !filterProduction
                                }) {
                                    return (site, vpsAsset)
                                }
                            } catch {
                                print("Failed to load assets for site \(site.name): \(error.localizedDescription)")
                            }
                            return nil
                        }
                    }
                    for try await pair in group {
                        try Task.checkCancellation()
                        if let pair {
                            await MainActor.run { [weak self] in
                                self?.appendSiteButtonIncremental(site: pair.0, asset: pair.1)
                            }
                        }
                    }
                }

                try Task.checkCancellation()
                await MainActor.run {
                    self.finishSitesLoading(totalChecked: sites.count)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.infoLabel.text = (self.infoLabel.text ?? "") + "\n\n❌ Error loading sites: \(error.localizedDescription)"
                    self.createBackToOrganizationsOnly()
                }
            }
        }
    }

    private func siteTapped(_ site: SiteInfo) {
        clearFilter()
        guard let pair = currentSitesWithAssets.first(where: { $0.0.id == site.id }) else {
            infoLabel.text = (infoLabel.text ?? "") + "\n\n⚠️ Site \(site.name) not found"
            return
        }
        let asset = pair.1
        guard let vpsData = asset.vpsData, !vpsData.anchorPayload.isEmpty else {
            infoLabel.text = (infoLabel.text ?? "") + "\n\n⚠️ No VPS payload found for \(site.name)"
            return
        }
        startVps2AndTrack(payload: vpsData.anchorPayload)
    }
    
    private func startVps2AndTrack(payload: String) {
        let vps2VC = VPS2ViewController()
        vps2VC.anchorPayload = payload
        vps2VC.nsdkManager = nsdkManager
        navigationController?.pushViewController(vps2VC, animated: true)
    }

    private func backToOrganizations() {
        clearFilter()
        if let user = currentUser {
            updateInfoBox(with: user)
        }
        createOrganizationButtons(currentOrganizations)
    }
}

// MARK: - UITextFieldDelegate
extension SitesViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}
