//
//  AuthConstants.swift
//  NsdkSamples
//
// Shared constants used for authentication
// 

enum AuthConstants {
    // If you have an API key, set it here to enable samples that require server access
    // (this will skip Enterprise Auth login):
    static let apiKey: String = "YOUR_API_KEY"
    // Developer tokens can be pasted here to enable samples that require server access
    // (this will skip Enterprise Auth login):
    static let accessToken: String = ""
    static let refreshToken: String = ""

    // List of all end-points used by authentication
    enum EndPointUrls {
        static let SignIn: String = "https://sample-app-frontend-internal.nianticspatial.com/signin"
        static let Identity: String = "https://spatial-identity.nianticspatial.com/oauth/token"
        static let Access: String = "https://sample-app-backend-internal.nianticspatial.com/api/access-token"
    }
}
