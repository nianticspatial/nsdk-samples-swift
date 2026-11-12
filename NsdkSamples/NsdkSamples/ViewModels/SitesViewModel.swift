// Copyright 2026 Niantic Spatial.

import Foundation
import NSDK
import Observation

/// A site with one of its VPS assets, production or not (for localization).
struct SiteWithVpsAsset {
    let site: SiteInfo
    let asset: AssetInfo
}

/// Drives Sites API flows using NSDKSitesSession and AuthRetryHelper.
///
/// Publishes:
/// - `listMode` (`ListMode`): whether showing organizations or sites. Initially `.organizations`. Changes on drill-down or back navigation.
/// - `organizations` (`[OrganizationInfo]`): loaded organizations. Initially empty. Set after `loadInitialData()` completes.
/// - `siteAssetPairs` (`[SiteWithVpsAsset]`): the VPS assets of the organization's sites in
///   `assetScope`, one entry per asset. Initially empty. Populated incrementally during `selectOrganization()`.
/// - `infoPanelText` (`String`): formatted info panel content. Initially `""`. Updated on every API call or user selection.
/// - `sitesLoadProgress` (`(loaded: Int, total: Int)?`): incremental loading progress. Initially `nil`. Non-nil only while sites are being fetched.
/// - `showSitesFailureRecovery` (`Bool`): whether to show failure recovery UI. Initially `false`. Set to `true` on sites load error.
/// - `assetScope` (`AssetScope`): which deployments the lists show. Initially `.production`. Set by `setAssetScope(_:)`,
///   which re-runs the list on screen.
@Observable
final class SitesViewModel {

    enum ListMode {
        case modeSelection
        case organizations
        case sites(organization: OrganizationInfo)
        case sitesNearMe
        case localizeNearMe
    }

    // MARK: - Published UI state

    private(set) var listMode: ListMode = .modeSelection
    private(set) var organizations: [OrganizationInfo] = []
    private(set) var siteAssetPairs: [SiteWithVpsAsset] = []
    private(set) var sitesLoadProgress: (loaded: Int, total: Int)?
    private(set) var infoPanelText: String = ""

    private(set) var showSitesFailureRecovery: Bool = false
    private(set) var assetScope: AssetScope = .production

    /// Whether an async load (organizations, sites, or near-me search) is in flight.
    private(set) var isLoading: Bool = false

    // Near Me state: the nearby sites' VPS assets in assetScope, for direct VPS2 launch
    private(set) var sitesNearMeResults: [SiteWithVpsAsset] = []
    private(set) var sitesNearMeWarning: String?

    // MARK: - Private

    @ObservationIgnored private let sitesSession: NSDKSitesSession
    @ObservationIgnored private let retryHelper: AuthRetryHelper
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    /// The last near-me search, so a scope change can re-run it.
    @ObservationIgnored private var lastNearMeSearch: (lat: Double, lng: Double, radiusMeters: Double)?

    // MARK: - Initialization

    init(sitesSession: NSDKSitesSession, retryHelper: AuthRetryHelper) {
        self.sitesSession = sitesSession
        self.retryHelper = retryHelper
    }

    // MARK: - Load task management

    /// Runs `work` as the single in-flight load task, cancelling any previous one.
    /// `isLoading` is held across a cancel→replace handoff: only the most recent
    /// (uncancelled) task clears it, so a superseded task can't switch it off
    /// underneath its replacement.
    private func runExclusive(_ work: @escaping () async -> Void) {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.isLoading = true
            await work()
            guard !Task.isCancelled else { return }
            self.isLoading = false
            self.loadTask = nil
        }
    }

    func cancelLoading() {
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
    }

    // MARK: - Info panel formatting

    func infoText(for user: UserInfo) -> String {
        var text = "👤 USER INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(user.firstName) \(user.lastName)\n"
        text += "ID: \(user.id)\n"
        text += "Email: \(user.email)\n"
        text += "Status: \(user.status)\n"
        text += "Created: \(Self.formatTimestamp(user.createdTimestamp))\n"
        return text
    }

    func infoText(for org: OrganizationInfo) -> String {
        var text = "🏢 ORGANIZATION INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(org.name)\n"
        text += "ID: \(org.id)\n"
        text += "Status: \(org.status)\n"
        text += "Created: \(Self.formatTimestamp(org.createdTimestamp))\n"
        return text
    }

    func infoText(for site: SiteInfo) -> String {
        var text = "📍 SITE INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(site.name)\n"
        text += "ID: \(site.id)\n"
        text += "Status: \(site.status)\n"
        text += "Organization ID: \(site.organizationId)\n"
        if let location = site.location {
            text += "Location: (\(String(format: "%.6f", location.latitude)), \(String(format: "%.6f", location.longitude)))\n"
        } else {
            text += "Location: Not available\n"
        }
        if let parentId = site.parentSiteId {
            text += "Parent Site ID: \(parentId)\n"
        }
        return text
    }

    func infoText(for asset: AssetInfo) -> String {
        var text = "📦 ASSET INFORMATION\n"
        text += "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
        text += "Name: \(asset.name)\n"
        text += "ID: \(asset.id)\n"
        text += "Type: \(asset.assetType)\n"
        text += "Status: \(asset.assetStatus)\n"
        text += "Site ID: \(asset.siteId)\n"
        if let desc = asset.description {
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

        // Said only when the map is split. The typed data below describes areas[0] alone, so
        // knowing there are others is what explains why it covers less than the whole asset.
        if asset.areas.count > 1 {
            text += "Areas: \(asset.areas.count)\n"
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
        return text
    }

    // MARK: - Mode Selection

    func startFromOrgsFlow() {
        listMode = .organizations
        runExclusive { [weak self] in
            await self?.loadInitialData()
        }
    }

    func startNearMeFlow() {
        lastNearMeSearch = nil
        sitesNearMeResults = []
        sitesNearMeWarning = nil
        listMode = .sitesNearMe
    }

    /// Enters the direct area-localization flow. VPS2View does the localizing, so no
    /// Sites API call is needed here.
    func startLocalizeNearMeFlow() {
        infoPanelText = "Enter a coordinate and radius, then localize against every VPS site in that area."
        listMode = .localizeNearMe
    }

    /// Switches `assetScope` and re-runs the list on screen with it.
    func setAssetScope(_ scope: AssetScope) {
        guard scope != assetScope else { return }
        assetScope = scope
        switch listMode {
        case .sitesNearMe:
            if let search = lastNearMeSearch {
                loadNearMeSites(lat: search.lat, lng: search.lng, radiusMeters: search.radiusMeters)
            }
        case .sites(let organization):
            selectOrganization(organization)
        case .modeSelection, .organizations, .localizeNearMe:
            break
        }
    }

    func backToModeSelection() {
        cancelLoading()
        listMode = .modeSelection
        infoPanelText = ""
    }

    // MARK: - Near Me Loading

    func loadNearMeSites(lat: Double, lng: Double, radiusMeters: Double) {
        runExclusive { [weak self] in
            await self?.performNearMeSearch(lat: lat, lng: lng, radiusMeters: radiusMeters)
        }
    }

    private func performNearMeSearch(lat: Double, lng: Double, radiusMeters: Double) async {
        infoPanelText = "⏳ Searching for VPS sites within \(Int(radiusMeters))m..."
        lastNearMeSearch = (lat, lng, radiusMeters)
        sitesNearMeResults = []
        sitesNearMeWarning = nil
        let scope = assetScope

        do {
            // .all adds non-production assets, which localize by asset ID.
            let result = try await retryHelper.withRetry {
                try await sitesSession.requestSiteAssetsByLocation(
                    lat: lat, lng: lng, radiusMeters: radiusMeters, assetType: .vpsInfo, scope: scope
                )
            }

            let results = result.entries.flatMap { entry in
                Self.vpsAssets(entry.assets, scope: scope).map { SiteWithVpsAsset(site: entry.site, asset: $0) }
            }

            sitesNearMeResults = results
            if results.isEmpty {
                sitesNearMeWarning = "No VPS sites found within \(Int(radiusMeters))m."
                infoPanelText = "No sites with VPS assets found near this location."
            } else {
                infoPanelText = "Found \(results.count) VPS asset(s) within \(Int(radiusMeters))m."
                sitesNearMeWarning = nil
            }
            listMode = .sitesNearMe
        } catch is CancellationError {
        } catch {
            infoPanelText = "❌ Error: \(error.localizedDescription)"
            sitesNearMeWarning = error.localizedDescription
            listMode = .sitesNearMe
        }
    }

    // MARK: - Loading

    private func loadInitialData() async {
        infoPanelText = "⏳ Loading organizations..."
        do {
            let orgsResult = try await retryHelper.withRetry {
                try await sitesSession.requestSelfOrganizationInfo()
            }
            let orgs = orgsResult.organizations
            if orgs.isEmpty {
                infoPanelText = "⚠️ No organizations found. Make sure you're authenticated."
            } else {
                organizations = orgs
                infoPanelText = "✅ Loaded \(orgs.count) organization(s)"
            }
        } catch is CancellationError {
        } catch {
            infoPanelText = "❌ Error loading data: \(error.localizedDescription)"
        }
    }

    func selectOrganization(_ org: OrganizationInfo) {
        runExclusive { [weak self] in
            await self?.performSelectOrganization(org)
        }
    }

    private func performSelectOrganization(_ org: OrganizationInfo) async {
        showSitesFailureRecovery = false
        listMode = .sites(organization: org)
        siteAssetPairs = []
        sitesLoadProgress = nil
        infoPanelText = infoText(for: org)

        do {
            infoPanelText = infoPanelText + "\n\n⏳ Loading sites for \(org.name)..."

            let result = try await retryHelper.withRetry {
                try await sitesSession.requestSitesForOrganization(orgId: org.id)
            }
            let sites = result.sites
            guard !sites.isEmpty else {
                infoPanelText = (infoPanelText) + "\n\n⚠️ No sites found"
                return
            }
            sitesLoadProgress = (0, sites.count)
            let scope = assetScope

            try await withThrowingTaskGroup(of: [SiteWithVpsAsset].self) { group in
                for site in sites {
                    group.addTask {
                        try Task.checkCancellation()
                        do {
                            // This endpoint returns every asset, production or not, so vpsAssets
                            // applies the scope.
                            let assetsResult = try await self.retryHelper.withRetry {
                                try await self.sitesSession.requestAssetsForSite(siteId: site.id)
                            }
                            return Self.vpsAssets(assetsResult.assets, scope: scope).map {
                                SiteWithVpsAsset(site: site, asset: $0)
                            }
                        } catch is CancellationError {
                            print("Cancelled loading assets for site \(site.name)")
                            throw CancellationError()
                        }
                        catch {
                            print("Failed to load assets for site \(site.name): \(error.localizedDescription)")
                        }
                        return []
                    }
                }

                var loaded = 0
                for try await pairs in group {
                    try Task.checkCancellation()
                    loaded += 1
                    await MainActor.run {
                        self.sitesLoadProgress = (loaded, sites.count)
                        self.siteAssetPairs.append(contentsOf: pairs)
                    }
                }
            }

            sitesLoadProgress = nil
            if siteAssetPairs.isEmpty {
                infoPanelText = (infoPanelText.replacing("⏳ Loading sites for \(org.name)...", with: "⚠️ No sites with a \(scope == .production ? "Production " : "")VPS asset found"))
            } else {
                infoPanelText = (infoPanelText.replacing("⏳ Loading sites for \(org.name)...", with: "✅ Found \(siteAssetPairs.count) VPS asset(s) (checked \(sites.count) site(s))"))
            }
        } catch is CancellationError {
        } catch {
            infoPanelText = (infoPanelText) + "\n\n❌ Error loading sites: \(error.localizedDescription)"
            showSitesFailureRecovery = true
        }
    }

    func backToOrganizations() {
        cancelLoading()
        listMode = .organizations
        siteAssetPairs = []
        sitesLoadProgress = nil
        showSitesFailureRecovery = false
        infoPanelText = "\(organizations.count) organization(s)"
    }

    func applySelection(_ pair: SiteWithVpsAsset) {
        infoPanelText = infoText(for: pair.site) + "\n\n" + infoText(for: pair.asset)
    }

    /// The VPS assets in `scope` that VPS2 can localize to: those with a map.
    /// Nonisolated: the organization flow calls it from its task group's child tasks.
    nonisolated private static func vpsAssets(_ assets: [AssetInfo], scope: AssetScope) -> [AssetInfo] {
        assets.filter { asset in
            guard asset.assetType == .vpsInfo, let vps = asset.vpsData, !vps.anchorPayload.isEmpty else {
                return false
            }
            return scope == .all || asset.deployment == .production
        }
    }

    private static func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
