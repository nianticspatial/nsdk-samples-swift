// Copyright 2026 Niantic Spatial.

import Combine
import Foundation
import NSDK

/// Drives Sites API flows using NSDKSitesSession and AuthRetryHelper.
///
/// Publishes:
/// - `listMode`: `ListMode` — whether showing organizations or sites. Initially `.organizations`. Changes on drill-down or back navigation.
/// - `organizations`: `[OrganizationInfo]` — loaded organizations. Initially empty. Set after `loadInitialData()` completes.
/// - `siteAssetPairs`: `[(SiteInfo, AssetInfo)]` — sites with VPS assets. Initially empty. Populated incrementally during `selectOrganization()`.
/// - `infoPanelText`: `String` — formatted info panel content. Initially `""`. Updated on every API call or user selection.
/// - `sitesLoadProgress`: `(loaded: Int, total: Int)?` — incremental loading progress. Initially `nil`. Non-nil only while sites are being fetched.
/// - `showSitesFailureRecovery`: `Bool` — whether to show failure recovery UI. Initially `false`. Set to `true` on sites load error.
/// - `filterProduction`: `Bool` — whether to filter VPS assets by production deployment. Initially `true`. User-settable.
@MainActor
final class SitesViewModel {

    enum ListMode {
        case modeSelection
        case organizations
        case sites(organization: OrganizationInfo)
        case sitesNearMe
    }

    // MARK: - Published UI state

    @Published private(set) var listMode: ListMode = .modeSelection
    @Published private(set) var currentUser: UserInfo?
    @Published private(set) var organizations: [OrganizationInfo] = []
    @Published private(set) var siteAssetPairs: [(SiteInfo, AssetInfo)] = []
    @Published private(set) var sitesLoadProgress: (loaded: Int, total: Int)?
    @Published private(set) var infoPanelText: String = ""

    @Published private(set) var showSitesFailureRecovery: Bool = false
    @Published var filterProduction: Bool = true

    // Near Me state — (site, anchorPayload) pairs for direct VPS2 launch
    @Published private(set) var sitesNearMeSitePayloadPairs: [(SiteInfo, String)] = []
    @Published private(set) var sitesNearMeWarning: String?

    // MARK: - Private

    private let sitesSession: NSDKSitesSession
    private let retryHelper: AuthRetryHelper

    // MARK: - Initialization

    init(sitesSession: NSDKSitesSession, retryHelper: AuthRetryHelper) {
        self.sitesSession = sitesSession
        self.retryHelper = retryHelper
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

    func anchorPayload(for siteId: String) -> String? {
        guard let pair = siteAssetPairs.first(where: { $0.0.id == siteId }),
              let vps = pair.1.vpsData,
              !vps.anchorPayload.isEmpty else {
            return nil
        }
        return vps.anchorPayload
    }

    // MARK: - Mode Selection

    func startFromOrgsFlow() async {
        listMode = .organizations
        await loadInitialData()
    }

    func startNearMeFlow() {
        sitesNearMeSitePayloadPairs = []
        sitesNearMeWarning = nil
        listMode = .sitesNearMe
    }

    func backToModeSelection() {
        listMode = .modeSelection
        infoPanelText = ""
    }

    // MARK: - Near Me Loading

    func loadNearMeSites(lat: Double, lng: Double, radiusMeters: Double) async {
        infoPanelText = "⏳ Searching for VPS sites within \(Int(radiusMeters))m..."
        sitesNearMeSitePayloadPairs = []
        sitesNearMeWarning = nil

        do {
            let result = try await retryHelper.withRetry {
                try await sitesSession.requestSiteAssetsByLocation(
                    lat: lat, lng: lng, radiusMeters: radiusMeters, assetType: .vpsInfo
                )
            }

            var pairs: [(SiteInfo, String)] = []
            for entry in result.entries {
                if let vpsAsset = entry.assets.first(where: {
                    guard let vps = $0.vpsData, !vps.anchorPayload.isEmpty else { return false }
                    return $0.deployment == .production || !filterProduction
                }), let payload = vpsAsset.vpsData?.anchorPayload {
                    pairs.append((entry.site, payload))
                }
            }

            sitesNearMeSitePayloadPairs = pairs
            if pairs.isEmpty {
                sitesNearMeWarning = "No VPS sites found within \(Int(radiusMeters))m."
                infoPanelText = "No sites with VPS assets found near this location."
            } else {
                infoPanelText = "Found \(pairs.count) VPS site(s) within \(Int(radiusMeters))m."
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

    func loadInitialData() async {
        infoPanelText = "⏳ Loading user info..."
        do {
            let userResult = try await retryHelper.withRetry {
                try await sitesSession.requestSelfUserInfo()
            }
            guard let user = userResult.user else {
                infoPanelText = "❌ Failed to retrieve user information. Make sure you're authenticated."
                return
            }
            currentUser = user
            infoPanelText = infoText(for: user)

            let orgsResult = try await retryHelper.withRetry {
                try await sitesSession.requestOrganizationsForUser(userId: user.id)
            }
            let orgs = orgsResult.organizations
            if orgs.isEmpty {
                infoPanelText = (infoPanelText) + "\n\n⚠️ No organizations found"
            } else {
                organizations = orgs
            }
        } catch is CancellationError {
        } catch {
            infoPanelText = "❌ Error loading data: \(error.localizedDescription)"
        }
    }

    func selectOrganization(_ org: OrganizationInfo) async {
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

            try await withThrowingTaskGroup(of: (SiteInfo, AssetInfo)?.self) { group in
                for site in sites {
                    group.addTask {
                        try Task.checkCancellation()
                        let filterProduction = await MainActor.run { self.filterProduction }
                        do {
                            let assetsResult = try await self.retryHelper.withRetry {
                                try await self.sitesSession.requestAssetsForSite(siteId: site.id)
                            }
                            let assets = assetsResult.assets
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

                var loaded = 0
                for try await pair in group {
                    try Task.checkCancellation()
                    loaded += 1
                    let toAdd = pair
                    await MainActor.run {
                        self.sitesLoadProgress = (loaded, sites.count)
                        if let toAdd {
                            self.siteAssetPairs.append(toAdd)
                        }
                    }
                }
            }

            sitesLoadProgress = nil
            if siteAssetPairs.isEmpty {
                infoPanelText = (infoPanelText) + "\n\n⚠️ No sites with Production VPS asset found"
            } else {
                infoPanelText = (infoPanelText) + "\n\nFound \(siteAssetPairs.count) site(s) (checked \(sites.count))"
            }
        } catch is CancellationError {
        } catch {
            infoPanelText = (infoPanelText) + "\n\n❌ Error loading sites: \(error.localizedDescription)"
            showSitesFailureRecovery = true
        }
    }

    func backToOrganizations() {
        listMode = .organizations
        siteAssetPairs = []
        sitesLoadProgress = nil
        showSitesFailureRecovery = false
        if let user = currentUser {
            infoPanelText = infoText(for: user)
        }
    }

    func applySiteSelection(_ site: SiteInfo) {
        guard let pair = siteAssetPairs.first(where: { $0.0.id == site.id }) else { return }
        infoPanelText = infoText(for: pair.0) + "\n\n" + infoText(for: pair.1)
    }

    private static func formatTimestamp(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
