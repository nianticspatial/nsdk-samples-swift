// Copyright 2026 Niantic Spatial.

import Foundation

enum AuthUtils {
    static func extractTokens(from urlString: String) -> (accessToken: String?, refreshToken: String?) {
        guard let url = URL(string: urlString),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return (nil, nil)
        }

        let queryItems = components.queryItems
        let accessToken = queryItems?.first(where: { $0.name == "accessToken" })?.value
        let refreshToken = queryItems?.first(where: { $0.name == "refreshToken" })?.value

        return (accessToken, refreshToken)
    }

    static func printTokenDetails(_ token: String?, _ context: String) {
        let abbreviatedToken = token?.suffix(4) ?? "<none>"
        let expiration = jwtExpiration(for: token)

        var timeLeft: String = "<unknown>"
        if expiration != nil {
            timeLeft = Int(expiration! - Date().timeIntervalSince1970).description
        }

        print(context + ": " + abbreviatedToken + ", time left = " + timeLeft)
    }

    /// Returns true if `token` looks like a structurally valid JWT: three dot-separated parts
    /// where the header and payload are valid base64url-encoded JSON objects. Does not verify
    /// the signature. Rejects placeholder strings like "set_your_token_here".
    static func isValidJwt(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return decodeBase64UrlJson(String(parts[0])) != nil
            && decodeBase64UrlJson(String(parts[1])) != nil
    }

    private static func decodeBase64UrlJson(_ s: String) -> [String: Any]? {
        var padded = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 { padded += String(repeating: "=", count: 4 - remainder) }
        guard let data = Data(base64Encoded: padded),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    static func isTokenEmptyOrExpiring(_ token: String?, minUnexpiredTimeLeft: TimeInterval) -> Bool {
        guard let token, !token.isEmpty else { return true }
        guard let expiration = jwtExpiration(for: token) else { return true }

        let timeLeft = expiration - Date().timeIntervalSince1970
        return timeLeft <= minUnexpiredTimeLeft
    }

    static func jwtEmail(for token: String?) -> String? {
        guard let parts = token?.split(separator: "."), parts.count >= 2 else { return nil }

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

        return (json["email"] as? String) ?? (json["sub"] as? String)
    }

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
