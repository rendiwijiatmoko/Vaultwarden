import Foundation
import Testing
@testable import vaultwardenApp

struct WebsiteIconHostTests {
    @Test(arguments: [
        ("https://www.GitHub.com/login", "github.com"),
        ("github.com", "github.com"),
        ("www.example.co.uk/path?query=1", "example.co.uk"),
        ("http://accounts.google.com:8443", "accounts.google.com"),
        ("  https://Example.org.  ", "example.org"),
        ("https://user:pass@mail.example.net/inbox", "mail.example.net")
    ])
    func normalizesWebsites(uri: String, expected: String) {
        #expect(WebsiteIconHost.iconHost(for: uri) == expected)
    }

    @Test(arguments: [
        "",
        "   ",
        "androidapp://com.example.app",
        "iosapp://com.example.app",
        "192.168.1.1",
        "https://10.0.0.2:8080",
        "https://[::1]/",
        "localhost:5000",
        "nas",
        "printer.local",
        "router.lan",
        "build.internal",
        "https://www.com"
    ])
    func refusesHostsWithoutAPublicIcon(uri: String) {
        #expect(WebsiteIconHost.iconHost(for: uri) == nil)
    }

    @Test func storageHostMatchesTheAutoFillExtension() {
        // AutoFill names cache files by this host, with "www." kept.
        #expect(WebsiteIconHost.storageHost(for: "www.GitHub.com/login") == "www.github.com")
        #expect(WebsiteIconHost.storageHost(for: "https://github.com") == "github.com")
    }

    @Test func diskKeyDependsOnServerAndHost() throws {
        let server = try #require(URL(string: "https://vault.example.com"))
        let other = try #require(URL(string: "https://other.example.com"))
        let key = WebsiteIconHost.diskKey(serverURL: server, host: "github.com")
        #expect(key.count == 64)
        #expect(key == WebsiteIconHost.diskKey(serverURL: server, host: "github.com"))
        #expect(key != WebsiteIconHost.diskKey(serverURL: other, host: "github.com"))
        #expect(key != WebsiteIconHost.diskKey(serverURL: server, host: "gitlab.com"))
    }

    @Test func recognizesImageSignatures() {
        #expect(WebsiteIconRepository.isImageData(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A])))
        #expect(WebsiteIconRepository.isImageData(Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00])))
        #expect(WebsiteIconRepository.isImageData(Data("<svg xmlns=".utf8)) == false)
        #expect(WebsiteIconRepository.isImageData(Data([0xFF])) == false)
    }
}

struct WebsiteIconFailureLogTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func missingIconIsNotAskedForAgainForADay() {
        var log = WebsiteIconFailureLog()
        log.recordMissing("key", at: now)
        #expect(log.shouldSkip("key", at: now.addingTimeInterval(60)))
        #expect(log.shouldSkip("key", at: now.addingTimeInterval(23 * 60 * 60)))
        #expect(log.shouldSkip("key", at: now.addingTimeInterval(24 * 60 * 60 + 1)) == false)
        #expect(log.shouldSkip("other", at: now) == false)
    }

    @Test func transientFailureRetriesSoon() {
        var log = WebsiteIconFailureLog()
        log.recordTransientFailure("key", at: now)
        #expect(log.shouldSkip("key", at: now.addingTimeInterval(5 * 60)))
        #expect(log.shouldSkip("key", at: now.addingTimeInterval(11 * 60)) == false)
    }

    @Test func clockMovedBackDoesNotHoldAHostOffLonger() {
        var log = WebsiteIconFailureLog()
        log.recordMissing("key", at: now)
        // Two days earlier than the failure: the retry date is too far away to trust.
        #expect(log.shouldSkip("key", at: now.addingTimeInterval(-2 * 24 * 60 * 60)) == false)
    }

    @Test func successClearsFailures() {
        var log = WebsiteIconFailureLog()
        log.recordMissing("key", at: now)
        log.recordSuccess("key")
        #expect(log.shouldSkip("key", at: now) == false)
    }

    @Test func onlyMissingIconsAndFallbacksArePersisted() throws {
        var log = WebsiteIconFailureLog()
        log.recordMissing("missing", at: now)
        log.recordTransientFailure("offline", at: now)
        log.setFallbackDigest("abc", forServer: "server")

        let data = try JSONEncoder().encode(log)
        let decoded = try JSONDecoder().decode(WebsiteIconFailureLog.self, from: data)

        #expect(decoded.shouldSkip("missing", at: now))
        #expect(decoded.shouldSkip("offline", at: now) == false)
        #expect(decoded.fallbackDigest(forServer: "server") == "abc")
    }

    @Test func expiredEntriesAreRemoved() {
        var log = WebsiteIconFailureLog()
        log.recordMissing("key", at: now)
        log.removeExpired(at: now.addingTimeInterval(25 * 60 * 60))
        #expect(log.missing.isEmpty)
    }
}

struct VaultMonogramTests {
    @Test(arguments: [
        ("GitHub", nil as String?, "G"),
        ("  (work) mail", nil, "W"),
        ("élan", nil, "É"),
        ("123 Bank", nil, "1"),
        ("", "example.com", "E"),
        ("🔑", "vault.example.com", "V")
    ])
    func letterComesFromTheNameThenTheHost(name: String, host: String?, expected: String) {
        #expect(VaultMonogram.letter(name: name, host: host) == expected)
    }

    @Test func noLetterWhenNeitherHasOne() {
        #expect(VaultMonogram.letter(name: "🔑", host: nil) == nil)
    }

    @Test func tintIsStableAndInRange() {
        // Fixed values: the tint must not change between launches or releases.
        let first = VaultMonogram.tintIndex(for: "github.com")
        #expect(first == VaultMonogram.tintIndex(for: "github.com"))
        #expect((0..<VaultMonogram.palette.count).contains(first))
        #expect(VaultMonogram.tintIndex(for: "", paletteSize: 8) == Int(UInt64(0xcbf2_9ce4_8422_2325) % 8))
    }

    @Test func tintSeedPrefersTheHost() {
        #expect(VaultMonogram.tintSeed(name: "My GitHub", host: "github.com") == "github.com")
        #expect(VaultMonogram.tintSeed(name: " Bank ", host: nil) == "bank")
    }

    @Test func tintsSpreadAcrossThePalette() {
        let hosts = (0..<64).map { "site\($0).example.com" }
        let used = Set(hosts.map { VaultMonogram.tintIndex(for: $0) })
        #expect(used.count > VaultMonogram.palette.count / 2)
    }
}
