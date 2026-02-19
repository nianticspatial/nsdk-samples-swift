//
//  RequestUserSessionAccess.swift
//  NsdkSamples
//
// Request access to the user session as part of Enterprise Authentication
//

import Foundation

/// A namespace for handling the renewal of user session access tokens using a refresh token.
enum RequestUserSessionAccess {
    /// The internal request body sent to the identity endpoint.
    private struct Request: Encodable {
        let grantType = "refresh_user_session_access_token"
    }

    /// The expected successful response body from the identity endpoint.
    private struct Response: Decodable {
        let token: String
        let expiresAt: Int?
    }

    /// The structure used to parse error messages from the server.
    private struct ErrorResponse: Decodable {
        let error: String?
    }

    /// The final output containing the updated session credentials.
    struct UserSessionResult {
        let refreshToken: String?
        let accessToken: String?
    }

    /// Executes an asynchronous network request to refresh the user session.
    /// - Parameters:
    ///   - refreshToken: The current refresh token used to authenticate the request.
    /// - Returns: A `UserSessionResult` containing the new access token and an optional new refresh token.
    /// - Throws: `UserSessionError` if the server returns an error or if the response is invalid.
    static func execute(refreshToken: String) async throws -> UserSessionResult {
        // Convert the end-point string to a URL
        guard let identityEndpoint = URL(string: AuthConstants.EndPointUrls.Identity) else {
            throw UserSessionError.invalidEndpointUrl
        }

        // Prepare the URLRequest with standard JSON headers
        var request = URLRequest(url: identityEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request())

        // Pass the refresh token via the Cookie header as required by the Enterprise Auth spec
        request.setValue("refresh_token=\(refreshToken)", forHTTPHeaderField: "Cookie")

        // Perform the network call using Swift Concurrency
        let (data, response) = try await URLSession.shared.data(for: request)

        // Ensure the task wasn't cancelled during the network wait
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UserSessionError.invalidResponse
        }

        // Check for successful HTTP status codes (2xx)
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            // Attempt to decode a specific error message, otherwise fallback to the raw response string
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ??
                String(data: data, encoding: .utf8)
            throw UserSessionError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed = try JSONDecoder().decode(Response.self, from: data)

        // Refresh tokens are always rotated and sent back via Set-Cookie headers
        let newRefreshToken = extractRefreshToken(from: httpResponse, url: identityEndpoint)

        return UserSessionResult(refreshToken: newRefreshToken, accessToken: parsed.token)
    }

    /// Helper method to extract the 'refresh_token' from the HTTP response headers.
    /// - Parameters:
    ///   - response: The HTTPURLResponse containing the headers.
    ///   - url: The URL associated with the cookies.
    /// - Returns: The string value of the refresh token if found.
    private static func extractRefreshToken(from response: HTTPURLResponse, url: URL) -> String? {
        // Convert the [AnyHashable: Any] headers into a [String: String] dictionary for cookie processing
        let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { partialResult, pair in
            if let key = pair.key as? String, let value = pair.value as? String {
                partialResult[key] = value
            }
        }

        // Parse the cookies from the header fields
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)

        // Find the specific cookie by name (case-insensitive)
        return cookies.first { $0.name.lowercased() == "refresh_token" }?.value
    }
}

/// Potential errors encountered during the user session request process.
enum UserSessionError: Error, CustomStringConvertible {
    case invalidEndpointUrl
    case invalidResponse
    case serverError(statusCode: Int, message: String?)

    /// A human-readable description of the error.
    var description: String {
        switch self {
        case .invalidEndpointUrl:
            return "Endpoint is not a valid URL"
        case .invalidResponse:
            return "Invalid response from identity endpoint."
        case let .serverError(statusCode, message):
            if let message, !message.isEmpty {
                return "Identity endpoint returned \(statusCode): \(message)"
            }
            return "Identity endpoint returned \(statusCode)."
        }
    }
}


