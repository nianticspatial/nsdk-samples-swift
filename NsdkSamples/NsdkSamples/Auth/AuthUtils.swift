//
//  AuthUtils.swift
//  NsdkSamples
//
// Miscellaneous utility functions related to authentication.
//

import Foundation

enum AuthUtils {
    // Extract refresh and access tokens from a URL string:
    static func extractTokens(from urlString: String) -> (accessToken: String?, refreshToken: String?) {
        // 1. Convert the string to a URL object
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil)
        }

        // 2. Access the query items array
        let queryItems = components.queryItems

        // 3. Extract specific parameters by name
        let accessToken = queryItems?.first(where: { $0.name == "accessToken" })?.value
        let refreshToken = queryItems?.first(where: { $0.name == "refreshToken" })?.value

        return (accessToken, refreshToken)
    }

    // Print details of a token (useful for debugging)
    static func printTokenDetails(_ token: String?, _ context: String) {
        let abbreviatedToken = token?.suffix(4) ?? "<none>"
        let expiration = jwtExpiration(for: token)

        var timeLeft: String = "<unknown>"
        if expiration != nil {
            timeLeft = Int(expiration! - Date().timeIntervalSince1970).description
        }

        print(context + ": " + abbreviatedToken + ", time left = " + timeLeft)
    }

    // Is the given token either empty, expired, or about to expire (in the given time left):
    static func isTokenEmptyOrExpiring(_ token: String?, minUnexpiredTimeLeft: TimeInterval) -> Bool {
        guard let token, !token.isEmpty else { return true }
        guard let expiration = jwtExpiration(for: token) else { return true }

        let timeLeft = expiration - Date().timeIntervalSince1970
        return timeLeft <= minUnexpiredTimeLeft
    }

    // Extracts an expiration timestamp from a JWT payload.
    private static func jwtExpiration(for token: String?) -> TimeInterval? {
        guard let parts = token?.split(separator: ".") else { return nil }
        guard parts.count >= 2 else { return nil }

        var payload = String(parts[1])
        payload = payload.replacingOccurrences(of: "-", with: "+")
        payload = payload.replacingOccurrences(of: "_", with: "/")
        let padding = payload.count % 4
        if padding > 0 {
            payload.append(String(repeating: "=", count: 4 - padding))
        }

        guard let data = Data(base64Encoded: payload),
              let jsonObject = try? JSONSerialization.jsonObject(with: data),
              let json = jsonObject as? [String: Any] else {
            return nil
        }

        if let exp = json["exp"] as? Double {
            return exp
        }
        if let exp = json["exp"] as? Int {
            return Double(exp)
        }
        return nil
    }
}
