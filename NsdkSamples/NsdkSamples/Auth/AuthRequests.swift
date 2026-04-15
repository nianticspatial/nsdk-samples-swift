// Copyright 2026 Niantic Spatial.

import Foundation

// MARK: - Request functions

/// Refreshes the sample session token. Returns the rotated token from Set-Cookie,
/// or nil if the server did not rotate it.
func requestSampleSessionAccess(sessionToken: String) async throws -> String? {
    var request = try makeIdentityRequest()
    request.setValue("refresh_token=\(sessionToken)", forHTTPHeaderField: "Cookie")
    request.httpBody = try encodeBody(["grantType": "refresh_user_session_access_token"])
    let (_, httpResponse) = try await performRequest(request)
    return extractRefreshTokenCookie(from: httpResponse, url: request.url!)
}

/// Exchanges a sample session token for an NSDK refresh token.
func requestNsdkRefreshToken(sessionToken: String) async throws -> String {
    var request = try makeIdentityRequest()
    request.setValue("refresh_token=\(sessionToken)", forHTTPHeaderField: "Cookie")
    request.httpBody = try encodeBody(["grantType": "exchange_build_refresh_token"])
    let (data, _) = try await performRequest(request)
    let json = try parseJSON(data)
    guard let token = json["buildRefreshToken"] as? String, !token.isEmpty else {
        throw AuthRequestError.invalidResponse("buildRefreshToken missing or empty")
    }
    return token
}

/// Exchanges an NSDK refresh token for an NSDK access token.
func requestNsdkAccessToken(nsdkRefreshToken: String) async throws -> String {
    var request = try makeIdentityRequest()
    request.httpBody = try encodeBody([
        "grantType": "refresh_build_access_token",
        "buildRefreshToken": nsdkRefreshToken,
    ])
    let (data, _) = try await performRequest(request)
    let json = try parseJSON(data)
    guard let token = json["buildAccessToken"] as? String, !token.isEmpty else {
        throw AuthRequestError.invalidResponse("buildAccessToken missing or empty")
    }
    return token
}

// MARK: - Helpers

private func makeIdentityRequest() throws -> URLRequest {
    guard let url = URL(string: AuthConstants.EndPointUrls.Identity) else {
        throw AuthRequestError.invalidEndpointUrl
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    return request
}

private func encodeBody(_ body: [String: String]) throws -> Data {
    try JSONSerialization.data(withJSONObject: body)
}

private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    let (data, response) = try await URLSession.shared.data(for: request)
    try Task.checkCancellation()

    guard let httpResponse = response as? HTTPURLResponse else {
        throw AuthRequestError.invalidResponse("non-HTTP response")
    }

    guard (200 ..< 300).contains(httpResponse.statusCode) else {
        let message = (try? JSONDecoder().decode(_ErrorBody.self, from: data))?.error
        throw AuthRequestError.serverError(statusCode: httpResponse.statusCode, message: message)
    }

    return (data, httpResponse)
}

private func parseJSON(_ data: Data) throws -> [String: Any] {
    let parsed = try JSONSerialization.jsonObject(with: data)
    return (parsed as? [String: Any]) ?? [:]
}

private func extractRefreshTokenCookie(from response: HTTPURLResponse, url: URL) -> String? {
    let headerFields = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
        if let key = pair.key as? String, let value = pair.value as? String {
            result[key] = value
        }
    }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headerFields, for: url)
    return cookies.first { $0.name.lowercased() == "refresh_token" }?.value
}

private struct _ErrorBody: Decodable {
    let error: String?
}

// MARK: - Errors

enum AuthRequestError: Error, CustomDebugStringConvertible {
    case invalidEndpointUrl
    case invalidResponse(String)
    case serverError(statusCode: Int, message: String?)

    var debugDescription: String {
        switch self {
        case .invalidEndpointUrl:
            return "Endpoint is not a valid URL"
        case .invalidResponse(let detail):
            return "Invalid response from identity endpoint: \(detail)"
        case let .serverError(statusCode, message):
            if let message, !message.isEmpty {
                return "Identity endpoint returned \(statusCode): \(message)"
            }
            return "Identity endpoint returned \(statusCode)."
        }
    }
}
