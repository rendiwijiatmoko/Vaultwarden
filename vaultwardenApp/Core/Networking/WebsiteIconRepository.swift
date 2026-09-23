import CryptoKit
import Foundation

/// Downloads website icons through the account's Vaultwarden server and keeps a
/// protected on-device copy so list thumbnails remain available offline.
actor WebsiteIconRepository {
    static let shared = WebsiteIconRepository()

    private var memory: [String: Data] = [:]
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func iconData(website: String, serverURL: URL) async -> Data? {
        guard let host = Self.host(from: website) else { return nil }
        let key = Self.cacheKey(serverURL: serverURL, host: host)
        if let data = memory[key] { return data }

        let fileURL = cacheDirectory.appendingPathComponent("\(key).icon", isDirectory: false)
        if let data = try? Data(contentsOf: fileURL), Self.isValidImage(data) {
            memory[key] = data
            return data
        }

        let legacyFileURL = legacyCacheDirectory.appendingPathComponent("\(key).icon", isDirectory: false)
        if let data = try? Data(contentsOf: legacyFileURL), Self.isValidImage(data) {
            memory[key] = data
            persist(data, to: fileURL)
            return data
        }

        let iconURL = serverURL
            .appendingPathComponent("icons", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent("icon.png", isDirectory: false)
        var request = URLRequest(url: iconURL)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              data.count <= 2_000_000,
              Self.isValidImage(data) else { return nil }

        memory[key] = data
        persist(data, to: fileURL)
        return data
    }

    private var cacheDirectory: URL {
        AutoFillSharedVault.websiteIconCacheDirectory
    }

    private var legacyCacheDirectory: URL {
        let root = (try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("WebsiteIcons", isDirectory: true)
    }

    private func persist(_ data: Data, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(
                to: fileURL,
                options: ClientPlatform.encryptedFileWritingOptions
            )
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = fileURL
            try? protectedURL.setResourceValues(values)
        } catch {
            // The icon is cosmetic. Keep the in-memory copy when disk caching fails.
        }
    }

    private static func host(from value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        return URLComponents(string: candidate)?.host?.lowercased()
    }

    private static func cacheKey(serverURL: URL, host: String) -> String {
        SHA256.hash(data: Data("\(serverURL.absoluteString)|\(host)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isValidImage(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefix = Array(data.prefix(12))
        let isPNG = prefix.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isJPEG = prefix.starts(with: [0xFF, 0xD8, 0xFF])
        let isGIF = prefix.starts(with: Array("GIF8".utf8))
        let isWebP = prefix.starts(with: Array("RIFF".utf8))
            && prefix.count >= 12
            && Array(prefix[8..<12]) == Array("WEBP".utf8)
        return isPNG || isJPEG || isGIF || isWebP
    }
}
