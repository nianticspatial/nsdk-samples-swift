// Copyright 2026 Niantic Spatial.

import Foundation
import NSDK

/// Resolves the display names of a localized site and asset through the Sites API.
final class SiteNameLoader {

    private var siteTask: Task<Void, Never>?
    private var assetTask: Task<Void, Never>?

    /// Starts a name lookup, replacing any in-flight one.
    ///
    /// - Parameters:
    ///   - siteId: The site of the localized asset.
    ///   - assetId: The localized VPS map asset.
    ///   - onSiteName: Called on the main actor once the site name resolves.
    ///   - onAsset: Called on the main actor once the asset resolves, with its display name and
    ///     how many areas it is split into. A scan too large for one mapping run produces several,
    ///     each with its own anchor and extent.
    ///
    /// The two requests are independent: they run concurrently, and either callback still runs
    /// if the other request fails. A callback does not run if its own request fails.
    func start(
        siteId: String,
        assetId: String,
        nsdkSession: NSDKSession,
        retryHelper: AuthRetryHelper,
        onSiteName: @MainActor @escaping (String) -> Void,
        onAsset: @MainActor @escaping (_ name: String, _ areaCount: Int) -> Void
    ) {
        cancel()

        // Shared with the screen that acquired it first, which also destroys it; this loader
        // never does.
        let sites = nsdkSession.acquireSitesSession()

        siteTask = Task {
            do {
                let siteResult = try await retryHelper.withRetry {
                    try await sites.requestSiteInfo(siteId: siteId)
                }
                try Task.checkCancellation()
                if let name = siteResult.sites.first?.name {
                    onSiteName(name)
                }
            } catch is CancellationError {
            } catch {
                print("Failed to resolve name for site \(siteId): \(error)")
            }
        }

        assetTask = Task {
            do {
                let assetResult = try await retryHelper.withRetry {
                    try await sites.requestAssetInfo(assetId: assetId)
                }
                try Task.checkCancellation()
                if let asset = assetResult.assets.first {
                    onAsset(asset.name, asset.areas.count)
                }
            } catch is CancellationError {
            } catch {
                print("Failed to resolve name for asset \(assetId): \(error)")
            }
        }
    }

    func cancel() {
        siteTask?.cancel()
        siteTask = nil
        assetTask?.cancel()
        assetTask = nil
    }
}
