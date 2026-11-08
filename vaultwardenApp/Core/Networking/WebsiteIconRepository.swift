import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

/// Turns vault URIs into the hosts their icons belong to.
nonisolated enum WebsiteIconHost {
    /// Suffixes that only exist on private networks or in tests. The icon service
    /// can't reach them, and their names shouldn't leave the device for nothing.
    private static let privateSuffixes = [
        "local", "localhost", "lan", "internal", "intranet", "corp", "home", "home.arpa", "test", "invalid"
    ]

    /// The host to ask the icon service about, or nil when the URI names an app,
    /// an IP address or a private network.
    static func iconHost(for uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let schemeEnd = trimmed.range(of: "://") {
            let scheme = trimmed[..<schemeEnd.lowerBound].lowercased()
            guard scheme == "http" || scheme == "https" else { return nil }
        }
        guard var host = storageHost(for: trimmed) else { return nil }
        while host.hasSuffix(".") { host.removeLast() }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        guard isPublicDomain(host) else { return nil }
        return host
    }

    /// The host as the AutoFill extension derives it, so both name cache files alike.
    static func storageHost(for uri: String) -> String? {
        let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let host = URLComponents(string: candidate)?.host?.lowercased(), !host.isEmpty else { return nil }
        return host
    }

    /// A short host for display: no scheme, no `www.`.
    static func displayHost(for uri: String) -> String? {
        guard var host = storageHost(for: uri) else { return nil }
        if host.hasPrefix("www."), host.count > 4 { host.removeFirst(4) }
        return host
    }

    static func isPublicDomain(_ host: String) -> Bool {
        guard host.count <= 253, host.contains("."),
              !host.hasPrefix("."), !host.contains(".."),
              !isIPAddress(host) else { return false }
        let allowed = host.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "."
        }
        guard allowed,
              let topLevel = host.split(separator: ".").last,
              topLevel.contains(where: \.isLetter) else { return false }
        return !privateSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    static func isIPAddress(_ host: String) -> Bool {
        if host.contains(":") || host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy { $0.isASCII && $0.isNumber }
        }
    }

    /// The on-disk name for a host's icon. Matches `AutoFillSharedVault.cachedWebsiteIconData`.
    static func diskKey(serverURL: URL, host: String) -> String {
        SHA256.hash(data: Data("\(serverURL.absoluteString)|\(host)".utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

/// One icon at one size, for one server.
nonisolated struct WebsiteIconRequest: Hashable, Sendable {
    let host: String
    let storageHost: String
    let serverURL: URL
    let pixelSize: Int

    var memoryKey: String { "\(serverURL.absoluteString)|\(host)|\(pixelSize)" }
}

/// Host parsing runs for every row on every render, so it is memoized per URI.
enum WebsiteIconHostLookup {
    struct Hosts: Equatable {
        let icon: String
        let storage: String
    }

    private static var cache: [String: Hosts?] = [:]

    static func hosts(for uri: String) -> Hosts? {
        if let cached = cache[uri] { return cached }
        var hosts: Hosts?
        if let icon = WebsiteIconHost.iconHost(for: uri), let storage = WebsiteIconHost.storageHost(for: uri) {
            hosts = Hosts(icon: icon, storage: storage)
        }
        if cache.count > 4_000 { cache.removeAll(keepingCapacity: true) }
        cache[uri] = hosts
        return hosts
    }

    static func request(for uri: String, serverURL: URL, pixelSize: Int) -> WebsiteIconRequest? {
        guard let hosts = hosts(for: uri) else { return nil }
        return WebsiteIconRequest(host: hosts.icon, storageHost: hosts.storage, serverURL: serverURL, pixelSize: pixelSize)
    }

    static func removeAll() { cache.removeAll() }
}

/// A decoded icon. Immutable, so it can cross actors.
nonisolated final class WebsiteIconImage: @unchecked Sendable {
    let cgImage: CGImage
    /// True when the icon is a full, opaque square (an app-style icon) that should fill
    /// its tile, rather than a glyph that sits on white.
    let fillsTile: Bool

    init(cgImage: CGImage, fillsTile: Bool) {
        self.cgImage = cgImage
        self.fillsTile = fillsTile
    }
}

/// Decoded icons, readable synchronously so a row that scrolls back shows its icon
/// in the first frame. `NSCache` is thread-safe and gives memory back under pressure.
nonisolated enum WebsiteIconMemoryCache {
    nonisolated(unsafe) private static let storage: NSCache<NSString, WebsiteIconImage> = {
        let cache = NSCache<NSString, WebsiteIconImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 32 * 1_024 * 1_024
        return cache
    }()

    static func image(for request: WebsiteIconRequest) -> WebsiteIconImage? {
        storage.object(forKey: request.memoryKey as NSString)
    }

    static func insert(_ image: WebsiteIconImage, for request: WebsiteIconRequest) {
        let cost = image.cgImage.bytesPerRow * image.cgImage.height
        storage.setObject(image, forKey: request.memoryKey as NSString, cost: cost)
    }

    static func removeAll() {
        storage.removeAllObjects()
    }
}

/// Hosts that have no icon, so they aren't asked again for a while, and each
/// server's stand-in icon, so it can be told apart from a real one.
nonisolated struct WebsiteIconFailureLog: Codable, Equatable, Sendable {
    static let missingRetryInterval: TimeInterval = 24 * 60 * 60
    static let transientRetryInterval: TimeInterval = 10 * 60

    /// Disk key to the date a missing icon may be asked for again.
    private(set) var missing: [String: Date] = [:]
    /// Server key to the SHA-256 of the image the server returns when it has no icon.
    private(set) var fallbackDigests: [String: String] = [:]
    /// Offline or server errors pass quickly, so they are kept in memory only.
    private var transient: [String: Date] = [:]

    private enum CodingKeys: String, CodingKey {
        case missing, fallbackDigests
    }

    func shouldSkip(_ key: String, at now: Date) -> Bool {
        Self.isActive(missing[key], interval: Self.missingRetryInterval, now: now)
            || Self.isActive(transient[key], interval: Self.transientRetryInterval, now: now)
    }

    mutating func recordMissing(_ key: String, at now: Date) {
        missing[key] = now.addingTimeInterval(Self.missingRetryInterval)
        transient[key] = nil
    }

    mutating func recordTransientFailure(_ key: String, at now: Date) {
        transient[key] = now.addingTimeInterval(Self.transientRetryInterval)
    }

    mutating func recordSuccess(_ key: String) {
        missing[key] = nil
        transient[key] = nil
    }

    mutating func removeExpired(at now: Date) {
        missing = missing.filter { Self.isActive($0.value, interval: Self.missingRetryInterval, now: now) }
        transient = transient.filter { Self.isActive($0.value, interval: Self.transientRetryInterval, now: now) }
    }

    func fallbackDigest(forServer serverKey: String) -> String? {
        fallbackDigests[serverKey]
    }

    mutating func setFallbackDigest(_ digest: String, forServer serverKey: String) {
        fallbackDigests[serverKey] = digest
    }

    /// A retry date further away than one interval means the clock moved back,
    /// so it isn't trusted to hold a host off for longer than intended.
    private static func isActive(_ retryAfter: Date?, interval: TimeInterval, now: Date) -> Bool {
        guard let retryAfter else { return false }
        let remaining = retryAfter.timeIntervalSince(now)
        return remaining > 0 && remaining <= interval
    }
}

/// Downloads website icons through the account's Vaultwarden server and keeps a
/// protected on-device copy so thumbnails remain available offline and in AutoFill.
actor WebsiteIconRepository {
    static let shared = WebsiteIconRepository()

    private static let maximumConcurrentFetches = 4
    private static let maximumIconBytes = 2_000_000
    private static let stateFileName = "IconState.json"
    /// No site lives here, so the reply is the server's stand-in icon.
    private static let fallbackProbeHost = "icon-probe.invalid"

    private struct InFlightFetch {
        let id: UUID
        let task: Task<Data?, Never>
        var waiters: Int
    }

    private enum FetchOutcome: Sendable {
        case icon(Data)
        case missing
        case unavailable
        case cancelled
    }

    private let session: URLSession
    private let cacheDirectory: URL
    private var inFlight: [String: InFlightFetch] = [:]
    private var failures = WebsiteIconFailureLog()
    private var hasLoadedState = false
    private var saveTask: Task<Void, Never>?
    private var activeFetches = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    private var fallbackProbes: [String: Task<String?, Never>] = [:]

    init(cacheDirectory: URL = AutoFillSharedVault.websiteIconCacheDirectory) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = Self.maximumConcurrentFetches
        session = URLSession(configuration: configuration)
        self.cacheDirectory = cacheDirectory
    }

    /// The icon for `request`, decoded at its pixel size off the main thread.
    /// Nil means the site has none, or it can't be fetched right now.
    func icon(for request: WebsiteIconRequest) async -> WebsiteIconImage? {
        if let cached = WebsiteIconMemoryCache.image(for: request) { return cached }
        guard let data = await iconData(for: request) else { return nil }
        if let cached = WebsiteIconMemoryCache.image(for: request) { return cached }
        guard let image = Self.decode(data, maximumPixelSize: request.pixelSize) else { return nil }
        WebsiteIconMemoryCache.insert(image, for: request)
        return image
    }

    /// Warms icons for rows that are about to be on screen.
    nonisolated func prefetch(_ requests: [WebsiteIconRequest]) {
        let pending = requests.filter { WebsiteIconMemoryCache.image(for: $0) == nil }
        guard !pending.isEmpty else { return }
        Task(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for request in pending {
                    group.addTask { _ = await self.icon(for: request) }
                }
            }
        }
    }

    /// Forgets everything held in memory, for example after signing out.
    func reset() {
        for fetch in inFlight.values { fetch.task.cancel() }
        inFlight.removeAll()
        fallbackProbes.removeAll()
        failures = WebsiteIconFailureLog()
        hasLoadedState = false
        saveTask?.cancel()
        saveTask = nil
    }

    // MARK: Loading

    private func iconData(for request: WebsiteIconRequest) async -> Data? {
        let key = WebsiteIconHost.diskKey(serverURL: request.serverURL, host: request.host)
        let storageKey = WebsiteIconHost.diskKey(serverURL: request.serverURL, host: request.storageHost)
        loadStateIfNeeded()
        if let data = cachedData(storageKey: storageKey, key: key, serverURL: request.serverURL) {
            return data
        }
        guard !failures.shouldSkip(key, at: .now) else { return nil }

        let fetchID: UUID
        let task: Task<Data?, Never>
        if var existing = inFlight[key] {
            existing.waiters += 1
            inFlight[key] = existing
            fetchID = existing.id
            task = existing.task
        } else {
            let id = UUID()
            let host = request.host
            let serverURL = request.serverURL
            let newTask = Task { await self.download(host: host, key: key, id: id, serverURL: serverURL) }
            inFlight[key] = InFlightFetch(id: id, task: newTask, waiters: 1)
            fetchID = id
            task = newTask
        }

        let data = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            Task { await self.releaseWaiter(key: key, id: fetchID) }
        }
        if let data, !fileExists(named: storageKey) {
            persist(data, named: storageKey)
        }
        return data
    }

    private func download(host: String, key: String, id: UUID, serverURL: URL) async -> Data? {
        defer {
            if inFlight[key]?.id == id { inFlight[key] = nil }
        }
        await acquireFetchSlot()
        defer { releaseFetchSlot() }
        guard !Task.isCancelled else { return nil }

        switch await fetch(host: host, serverURL: serverURL) {
        case let .icon(data):
            if await isServerFallback(data, serverURL: serverURL) {
                failures.recordMissing(key, at: .now)
                scheduleStateSave()
                return nil
            }
            failures.recordSuccess(key)
            return data
        case .missing:
            failures.recordMissing(key, at: .now)
            scheduleStateSave()
            return nil
        case .unavailable:
            failures.recordTransientFailure(key, at: .now)
            return nil
        case .cancelled:
            return nil
        }
    }

    private func fetch(host: String, serverURL: URL) async -> FetchOutcome {
        let iconURL = serverURL
            .appendingPathComponent("icons", isDirectory: true)
            .appendingPathComponent(host, isDirectory: true)
            .appendingPathComponent("icon.png", isDirectory: false)
        var request = URLRequest(url: iconURL)
        request.httpMethod = "GET"
        request.setValue("image/*", forHTTPHeaderField: "Accept")

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: request)
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled { return .cancelled }
            return .unavailable
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse else { return .unavailable }
        switch http.statusCode {
        case 200..<300:
            guard data.count <= Self.maximumIconBytes, Self.isImageData(data) else { return .missing }
            return .icon(data)
        case 408, 429:
            return .unavailable
        case 400..<500:
            return .missing
        default:
            return .unavailable
        }
    }

    /// Releases one waiter. When nobody waits any more (the rows scrolled away
    /// before a fetch slot opened), the download is cancelled.
    private func releaseWaiter(key: String, id: UUID) {
        guard var fetch = inFlight[key], fetch.id == id else { return }
        fetch.waiters -= 1
        if fetch.waiters > 0 {
            inFlight[key] = fetch
        } else {
            fetch.task.cancel()
            inFlight[key] = nil
        }
    }

    private func acquireFetchSlot() async {
        if activeFetches < Self.maximumConcurrentFetches {
            activeFetches += 1
            return
        }
        await withCheckedContinuation { continuation in
            slotWaiters.append(continuation)
        }
    }

    private func releaseFetchSlot() {
        if slotWaiters.isEmpty {
            activeFetches = max(0, activeFetches - 1)
        } else {
            // The slot passes straight to the next download.
            slotWaiters.removeFirst().resume()
        }
    }

    // MARK: Server stand-in icon

    private func isServerFallback(_ data: Data, serverURL: URL) async -> Bool {
        guard let digest = await fallbackDigest(serverURL: serverURL) else { return false }
        return Self.digest(of: data) == digest
    }

    /// Asked once per launch, outside the fetch slots so it can't wait behind
    /// the downloads that are waiting for it.
    private func fallbackDigest(serverURL: URL) async -> String? {
        let serverKey = Self.serverKey(serverURL)
        if let probe = fallbackProbes[serverKey] { return await probe.value }
        let probe = Task { () -> String? in
            guard case let .icon(data) = await self.fetch(host: Self.fallbackProbeHost, serverURL: serverURL) else {
                return nil
            }
            return Self.digest(of: data)
        }
        fallbackProbes[serverKey] = probe
        guard let digest = await probe.value else {
            return failures.fallbackDigest(forServer: serverKey)
        }
        if failures.fallbackDigest(forServer: serverKey) != digest {
            failures.setFallbackDigest(digest, forServer: serverKey)
            scheduleStateSave()
        }
        return digest
    }

    private func startFallbackProbeIfNeeded(serverURL: URL) {
        let serverKey = Self.serverKey(serverURL)
        guard fallbackProbes[serverKey] == nil else { return }
        Task { _ = await self.fallbackDigest(serverURL: serverURL) }
    }

    // MARK: Disk

    private func cachedData(storageKey: String, key: String, serverURL: URL) -> Data? {
        let primary = fileURL(named: storageKey)
        var candidates = [primary]
        if key != storageKey { candidates.append(fileURL(named: key)) }
        if let legacy = Self.legacyCacheDirectory {
            candidates.append(legacy.appendingPathComponent("\(storageKey).icon", isDirectory: false))
        }

        for url in candidates {
            guard let data = try? Data(contentsOf: url), Self.isImageData(data) else { continue }
            let serverKey = Self.serverKey(serverURL)
            if let fallback = failures.fallbackDigest(forServer: serverKey) {
                if Self.digest(of: data) == fallback {
                    // Saved by an earlier version that kept the server's stand-in.
                    try? FileManager.default.removeItem(at: url)
                    failures.recordMissing(key, at: .now)
                    scheduleStateSave()
                    return nil
                }
            } else {
                startFallbackProbeIfNeeded(serverURL: serverURL)
            }
            if url != primary { persist(data, named: storageKey) }
            return data
        }
        return nil
    }

    private func fileURL(named name: String) -> URL {
        cacheDirectory.appendingPathComponent("\(name).icon", isDirectory: false)
    }

    private func fileExists(named name: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(named: name).path)
    }

    private func persist(_ data: Data, named name: String) {
        write(data, to: fileURL(named: name))
    }

    private func write(_ data: Data, to fileURL: URL) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL, options: ClientPlatform.encryptedFileWritingOptions)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var protectedURL = fileURL
            try? protectedURL.setResourceValues(values)
        } catch {
            // Icons are cosmetic. The in-memory copy still works when disk caching fails.
        }
    }

    private var stateURL: URL {
        cacheDirectory.appendingPathComponent(Self.stateFileName, isDirectory: false)
    }

    private func loadStateIfNeeded() {
        guard !hasLoadedState else { return }
        hasLoadedState = true
        guard let data = try? Data(contentsOf: stateURL),
              var saved = try? JSONDecoder().decode(WebsiteIconFailureLog.self, from: data) else { return }
        saved.removeExpired(at: .now)
        failures = saved
    }

    /// Failures tend to arrive in bursts while a list loads; write once afterwards.
    private func scheduleStateSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.saveState()
        }
    }

    private func saveState() {
        failures.removeExpired(at: .now)
        guard let data = try? JSONEncoder().encode(failures) else { return }
        write(data, to: stateURL)
    }

    private static var legacyCacheDirectory: URL? {
        try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).appendingPathComponent("WebsiteIcons", isDirectory: true)
    }

    // MARK: Decoding

    private static func serverKey(_ serverURL: URL) -> String {
        WebsiteIconHost.diskKey(serverURL: serverURL, host: "")
    }

    private static func digest(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func isImageData(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let prefix = Array(data.prefix(12))
        let isPNG = prefix.starts(with: [0x89, 0x50, 0x4E, 0x47])
        let isJPEG = prefix.starts(with: [0xFF, 0xD8, 0xFF])
        let isGIF = prefix.starts(with: Array("GIF8".utf8))
        let isICO = prefix.starts(with: [0x00, 0x00, 0x01, 0x00])
        let isWebP = prefix.starts(with: Array("RIFF".utf8))
            && prefix.count >= 12
            && Array(prefix[8..<12]) == Array("WEBP".utf8)
        return isPNG || isJPEG || isGIF || isICO || isWebP
    }

    /// Decodes straight to the display size, from the largest image in the file.
    static func decode(_ data: Data, maximumPixelSize: Int) -> WebsiteIconImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return nil }

        var bestIndex = 0
        var bestWidth = 0
        for index in 0..<count {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int else { continue }
            if width > bestWidth {
                bestWidth = width
                bestIndex = index
            }
        }

        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maximumPixelSize)
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, bestIndex, thumbnailOptions as CFDictionary) else {
            return nil
        }
        let fillsTile = bestWidth >= 96 && isOpaqueToCorners(image)
        return WebsiteIconImage(cgImage: image, fillsTile: fillsTile)
    }

    /// Samples the corners of a tiny copy: an icon with its own opaque background
    /// fills the tile; one with transparent corners sits inset on white.
    private static func isOpaqueToCorners(_ image: CGImage) -> Bool {
        let side = 4
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        return pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            let corners = [0, side - 1, side * (side - 1), side * side - 1]
            return corners.allSatisfy { buffer[$0 * 4 + 3] >= 250 }
        }
    }
}
