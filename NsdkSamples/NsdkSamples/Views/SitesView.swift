// Copyright 2026 Niantic Spatial.

import CoreLocation
import SwiftUI
import NSDK

struct SitesView: View {

    let arManager: ARManager

    // MARK: - State

    @State private var viewModel: SitesViewModel?
    @State private var sitesSession: NSDKSitesSession?

    @State private var searchText = ""
    @State private var vps2Destination: VPS2Destination?

    @State private var nearMeLat = String(defaultLat)
    @State private var nearMeLng = String(defaultLng)
    // Lat/lng are shared by both flows; the radius is not — localization keeps assets
    // loaded for the session, so it starts much smaller than search.
    @State private var nearMeRadius = String(defaultRadius)
    @State private var localizeRadius = String(defaultLocalizeRadius)
    // Local because SitesViewModel.sitesNearMeWarning is private(set) and search-specific.
    @State private var nearMeInputError: String?

    @State private var isHelpVisible = false
    @State private var locationProvider = LocationProvider()

    private static let defaultLat = 0.0
    private static let defaultLng = 0.0
    private static let defaultRadius = 1000.0
    private static let defaultLocalizeRadius = 100.0

    private struct VPS2Destination: Identifiable, Hashable {
        let target: VPS2LocalizationTarget
        /// The site's VPS assets, for the VPS2 screen's Switch Asset menu. Empty for nearby.
        let siteAssets: [VPS2AssetChoice]
        // Stored as raw degrees: CLLocationCoordinate2D is not Hashable, and
        // navigationDestination(item:) needs this type to be.
        private let latitude: Double?
        private let longitude: Double?

        /// Namespaced by case: the nearby case has no siteId, so a shared key space would collide.
        var id: String {
            switch target {
            case .site(let siteId, let assetId):
                return "site:\(siteId):\(assetId)"
            case .nearby(let lat, let lng, let radius):
                return "nearby:\(lat):\(lng):\(radius)"
            }
        }

        /// Localize against one already-chosen VPS asset of a site. `listed` is the list the
        /// asset was picked from; the site's other entries in it are what it can switch to.
        init(pair: SiteWithVpsAsset, listed: [SiteWithVpsAsset]) {
            target = .site(id: pair.site.id, assetId: pair.asset.id)
            siteAssets = listed.filter { $0.site.id == pair.site.id }.map { VPS2AssetChoice(asset: $0.asset) }
            latitude = pair.site.location?.latitude
            longitude = pair.site.location?.longitude
        }

        /// Localize against every VPS site within `radiusMeters` — no site chosen.
        init(latitude: Double, longitude: Double, radiusMeters: Double) {
            target = .nearby(latitude: latitude, longitude: longitude, radiusMeters: radiusMeters)
            siteAssets = []
            self.latitude = latitude
            self.longitude = longitude
        }

        /// Map pin: the site's location, or the entered center for the nearby case.
        var poiCoordinate: CLLocationCoordinate2D? {
            guard let latitude, let longitude else { return nil }
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    // MARK: - Help

    private static let helpText =
        "VPS2 Sites Sample Help\n\n" +
        "This sample demonstrates the Sites Manager API for browsing organizations and sites.\n\n" +
        "TO USE:\n" +
        "1. Select an organization from your user's organizations\n" +
        "2. Select a VPS asset. Each is marked Production or Not production. The Production / " +
        "All assets toggle picks whether non-production assets are listed too\n" +
        "3. Tap \"Localize to Asset\" on the next screen to start localization. While it runs, " +
        "\"Stop Localizing\" stops it and \"Switch Asset\" moves to another VPS asset of the site\n\n" +
        "You can filter items by name using the search field. "

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                ScrollView {
                    VStack(spacing: 12) {
                        if let viewModel {
                            if showsInfoPanel(viewModel) {
                                infoPanel(viewModel.infoPanelText)
                            }
                            if showsFilterField(viewModel) {
                                filterField
                            }
                            listContent(viewModel)
                        }
                    }
                    .padding(20)
                }

                if let viewModel, viewModel.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                HelpOverlayView(helpText: Self.helpText, isVisible: $isHelpVisible)
            }
        }
        .background(Color(.systemBackground))
        .navigationTitle("Sites Manager")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Help") { isHelpVisible.toggle() }
            }
        }
        .navigationDestination(item: $vps2Destination) { destination in
            VPS2View(
                arManager: arManager,
                target: destination.target,
                siteAssets: destination.siteAssets,
                poiCoordinate: destination.poiCoordinate
            )
        }
        .onAppear { setup() }
        .onDisappear { teardown() }
    }

    // MARK: - Info panel

    private func showsInfoPanel(_ viewModel: SitesViewModel) -> Bool {
        if case .modeSelection = viewModel.listMode { return false }
        return true
    }

    /// Only shown for modes that render a filterable list.
    private func showsFilterField(_ viewModel: SitesViewModel) -> Bool {
        switch viewModel.listMode {
        case .modeSelection, .localizeNearMe: return false
        case .organizations, .sites, .sitesNearMe: return true
        }
    }

    private func infoPanel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, minHeight: 100, alignment: .topLeading)
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(8)
    }

    // MARK: - Filter field

    private var filterField: some View {
        FilterField(text: $searchText)
    }

    // MARK: - Near Me inputs (shared by the search and direct-localize flows)

    @ViewBuilder
    private func nearMeCoordinateFields(radius: Binding<String>) -> some View {
        labeledField("Latitude", text: $nearMeLat)
        labeledField("Longitude", text: $nearMeLng)
        labeledField("Radius (meters)", text: radius)
    }

    private var useDeviceLocationButton: some View {
        styledButton(arManager.isPlayback ? "📍  Use Playback Location" : "📍  Use Device Location",
                     color: Color(.systemBlue)) {
            // Prefer the SDK location (running-frame GPS in playback, device fix in live, or
            // the dataset's recorded location before playback runs). Fall back to CoreLocation
            // only when the SDK has nothing yet (e.g. live mode before the first fix).
            if let location = sdkLocation() {
                nearMeLat = String(format: "%.6f", location.latitude)
                nearMeLng = String(format: "%.6f", location.longitude)
            } else {
                locationProvider.requestLocation { lat, lng in
                    nearMeLat = String(format: "%.6f", lat)
                    nearMeLng = String(format: "%.6f", lng)
                }
            }
        }
    }

    // MARK: - List content (mirrors rebuildButtonList)

    @ViewBuilder
    private func listContent(_ viewModel: SitesViewModel) -> some View {
        if viewModel.showSitesFailureRecovery {
            backToOrganizationsButton(viewModel)
        } else {
            switch viewModel.listMode {
            case .modeSelection:
                header("How would you like to find VPS sites?")
                styledButton("🌍  Display Sites Near Me", color: Color(.systemGreen)) {
                    nearMeInputError = nil
                    viewModel.startNearMeFlow()
                }
                styledButton("🏢  Display Sites From Orgs") {
                    viewModel.startFromOrgsFlow()
                }
                styledButton("🎯  Localize Near Me", color: Color(.systemPurple)) {
                    nearMeInputError = nil
                    viewModel.startLocalizeNearMeFlow()
                }

            case .sitesNearMe:
                styledButton("← Back to Mode Selection", color: Color(.systemGray)) {
                    viewModel.backToModeSelection()
                }
                nearMeCoordinateFields(radius: $nearMeRadius)
                useDeviceLocationButton
                assetScopePicker(viewModel)
                styledButton("Search Nearby Sites", color: Color(.systemGreen)) {
                    searchNearMeSites(viewModel)
                }
                if let nearMeInputError {
                    Text("⚠️ \(nearMeInputError)")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let warning = viewModel.sitesNearMeWarning {
                    Text("⚠️ \(warning)")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let nearby = viewModel.sitesNearMeResults
                if !nearby.isEmpty {
                    header("VPS Assets Near You (\(nearby.count)):")
                    ForEach(nearby.indices, id: \.self) { i in
                        let item = nearby[i]
                        if nameMatches(item.site.name) {
                            styledButton(assetLabel(item)) {
                                vps2Destination = VPS2Destination(pair: item, listed: nearby)
                            }
                        }
                    }
                }

            case .localizeNearMe:
                styledButton("← Back to Mode Selection", color: Color(.systemGray)) {
                    viewModel.backToModeSelection()
                }
                nearMeCoordinateFields(radius: $localizeRadius)
                useDeviceLocationButton
                Text("Localizes against every VPS site within the radius. Matched assets stay "
                     + "loaded for the session, so prefer a small radius (default 100 m).")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                styledButton("Start", color: Color(.systemPurple)) {
                    localizeThisArea()
                }
                if let nearMeInputError {
                    Text("⚠️ \(nearMeInputError)")
                        .font(.system(size: 14))
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

            case .organizations:
                styledButton("← Back to Mode Selection", color: Color(.systemGray)) {
                    viewModel.backToModeSelection()
                }
                header("Select an Organization:")
                ForEach(viewModel.organizations, id: \.id) { org in
                    if nameMatches(org.name) {
                        styledButton(org.name) {
                            viewModel.selectOrganization(org)
                        }
                    }
                }

            case .sites:
                backToOrganizationsButton(viewModel)
                assetScopePicker(viewModel)
                header("Select a VPS Asset (Localize):")
                if let progress = viewModel.sitesLoadProgress {
                    Text("Checking \(progress.loaded) / \(progress.total) site(s)...")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // One row per asset: a site can have several, in different deployments.
                ForEach(viewModel.siteAssetPairs, id: \.asset.id) { pair in
                    if nameMatches(pair.site.name) {
                        styledButton(assetLabel(pair)) {
                            assetTapped(pair, viewModel)
                        }
                    }
                }
            }
        }
    }

    /// Production assets only, or every asset. Changing it re-runs the list on screen.
    private func assetScopePicker(_ viewModel: SitesViewModel) -> some View {
        Picker("Assets", selection: Binding(
            get: { viewModel.assetScope },
            set: { viewModel.setAssetScope($0) }
        )) {
            Text("Production").tag(AssetScope.production)
            Text("All assets").tag(AssetScope.all)
        }
        .pickerStyle(.segmented)
    }

    private func backToOrganizationsButton(_ viewModel: SitesViewModel) -> some View {
        styledButton("← Back to Organizations", color: Color(.systemGray)) {
            viewModel.backToOrganizations()
        }
    }

    // MARK: - Reusable styled components (mirror VC styling)

    /// The site's name over the VPS asset's name and whether it is in production, with the
    /// asset's area count when the map is split.
    ///
    /// A scan too large for one mapping run is published as several areas, each with its own
    /// anchor and extent, and VPS2 localizes against whichever one the device is standing in.
    /// Only said above 1: one area is the ordinary case and would be noise on every row.
    private func assetLabel(_ pair: SiteWithVpsAsset) -> String {
        let areaCount = pair.asset.areas.count
        let areas = areaCount > 1 ? " · \(areaCount) areas" : ""
        return "\(pair.site.name)\n\(pair.asset.name) · \(deploymentLabel(pair.asset.deployment))\(areas)"
    }

    private func styledButton(_ title: String, color: Color = Color(.systemBlue), action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 50)
                .background(color)
                .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func header(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundColor(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func labeledField(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.secondary)
            TextField("", text: text)
                .keyboardType(.numbersAndPunctuation)
                .textFieldStyle(.roundedBorder)
                .frame(height: 44)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Actions

    private func nameMatches(_ name: String) -> Bool {
        searchText.isEmpty || name.lowercased().contains(searchText.lowercased())
    }

    private func assetTapped(_ pair: SiteWithVpsAsset, _ viewModel: SitesViewModel) {
        searchText = ""
        viewModel.applySelection(pair)
        vps2Destination = VPS2Destination(pair: pair, listed: viewModel.siteAssetPairs)
    }

    /// Strictly parses the coordinate fields and `radiusText`. Returns nil and sets
    /// `nearMeInputError` on unparseable or out-of-range input — falling back to a default
    /// would silently search or localize (0, 0).
    private func validatedNearMeInputs(
        radius radiusText: String
    ) -> (latitude: Double, longitude: Double, radiusMeters: Double)? {
        guard let latitude = Double(nearMeLat),
              let longitude = Double(nearMeLng),
              let radiusMeters = Double(radiusText),
              (-90...90).contains(latitude),
              (-180...180).contains(longitude),
              radiusMeters.isFinite, radiusMeters >= 0 else {
            nearMeInputError = "Enter a valid latitude (-90…90), longitude (-180…180) and radius (≥ 0)."
            return nil
        }
        nearMeInputError = nil
        return (latitude, longitude, radiusMeters)
    }

    private func searchNearMeSites(_ viewModel: SitesViewModel) {
        guard let inputs = validatedNearMeInputs(radius: nearMeRadius) else { return }
        viewModel.loadNearMeSites(
            lat: inputs.latitude, lng: inputs.longitude, radiusMeters: inputs.radiusMeters)
    }

    /// Pushes VPS2View to localize the entered area. Out-of-range input would otherwise
    /// throw inside VPS2View's retry loop, leaving the user with no button and no feedback.
    private func localizeThisArea() {
        guard let inputs = validatedNearMeInputs(radius: localizeRadius) else { return }
        searchText = ""
        vps2Destination = VPS2Destination(
            latitude: inputs.latitude, longitude: inputs.longitude, radiusMeters: inputs.radiusMeters)
    }

    /// Location for the "Use … Location" button: the active data source's GPS, or the playback
    /// dataset's first recorded fix when there is none yet. Nil when neither is available.
    private func sdkLocation() -> (latitude: Double, longitude: Double)? {
        guard let gps = arManager.latestGpsSample() ?? recordedStartGps() else { return nil }
        return (gps.latitude, gps.longitude)
    }

    /// The playback dataset's first recorded GPS fix.
    private func recordedStartGps() -> NSDKFrameData.GpsData? {
        guard let dataset = arManager.playbackDataset else { return nil }
        for index in 0..<dataset.info.frameCount {
            if let gps = try? dataset.getPlaybackFrameMetadataAtIndex(index: index).gpsData {
                return gps
            }
        }
        return nil
    }

    // MARK: - Lifecycle

    private func setup() {
        guard viewModel == nil else { return }
        let session = arManager.nsdkSession.acquireSitesSession()
        sitesSession = session
        let retry = AuthRetryHelper(session: arManager.nsdkSession)
        viewModel = SitesViewModel(sitesSession: session, retryHelper: retry)
    }

    private func teardown() {
        // Cancel any in-flight "Use My Location" request so a late callback (e.g. the GPS
        // service booting after this view is gone) can't mutate detached @State and drive a
        // spurious view rebuild — which would construct a second NSDKSession and crash.
        locationProvider.invalidate()
        viewModel?.cancelLoading()
        if let sitesSession {
            arManager.nsdkSession.destroy(sitesSession)
        }
        sitesSession = nil
        viewModel = nil
    }
}
