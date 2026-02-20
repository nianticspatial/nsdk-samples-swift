//
//  RequestAuthAccess.swift
//  NsdkSamples
//
// Request access to the NS API, using the sample user session access token.
//

import Foundation

/// A namespace for requesting NS API access tokens using a user session access token.
enum RequestAuthAccess {
    /// The expected successful response body from the access endpoint.
    private struct Response: Decodable {
        let error: String?
        let accessToken: String?
        let expiresIn: Int?
    }

    /// Executes an asynchronous network request to get an NS API access token.
    /// - Parameters:
    ///   - userSessionAccessToken: The user session access token used to authenticate the request.
    /// - Returns: The access token string if successful, or nil if the request failed.
    /// - Throws: `AuthAccessError` if the server returns an error or if the response is invalid.
    static func execute(userSessionAccessToken: String) async throws -> String? {
        // Convert the end-point string to a URL
        guard let accessEndpoint = URL(string: AuthConstants.EndPointUrls.Access) else {
            throw UserSessionError.invalidEndpointUrl
        }
        // Prepare the URLRequest with Authorization header
        var request = URLRequest(url: accessEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(userSessionAccessToken)", forHTTPHeaderField: "Authorization")

        // Perform the network call using Swift Concurrency
        let (data, response) = try await URLSession.shared.data(for: request)

        // Ensure the task wasn't cancelled during the network wait
        try Task.checkCancellation()

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthAccessError.invalidResponse
        }

        // Check for successful HTTP status codes (2xx)
        guard (200 ..< 300).contains(httpResponse.statusCode) else {
            // Attempt to decode a specific error message, otherwise fallback to the raw response string
            let errorResponse = try? JSONDecoder().decode(Response.self, from: data)
            let message = errorResponse?.error ?? String(data: data, encoding: .utf8)
            throw AuthAccessError.serverError(statusCode: httpResponse.statusCode, message: message)
        }

        let parsed = try JSONDecoder().decode(Response.self, from: data)

        // Check if the response contains an error field
        if let error = parsed.error, !error.isEmpty {
            throw AuthAccessError.serverError(statusCode: httpResponse.statusCode, message: error)
        }

        // Check if access token is present
        guard let accessToken = parsed.accessToken, !accessToken.isEmpty else {
            throw AuthAccessError.invalidResponse
        }

        print("Access token received: \(accessToken)")
        return accessToken
    }
}

/// Potential errors encountered during the auth access request process.
enum AuthAccessError: Error, CustomStringConvertible {
    case invalidEndpointUrl
    case invalidResponse
    case serverError(statusCode: Int, message: String?)

    /// A human-readable description of the error.
    var description: String {
        switch self {
        case .invalidEndpointUrl:
            return "Endpoint is not a valid URL"
        case .invalidResponse:
            return "Failed to parse access token response"
        case let .serverError(statusCode, message):
            if let message, !message.isEmpty {
                return "Error in request for NS auth access token: \(statusCode) : \(message)"
            }
            return "Error in request for NS auth access token: \(statusCode)"
        }
    }
}
