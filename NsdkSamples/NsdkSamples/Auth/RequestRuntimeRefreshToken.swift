//
//  RequestRuntimeRefreshToken.swift
//  NsdkSamples
//
// Request a runtime refresh token by exchanging a user session refresh token.
// Provides a unique runtime refresh token for every build or play mode session.
//

import Foundation

/// A namespace for requesting a runtime refresh token using a user session refresh token.
/// This is a first-time request that creates a new refresh token (not refreshing an existing one).
enum RequestRuntimeRefreshToken {
    /// The internal request body sent to the identity endpoint.
    private struct Request: Encodable {
        let grantType = "exchange_build_refresh_token"
    }

    /// The expected successful response body from the identity endpoint.
    private struct Response: Decodable {
        let buildRefreshToken: String
        let expiresAt: Int?
    }

    /// The structure used to parse error messages from the server.
    private struct ErrorResponse: Decodable {
        let error: String?
    }

    /// The final output containing the runtime refresh token credentials.
    struct RuntimeRefreshTokenResult {
        let refreshToken: String
        let expiresAt: Int?
    }

    /// Executes an asynchronous network request to exchange an user session refresh token for a runtime refresh token.
    /// - Parameters:
    ///   - userSessionRefreshToken: A valid user session refresh token used to authenticate the request.
    /// - Returns: A `RuntimeRefreshTokenResult` containing the new runtime refresh token and optional expiry.
    /// - Throws: `RuntimeRefreshTokenError` if the server returns an error or if the response is invalid.
    static func execute(userSessionRefreshToken: String) async throws -> RuntimeRefreshTokenResult {
        // Convert the end-point string to a URL
        guard let identityEndpoint = URL(string: AuthConstants.EndPointUrls.Identity) else {
            throw RuntimeRefreshTokenError.invalidEndpointUrl
        }

        // Prepare the URLRequest with standard JSON headers
        var request = URLRequest(url: identityEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Request())

        // Pass the user session refresh token via the Cookie header as required by the Auth spec
        request.setValue("refresh_token=\(userSessionRefreshToken)", forHTTPHeaderField: "Cookie")

        // Perform the network call using Swift Concurrency
        let (data, response) = try await URLSession.shared.data(for: request)

        // Ensure the task wasn't cancelled during the network wait
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuntimeRefreshTokenError.invalidResponse
        }

        // Check for successful HTTP status codes (2xx)
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            // Attempt to decode a specific error message, otherwise fallback to the raw response string
            let message = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error ??
                String(data: data, encoding: .utf8)
            throw RuntimeRefreshTokenError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed = try JSONDecoder().decode(Response.self, from: data)

        return RuntimeRefreshTokenResult(refreshToken: parsed.buildRefreshToken, expiresAt: parsed.expiresAt)
    }
}

/// Potential errors encountered during the runtime refresh token request process.
enum RuntimeRefreshTokenError: Error, CustomStringConvertible {
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
