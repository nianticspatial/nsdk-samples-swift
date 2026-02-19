// Copyright 2022-2025 Niantic.

import Foundation
import SwiftyNsdk

class SitesManager: NSObject {
    private let nsdkSession: NsdkSession
    private var sitesSession: NsdkSitesSession
    
    init(nsdk: NsdkSession) {
        self.nsdkSession = nsdk
        self.sitesSession = nsdk.createSitesSession()
    }
    
    // MARK: - Public API Functions
    
    func requestOrganizationsForUser(userId: String) async throws -> OrganizationResult {
        return try await sitesSession.requestOrganizationsForUser(userId: userId)
    }
    
    func requestSitesForOrganization(orgId: String) async throws -> SiteResult {
        return try await sitesSession.requestSitesForOrganization(orgId: orgId)
    }
    
    func requestAssetsForSite(siteId: String) async throws -> AssetResult {
        return try await sitesSession.requestAssetsForSite(siteId: siteId)
    }
    
    func requestOrganizationInfo(orgId: String) async throws -> OrganizationResult {
        return try await sitesSession.requestOrganizationInfo(orgId: orgId)
    }
    
    func requestSiteInfo(siteId: String) async throws -> SiteResult {
        return try await sitesSession.requestSiteInfo(siteId: siteId)
    }
    
    func requestAssetInfo(assetId: String) async throws -> AssetResult {
        return try await sitesSession.requestAssetInfo(assetId: assetId)
    }
    
    func requestUserInfo(userId: String) async throws -> UserResult {
        return try await sitesSession.requestUserInfo(userId: userId)
    }
    
    func requestSelfUserInfo() async throws -> UserResult {
        return try await sitesSession.requestSelfUserInfo()
    }
}
