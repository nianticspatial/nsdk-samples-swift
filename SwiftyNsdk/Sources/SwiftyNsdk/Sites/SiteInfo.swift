// Copyright Niantic Spatial.
import CArdk

/// Represents site information from the Sites Manager service.
public struct SiteInfo: CustomStringConvertible {
    /// Site identifier.
    public let id: String
    
    /// Site name.
    public let name: String
    
    /// Site status.
    public let status: String
    
    /// Organization identifier that owns this site.
    public let organizationId: String
    
    /// Latitude coordinate (valid if hasLocation is true).
    public let latitude: Double
    
    /// Longitude coordinate (valid if hasLocation is true).
    public let longitude: Double
    
    /// Indicates whether latitude and longitude are valid.
    public let hasLocation: Bool
    
    /// Parent site identifier (nil if no parent site).
    public let parentSiteId: String?
    
    public init?(fromC cValue: ARDK_SitesManager_SiteInfo) {
        guard let idPtr = cValue.id else { return nil }
        guard let namePtr = cValue.name else { return nil }
        guard let statusPtr = cValue.status else { return nil }
        guard let orgIdPtr = cValue.organization_id else { return nil }
        
        self.id = String(cString: idPtr)
        self.name = String(cString: namePtr)
        self.status = String(cString: statusPtr)
        self.organizationId = String(cString: orgIdPtr)
        self.latitude = cValue.latitude
        self.longitude = cValue.longitude
        self.hasLocation = cValue.has_location
        self.parentSiteId = cValue.parent_site_id != nil ? String(cString: cValue.parent_site_id) : nil
    }
    
    public var description: String {
        var desc = """
Site
- ID: \(id)
- Name: \(name)
- Status: \(status)
- Organization ID: \(organizationId)
"""
        if hasLocation {
            desc += "- Location: (\(latitude), \(longitude))\n"
        }
        if let parentId = parentSiteId {
            desc += "- Parent Site ID: \(parentId)\n"
        }
        return desc
    }
}

