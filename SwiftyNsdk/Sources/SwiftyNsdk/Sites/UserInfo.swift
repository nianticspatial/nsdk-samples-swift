// Copyright Niantic Spatial.
import CArdk

/// Represents user information from the Sites Manager service.
public struct UserInfo: CustomStringConvertible {
    /// User identifier.
    public let id: String
    
    /// User's first name.
    public let firstName: String
    
    /// User's last name.
    public let lastName: String
    
    /// User's email address.
    public let email: String
    
    /// User status.
    public let status: String
    
    /// Timestamp when the user was created (Unix timestamp in seconds).
    public let createdTimestamp: Int64
    
    /// Organization identifier (nil if user doesn't belong to an organization).
    public let organizationId: String?
    
    public init?(fromC cValue: ARDK_SitesManager_UserInfo) {
        guard let idPtr = cValue.id else { return nil }
        guard let firstNamePtr = cValue.first_name else { return nil }
        guard let lastNamePtr = cValue.last_name else { return nil }
        guard let emailPtr = cValue.email else { return nil }
        guard let statusPtr = cValue.status else { return nil }
        
        self.id = String(cString: idPtr)
        self.firstName = String(cString: firstNamePtr)
        self.lastName = String(cString: lastNamePtr)
        self.email = String(cString: emailPtr)
        self.status = String(cString: statusPtr)
        self.createdTimestamp = cValue.created_timestamp
        self.organizationId = cValue.organization_id != nil ? String(cString: cValue.organization_id) : nil
    }
    
    public var description: String {
        var desc = """
User
- ID: \(id)
- Name: \(firstName) \(lastName)
- Email: \(email)
- Status: \(status)
- Created: \(createdTimestamp)
"""
        if let orgId = organizationId {
            desc += "- Organization ID: \(orgId)\n"
        }
        return desc
    }
}

