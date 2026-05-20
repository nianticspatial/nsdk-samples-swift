// Copyright 2026 Niantic Spatial.

import Combine
import CoreLocation
import NSDK
import UIKit

final class SitesViewController: UIViewController {

    private let arManager: ARManager
    private var sitesSession: NSDKSitesSession!
    private var viewModel: SitesViewModel!

    private var cancellables = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private lazy var locationManager = CLLocationManager()

    // Stored text fields for the Near Me input form
    private var sitesNearMeLatField: UITextField?
    private var sitesNearMeLngField: UITextField?
    private var sitesNearMeRadiusField: UITextField?

    private static let defaultLat = 0.0
    private static let defaultLng = 0.0
    private static let defaultRadius = 1000.0

    private let sessionInfoView = UIView()
    private let sessionInfoLabel = UILabel()
    private let helpOverlay = HelpOverlayView(helpText: SitesViewController.helpText)

    private let infoContainer = UIView()
    private let infoLabel = UILabel()
    private let searchTextField = UITextField()
    private let outerScrollView = UIScrollView()
    private let contentStackView = UIStackView()
    private let buttonStackView = UIStackView()

    init(arManager: ARManager) {
        self.arManager = arManager
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = "Sites Manager"

        setupUI()

        sitesSession = arManager.nsdkSession.acquireSitesSession()

        let retry = AuthRetryHelper(session: arManager.nsdkSession)
        viewModel = SitesViewModel(sitesSession: sitesSession, retryHelper: retry)

        bindViewModel()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        loadTask?.cancel()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isMovingFromParent {
            arManager.nsdkSession.destroy(sitesSession)
        }
    }

    private static let helpText =
        "VPS2 Sites Sample Help\n\n" +
        "This sample demonstrates the Sites Manager API for browsing organizations and sites.\n\n" +
        "TO USE:\n" +
        "1. Select an organization from your user's organizations\n" +
        "2. Select a site (only sites with a Production VPS asset are shown)\n" +
        "3. VPS2 localization starts immediately for the selected site\n\n" +
        "You can filter items by name using the search field. "

    // MARK: - Bindings

    private func bindViewModel() {
        viewModel.$infoPanelText
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in
                self?.infoLabel.text = text
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            viewModel.$listMode,
            viewModel.$organizations,
            viewModel.$showSitesFailureRecovery,
            viewModel.$siteAssetPairs
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _, _, _, _ in
            self?.rebuildButtonList()
        }
        .store(in: &cancellables)

        viewModel.$sitesLoadProgress
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildButtonList()
            }
            .store(in: &cancellables)

        viewModel.$sitesNearMeSitePayloadPairs
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.rebuildButtonList()
            }
            .store(in: &cancellables)
    }

    private func rebuildButtonList() {
        clearButtons()
        let savedLat = sitesNearMeLatField?.text ?? String(Self.defaultLat)
        let savedLng = sitesNearMeLngField?.text ?? String(Self.defaultLng)
        let savedRadius = sitesNearMeRadiusField?.text ?? String(Self.defaultRadius)
        sitesNearMeLatField = nil
        sitesNearMeLngField = nil
        sitesNearMeRadiusField = nil

        // Show or hide the info container based on mode
        if case .modeSelection = viewModel.listMode {
            infoContainer.isHidden = true
        } else {
            infoContainer.isHidden = false
        }

        if viewModel.showSitesFailureRecovery {
            buttonStackView.addArrangedSubview(makeBackToOrganizationsButton())
            return
        }

        switch viewModel.listMode {
        case .modeSelection:
            let header = makeHeader("How would you like to find VPS sites?")
            buttonStackView.addArrangedSubview(header)

            let sitesNearMeBtn = createStyledButton(title: "🌍  Display Sites Near Me", color: .systemGreen) { [weak self] in
                self?.viewModel.startNearMeFlow()
            }
            buttonStackView.addArrangedSubview(sitesNearMeBtn)

            let fromOrgsBtn = createStyledButton(title: "🏢  Display Sites From Orgs") { [weak self] in
                guard let self else { return }
                self.loadTask?.cancel()
                self.loadTask = Task { await self.viewModel.startFromOrgsFlow() }
            }
            buttonStackView.addArrangedSubview(fromOrgsBtn)

        case .sitesNearMe:
            let backBtn = createStyledButton(title: "← Back to Mode Selection", color: .systemGray) { [weak self] in
                self?.viewModel.backToModeSelection()
            }
            buttonStackView.addArrangedSubview(backBtn)

            // Coordinate input fields
            let latField = makeCoordinateField(placeholder: "Latitude", defaultValue: savedLat)
            let lngField = makeCoordinateField(placeholder: "Longitude", defaultValue: savedLng)
            let radiusField = makeCoordinateField(placeholder: "Radius (meters)", defaultValue: savedRadius)
            sitesNearMeLatField = latField
            sitesNearMeLngField = lngField
            sitesNearMeRadiusField = radiusField

            buttonStackView.addArrangedSubview(makeLabeledField(label: "Latitude", field: latField))
            buttonStackView.addArrangedSubview(makeLabeledField(label: "Longitude", field: lngField))
            buttonStackView.addArrangedSubview(makeLabeledField(label: "Radius (meters)", field: radiusField))

            let useLocationBtn = createStyledButton(title: "📍  Use My Location", color: .systemBlue) { [weak self] in
                self?.useMyLocation()
            }
            buttonStackView.addArrangedSubview(useLocationBtn)

            let searchBtn = createStyledButton(title: "Search Nearby Sites", color: .systemGreen) { [weak self] in
                self?.searchNearMeSites()
            }
            buttonStackView.addArrangedSubview(searchBtn)

            if let warning = viewModel.sitesNearMeWarning {
                let warningLabel = UILabel()
                warningLabel.text = "⚠️ \(warning)"
                warningLabel.font = .systemFont(ofSize: 14)
                warningLabel.textColor = .systemOrange
                warningLabel.numberOfLines = 0
                buttonStackView.addArrangedSubview(warningLabel)
            }

            if !viewModel.sitesNearMeSitePayloadPairs.isEmpty {
                buttonStackView.addArrangedSubview(makeHeader("VPS Sites Near You (\(viewModel.sitesNearMeSitePayloadPairs.count)):"))
                for (site, payload) in viewModel.sitesNearMeSitePayloadPairs {
                    let p = payload
                    let button = createStyledButton(title: site.name) { [weak self] in
                        self?.launchVPS2(anchorPayload: p)
                    }
                    buttonStackView.addArrangedSubview(button)
                }
            }

        case .organizations:
            buttonStackView.addArrangedSubview(
                createStyledButton(title: "← Back to Mode Selection", color: .systemGray) { [weak self] in
                    self?.viewModel.backToModeSelection()
                }
            )
            buttonStackView.addArrangedSubview(makeHeader("Select an Organization:"))
            for org in viewModel.organizations {
                let button = createStyledButton(title: org.name) { [weak self] in
                    guard let self else { return }
                    self.loadTask?.cancel()
                    self.loadTask = Task { await self.viewModel.selectOrganization(org) }
                }
                buttonStackView.addArrangedSubview(button)
            }

        case .sites:
            buttonStackView.addArrangedSubview(makeBackToOrganizationsButton())
            buttonStackView.addArrangedSubview(makeHeader("Select a Site (Localize):"))

            if let progress = viewModel.sitesLoadProgress {
                let loading = UILabel()
                loading.text = "Checking \(progress.loaded) / \(progress.total) site(s)..."
                loading.font = .systemFont(ofSize: 14)
                loading.textColor = .secondaryLabel
                buttonStackView.addArrangedSubview(loading)
            }

            for (site, _) in viewModel.siteAssetPairs {
                let button = createStyledButton(title: site.name) { [weak self] in
                    self?.siteTapped(site)
                }
                buttonStackView.addArrangedSubview(button)
            }
        }

        applyFilter()
    }

    private func useMyLocation() {
        locationManager.delegate = self
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            // Note: on iOS 14+, if the user grants "Approximate Location", the OS silently
            // caps accuracy to ~1 km regardless of this setting.
            locationManager.desiredAccuracy = kCLLocationAccuracyBest
            locationManager.requestLocation()
        default:
            break
        }
    }

    private func searchNearMeSites() {
        let lat = Double(sitesNearMeLatField?.text ?? "") ?? Self.defaultLat
        let lng = Double(sitesNearMeLngField?.text ?? "") ?? Self.defaultLng
        let radius = Double(sitesNearMeRadiusField?.text ?? "") ?? Self.defaultRadius
        loadTask?.cancel()
        loadTask = Task { await viewModel.loadNearMeSites(lat: lat, lng: lng, radiusMeters: radius) }
    }

    private func launchVPS2(anchorPayload: String) {
        clearFilter()
        let vps = VPS2ViewController(arManager: arManager)
        vps.anchorPayload = anchorPayload
        navigationController?.pushViewController(vps, animated: true)
    }

    private func makeBackToOrganizationsButton() -> UIButton {
        createStyledButton(title: "← Back to Organizations", color: .systemGray) { [weak self] in
            self?.viewModel.backToOrganizations()
        }
    }

    private func makeCoordinateField(placeholder: String, defaultValue: String) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.text = defaultValue
        field.borderStyle = .roundedRect
        field.backgroundColor = .systemGray6
        field.keyboardType = .numbersAndPunctuation
        field.returnKeyType = .done
        field.delegate = self
        return field
    }

    private func makeLabeledField(label: String, field: UITextField) -> UIView {
        let container = UIView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let labelView = UILabel()
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.text = label
        labelView.font = .systemFont(ofSize: 13, weight: .medium)
        labelView.textColor = .secondaryLabel
        container.addSubview(labelView)

        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)

        NSLayoutConstraint.activate([
            labelView.topAnchor.constraint(equalTo: container.topAnchor),
            labelView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            labelView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: 4),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.heightAnchor.constraint(equalToConstant: 44),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }

    private func makeHeader(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = .label
        return label
    }

    private func siteTapped(_ site: SiteInfo) {
        clearFilter()
        viewModel.applySiteSelection(site)
        guard let payload = viewModel.anchorPayload(for: site.id) else {
            infoLabel.text = (infoLabel.text ?? "") + "\n\n⚠️ No VPS payload found for \(site.name)"
            return
        }
        let vps = VPS2ViewController(arManager: arManager)
        vps.anchorPayload = payload
        navigationController?.pushViewController(vps, animated: true)
    }

    // MARK: - UI Setup (aligned with SitesViewController)

    private func setupUI() {
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

        helpOverlay.setup(in: view, anchoredBelow: sessionInfoView.bottomAnchor, navigationItem: navigationItem)

        infoContainer.translatesAutoresizingMaskIntoConstraints = false
        infoContainer.backgroundColor = UIColor.systemGray6
        infoContainer.layer.cornerRadius = 8
        infoContainer.clipsToBounds = true

        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.textColor = .label
        infoLabel.textAlignment = .left
        infoLabel.font = .systemFont(ofSize: 14)
        infoLabel.numberOfLines = 0
        infoContainer.addSubview(infoLabel)

        searchTextField.translatesAutoresizingMaskIntoConstraints = false
        searchTextField.placeholder = "Filter..."
        searchTextField.borderStyle = .roundedRect
        searchTextField.backgroundColor = .systemGray6
        searchTextField.clearButtonMode = .whileEditing
        searchTextField.returnKeyType = .done
        searchTextField.addTarget(self, action: #selector(filterTextChanged), for: .editingChanged)
        searchTextField.delegate = self

        buttonStackView.axis = .vertical
        buttonStackView.spacing = 12
        buttonStackView.translatesAutoresizingMaskIntoConstraints = false

        contentStackView.axis = .vertical
        contentStackView.spacing = 12
        contentStackView.translatesAutoresizingMaskIntoConstraints = false
        contentStackView.addArrangedSubview(infoContainer)
        contentStackView.addArrangedSubview(searchTextField)
        contentStackView.addArrangedSubview(buttonStackView)

        outerScrollView.translatesAutoresizingMaskIntoConstraints = false
        outerScrollView.showsVerticalScrollIndicator = true
        view.addSubview(outerScrollView)
        outerScrollView.addSubview(contentStackView)

        NSLayoutConstraint.activate([
            sessionInfoView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            sessionInfoView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 10),
            sessionInfoView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -10),
            sessionInfoView.heightAnchor.constraint(equalToConstant: 44),

            sessionInfoLabel.topAnchor.constraint(equalTo: sessionInfoView.topAnchor, constant: 4),
            sessionInfoLabel.bottomAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: -4),
            sessionInfoLabel.leadingAnchor.constraint(equalTo: sessionInfoView.leadingAnchor, constant: 8),
            sessionInfoLabel.trailingAnchor.constraint(equalTo: sessionInfoView.trailingAnchor, constant: -8),

            outerScrollView.topAnchor.constraint(equalTo: sessionInfoView.bottomAnchor, constant: 12),
            outerScrollView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            outerScrollView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            outerScrollView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -20),

            contentStackView.topAnchor.constraint(equalTo: outerScrollView.topAnchor, constant: 8),
            contentStackView.leadingAnchor.constraint(equalTo: outerScrollView.leadingAnchor),
            contentStackView.trailingAnchor.constraint(equalTo: outerScrollView.trailingAnchor),
            contentStackView.bottomAnchor.constraint(equalTo: outerScrollView.bottomAnchor, constant: -8),
            contentStackView.widthAnchor.constraint(equalTo: outerScrollView.widthAnchor),

            infoContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            infoLabel.topAnchor.constraint(equalTo: infoContainer.topAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: infoContainer.leadingAnchor, constant: 12),
            infoLabel.trailingAnchor.constraint(equalTo: infoContainer.trailingAnchor, constant: -12),
            infoLabel.bottomAnchor.constraint(equalTo: infoContainer.bottomAnchor, constant: -12),

            searchTextField.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @objc private func filterTextChanged() {
        applyFilter()
    }

    private func clearFilter() {
        searchTextField.text = ""
        applyFilter()
    }

    private func applyFilter() {
        let filterText = (searchTextField.text ?? "").lowercased()
        for subview in buttonStackView.arrangedSubviews {
            if let button = subview as? UIButton {
                let title = button.title(for: .normal) ?? ""
                let isBackButton = title.hasPrefix("←")
                if filterText.isEmpty || isBackButton {
                    button.isHidden = false
                } else {
                    button.isHidden = !title.lowercased().contains(filterText)
                }
            }
        }
    }

    private func clearButtons() {
        buttonStackView.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
}

extension SitesViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }
}

extension SitesViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        if manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways {
            manager.desiredAccuracy = kCLLocationAccuracyBest
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        sitesNearMeLatField?.text = String(format: "%.6f", location.coordinate.latitude)
        sitesNearMeLngField?.text = String(format: "%.6f", location.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        print("[SitesViewController] Location error: \(error.localizedDescription)")
    }
}
