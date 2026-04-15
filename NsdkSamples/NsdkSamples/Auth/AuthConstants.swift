// Copyright 2026 Niantic Spatial.

enum AuthConstants {
    // Developer access token can be pasted here to enable samples that require server access
    // (this will skip the login flow):
    static let accessToken: String = ""

    // URL scheme registered in Info.plist for the login callback deep link
    static let callbackUrlScheme: String = "nsdk-samples"

    // List of all end-points used by authentication
    enum EndPointUrls {
        static let SignIn: String = "https://sample-app-frontend-internal.nianticspatial.com/signin"
        static let Identity: String = "https://spatial-identity.nianticspatial.com/oauth/token"
    }
}
