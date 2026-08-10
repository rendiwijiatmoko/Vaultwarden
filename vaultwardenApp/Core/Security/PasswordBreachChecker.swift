import CryptoKit
import Foundation

nonisolated enum PasswordBreachCheckResult: Sendable, Equatable {
    case notFound
    case exposed(count: Int)
}

nonisolated enum PasswordBreachCheckError: LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "The breach service could not complete this check. Please try again."
    }
}

nonisolated enum PasswordBreachChecker {
    /// Uses the Pwned Passwords range API. Only the first five SHA-1 characters
    /// leave the device; the full password and complete hash remain local.
    static func check(_ password: String) async throws -> PasswordBreachCheckResult {
        let digest = Insecure.SHA1.hash(data: Data(password.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
        let prefix = String(digest.prefix(5))
        let suffix = String(digest.dropFirst(5))
        guard let url = URL(string: "https://api.pwnedpasswords.com/range/\(prefix)") else {
            throw PasswordBreachCheckError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("true", forHTTPHeaderField: "Add-Padding")
        request.setValue("Vaultwarden-iOS-Password-Check", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let body = String(data: data, encoding: .utf8) else {
            throw PasswordBreachCheckError.invalidResponse
        }

        for line in body.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2,
                  String(parts[0]).caseInsensitiveCompare(suffix) == .orderedSame,
                  let count = Int(parts[1]),
                  count > 0 else { continue }
            return .exposed(count: count)
        }
        return .notFound
    }
}
