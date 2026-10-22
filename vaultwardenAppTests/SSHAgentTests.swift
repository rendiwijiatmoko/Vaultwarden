#if os(macOS)
import BitwardenSdk
import CryptoKit
import Darwin
import XCTest
@testable import vaultwardenApp

@MainActor
final class SSHAgentTests: XCTestCase {
    func testRejectsMalformedAndUnsupportedRequests() throws {
        for payload in [Data(), Data([11, 0]), Data([13]), Data([13, 255, 255, 255, 255]),
                        Data(repeating: 0, count: SSHAgentRequest.maximumFrameSize + 1)] {
            XCTAssertThrowsError(try SSHAgentRequest.decode(payload))
        }
        for type: UInt8 in [1, 17, 18, 19, 22, 25, 27] {
            guard case .unsupported = try SSHAgentRequest.decode(Data([type])) else {
                return XCTFail("Unexpectedly accepted key management or unsupported operation")
            }
        }
    }

    func testEd25519SignatureMatchesPublicKeyAndRejectsMismatchedKeys() throws {
        let key = try SSHKeyGenerator.generate()
        let other = try SSHKeyGenerator.generate()
        let blob = try SSHAgentSigner.publicBlob(key.publicKey)
        let message = Data("SSH authentication challenge".utf8)
        let response = try SSHAgentSigner.sign(privateKey: key.privateKey, publicKey: blob, message: message, flags: 0)
        var reply = SSHWireReader(data: response)
        XCTAssertEqual(try reply.byte(), 14)
        var signature = SSHWireReader(data: try reply.string())
        XCTAssertEqual(try signature.text(), "ssh-ed25519")
        var publicReader = SSHWireReader(data: blob)
        _ = try publicReader.text()
        let verifier = try Curve25519.Signing.PublicKey(rawRepresentation: publicReader.string())
        XCTAssertTrue(verifier.isValidSignature(try signature.string(), for: message))
        XCTAssertTrue(signature.isAtEnd)
        XCTAssertTrue(reply.isAtEnd)
        XCTAssertThrowsError(try SSHAgentSigner.sign(privateKey: other.privateKey, publicKey: blob, message: message, flags: 0))
        XCTAssertThrowsError(try SSHAgentSigner.sign(privateKey: key.privateKey, publicKey: blob, message: message, flags: 2))
    }

    func testOpenSSHListsAndVerifiesEd25519ThroughSocket() async throws {
        let key = try SSHKeyGenerator.generate()
        try await verifyWithOpenSSH(privateKey: key.privateKey, publicKey: key.publicKey)
    }

    func testGeneratedAlgorithmsWorkThroughSSHAgent() async throws {
        for algorithm in SSHKeyAlgorithm.allCases {
            let key = try SSHKeyGenerator.generate(algorithm: algorithm)
            try await verifyWithOpenSSH(privateKey: key.privateKey, publicKey: key.publicKey)
        }
    }

    func testOpenSSHVerifiesRSA2048And4096WithoutSHA1() async throws {
        for bits in [2048, 4096] {
            let directory = try Self.directory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let keyPath = directory.appendingPathComponent("rsa").path
            _ = try await Task.detached {
                try Self.run("/usr/bin/ssh-keygen", ["-t", "rsa", "-b", String(bits), "-N", "", "-f", keyPath])
            }.value
            let privateKey = try String(contentsOfFile: keyPath, encoding: .utf8)
            let publicKey = try String(contentsOfFile: keyPath + ".pub", encoding: .utf8)
            let blob = try SSHAgentSigner.publicBlob(publicKey)
            for flags: UInt32 in [2, 4, 6] {
                let response = try SSHAgentSigner.sign(privateKey: privateKey, publicKey: blob,
                                                       message: Data("test-only".utf8), flags: flags)
                var reply = SSHWireReader(data: response)
                XCTAssertEqual(try reply.byte(), 14)
                var signature = SSHWireReader(data: try reply.string())
                XCTAssertEqual(try signature.text(), flags & 4 != 0 ? "rsa-sha2-512" : "rsa-sha2-256")
            }
            for flags: UInt32 in [0, 1, 8] {
                XCTAssertThrowsError(try SSHAgentSigner.sign(privateKey: privateKey, publicKey: blob,
                                                            message: Data(), flags: flags))
            }
            try await verifyWithOpenSSH(privateKey: privateKey, publicKey: publicKey)
        }
    }

    func testSocketPermissionsCollisionAndRestart() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agent.sock").path
        let first = SSHAgentSocket { _ in SSHAgentRequest.failure }
        let second = SSHAgentSocket { _ in SSHAgentRequest.failure }
        try first.start(at: path)
        defer { first.stop(); second.stop() }
        var metadata = stat()
        XCTAssertEqual(lstat(path, &metadata), 0)
        XCTAssertEqual(metadata.st_mode & 0o777, 0o600)
        XCTAssertThrowsError(try second.start(at: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        first.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        try second.start(at: path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testSocketNeverDeletesAnExistingRegularFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agent.sock")
        try "keep".write(to: path, atomically: true, encoding: .utf8)
        let socket = SSHAgentSocket { _ in SSHAgentRequest.failure }
        XCTAssertThrowsError(try socket.start(at: path.path))
        XCTAssertEqual(try String(contentsOf: path, encoding: .utf8), "keep")
    }

    func testRecoversAnOwnedStaleSocket() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("agent.sock").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        XCTAssertEqual(result, 0)
        let transport = SSHAgentSocket { _ in SSHAgentRequest.failure }
        try transport.start(at: path)
        transport.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testOlderSettingsDefaultToDisabledWithoutLosingExistingValues() throws {
        var settings = AppSettings()
        settings.serverURL = "https://example.invalid"
        settings.email = "test@example.invalid"
        settings.theme = .dark
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "sshAgentEnabled")
        json.removeValue(forKey: "sshAgentAllowedKeyIDs")
        json.removeValue(forKey: "sshAgentApprovals")
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.email, settings.email)
        XCTAssertEqual(restored.serverURL, settings.serverURL)
        XCTAssertEqual(restored.theme, .dark)
        XCTAssertNotEqual(restored.sshAgentEnabled, true)
        XCTAssertNil(restored.sshAgentAllowedKeyIDs)
        XCTAssertNil(restored.sshAgentApprovals)
    }

    func testAlwaysApprovalPersistsAndRespectsScopeLockAndRevocation() async throws {
        let suite = "SSHAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = try SSHKeyGenerator.generate()
        let item = VaultItem(name: "Remembered SSH", username: key.publicKey, password: key.privateKey, type: .sshKey)
        var settings = AppSettings()
        settings.serverURL = "https://example.invalid"
        settings.email = "test@example.invalid"
        settings.sessionReference = "ssh-agent-test-only"
        settings.sshAgentEnabled = true
        settings.sshAgentAllowedKeyIDs = [item.id]
        settings.syncOnOpen = false
        settings.backgroundRefresh = false
        defaults.set(try JSONEncoder().encode(settings), forKey: "vaultwardenApp.settings")
        let store = AppStore(settingsDefaults: defaults)
        store.isLocked = false
        store.items = [item]
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = MacSSHAgent(store: store, socketPath: directory.appendingPathComponent("agent.sock").path)
        defer { store.settings.sshAgentEnabled = false }
        let blob = try SSHAgentSigner.publicBlob(key.publicKey)
        let payload = Data([13]) + SSHWire.string(blob) + SSHWire.string(Data("challenge".utf8)) + SSHWire.uint32(0)

        let once = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        agent.resolvePrompt(approved: true)
        let onceResult = await once.value
        XCTAssertEqual(onceResult.first, 14)
        XCTAssertFalse(agent.isAlwaysApproved(item))

        let always = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        agent.resolvePrompt(approved: true, alwaysApprove: true)
        let alwaysResult = await always.value
        XCTAssertEqual(alwaysResult.first, 14)
        XCTAssertTrue(agent.isAlwaysApproved(item))
        let repeated = await agent.handle(payload)
        XCTAssertEqual(repeated.first, 14)
        XCTAssertNil(agent.prompt)

        // Recreate the store and agent from saved settings, as after app restart.
        let restoredStore = AppStore(settingsDefaults: defaults)
        restoredStore.isLocked = false
        restoredStore.items = [item]
        let restoredAgent = MacSSHAgent(store: restoredStore,
                                        socketPath: directory.appendingPathComponent("restored.sock").path)
        defer { restoredStore.settings.sshAgentEnabled = false }
        XCTAssertTrue(restoredAgent.isAlwaysApproved(item))
        let afterRestart = await restoredAgent.handle(payload)
        XCTAssertEqual(afterRestart.first, 14)
        XCTAssertNil(restoredAgent.prompt)

        let grant = try XCTUnwrap(store.settings.sshAgentApprovals?.first)
        for otherGrant in [
            SSHAgentApproval(accountID: "other@example.invalid", serverURL: grant.serverURL,
                             keyID: item.id, fingerprint: grant.fingerprint),
            SSHAgentApproval(accountID: grant.accountID, serverURL: URL(string: "https://other.invalid")!,
                             keyID: item.id, fingerprint: grant.fingerprint),
            SSHAgentApproval(accountID: grant.accountID, serverURL: grant.serverURL,
                             keyID: UUID(), fingerprint: grant.fingerprint),
            SSHAgentApproval(accountID: grant.accountID, serverURL: grant.serverURL,
                             keyID: item.id, fingerprint: "SHA256:different")
        ] {
            store.settings.sshAgentApprovals = [otherGrant]
            let wrongScope = Task { await agent.handle(payload) }
            try await waitForPrompt(agent)
            agent.resolvePrompt(approved: false)
            let wrongScopeResult = await wrongScope.value
            XCTAssertEqual(wrongScopeResult, SSHAgentRequest.failure)
        }
        store.settings.sshAgentApprovals = [grant]

        store.isLocked = true
        let locked = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        XCTAssertNil(agent.prompt?.keyName, "Remembered approval must still require unlocking")
        agent.resolvePrompt(approved: false)
        let lockedResult = await locked.value
        XCTAssertEqual(lockedResult, SSHAgentRequest.failure)
        store.isLocked = false

        store.settings.sshAgentAllowedKeyIDs = []
        let deselected = await agent.handle(payload)
        XCTAssertEqual(deselected, SSHAgentRequest.failure)
        store.settings.sshAgentAllowedKeyIDs = [item.id]
        var deleted = item
        deleted.deletedAt = Date()
        store.items = [deleted]
        let deletedResult = await agent.handle(payload)
        XCTAssertEqual(deletedResult, SSHAgentRequest.failure)
        store.items = [item]

        agent.revokeAlwaysApproval(for: item.id)
        XCTAssertFalse(agent.isAlwaysApproved(item))
        let revoked = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        agent.resolvePrompt(approved: true)
        let revokedResult = await revoked.value
        XCTAssertEqual(revokedResult.first, 14)
        XCTAssertFalse(agent.isAlwaysApproved(item))
    }

    func testAuthorizationAndVaultPolicy() async throws {
        let suite = "SSHAgentTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = try SSHKeyGenerator.generate()
        let item = VaultItem(name: "Test SSH", username: key.publicKey, password: key.privateKey, type: .sshKey)
        var settings = AppSettings()
        settings.serverURL = "https://example.invalid"
        settings.email = "test@example.invalid"
        settings.sessionReference = "ssh-agent-test-only"
        settings.sshAgentEnabled = true
        settings.sshAgentAllowedKeyIDs = [item.id]
        settings.syncOnOpen = false
        settings.backgroundRefresh = false
        defaults.set(try JSONEncoder().encode(settings), forKey: "vaultwardenApp.settings")
        let store = AppStore(settingsDefaults: defaults)
        store.isLocked = false
        store.items = [item]
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let agent = MacSSHAgent(store: store, socketPath: directory.appendingPathComponent("agent.sock").path,
                                authorizationTimeout: .milliseconds(500))
        defer { store.settings.sshAgentEnabled = false }
        XCTAssertTrue(agent.isRunning)
        let blob = try SSHAgentSigner.publicBlob(key.publicKey)
        let payload = Data([13]) + SSHWire.string(blob) + SSHWire.string(Data("challenge".utf8)) + SSHWire.uint32(0)
        let identities = await agent.handle(Data([11]))
        XCTAssertEqual(identities, SSHAgentRequest.identities([(blob, "Test SSH")]))

        let approved = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        XCTAssertEqual(agent.prompt?.fingerprint, SSHAgentSigner.fingerprint(blob))
        let previousPromptID = try XCTUnwrap(agent.prompt?.id)
        agent.resolvePrompt(approved: true)
        let signature = await approved.value
        XCTAssertEqual(signature.first, 14)

        // Returning to the app can sync identical key material with new timestamps
        // or unrelated items. This must leave the approval sheet open.
        let refreshed = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        var refreshedItem = item
        refreshedItem.updatedAt = Date().addingTimeInterval(30)
        store.items = [refreshedItem, VaultItem(name: "Unrelated login")]
        store.settings.showFavicons.toggle()
        await Task.yield()
        XCTAssertNotNil(agent.prompt)
        agent.resolvePrompt(approved: true)
        let refreshedSignature = await refreshed.value
        XCTAssertEqual(refreshedSignature.first, 14)

        let denied = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        agent.resolvePrompt(id: previousPromptID, approved: true, alwaysApprove: true)
        XCTAssertNotNil(agent.prompt, "A stale unlock callback must not approve a newer SSH request")
        agent.cancelPrompt(id: previousPromptID)
        XCTAssertNotNil(agent.prompt, "Dismissing an earlier sheet must not cancel a new request")
        agent.resolvePrompt(approved: false)
        let denial = await denied.value
        XCTAssertEqual(denial, SSHAgentRequest.failure)

        let locked = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        store.isLocked = true
        agent.resolvePrompt(approved: true)
        let lockResult = await locked.value
        XCTAssertEqual(lockResult, SSHAgentRequest.failure)
        store.isLocked = false

        let removed = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        store.items = []
        agent.resolvePrompt(approved: true)
        let removalResult = await removed.value
        XCTAssertEqual(removalResult, SSHAgentRequest.failure)

        store.items = [item]
        let canceled = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        canceled.cancel()
        let cancelResult = await canceled.value
        XCTAssertEqual(cancelResult, SSHAgentRequest.failure)
        XCTAssertNil(agent.prompt)

        store.isLocked = true
        let unlockListing = Task { await agent.handle(Data([11])) }
        try await waitForPrompt(agent)
        XCTAssertNil(agent.prompt?.keyName)
        store.isLocked = false
        agent.resolvePrompt(approved: true)
        let unlockedIdentities = await unlockListing.value
        XCTAssertEqual(unlockedIdentities, SSHAgentRequest.identities([(blob, "Test SSH")]))

        let timedOut = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        let timeoutResult = await timedOut.value
        XCTAssertEqual(timeoutResult, SSHAgentRequest.failure)
        XCTAssertNil(agent.prompt)

        for excluded in [
            VaultItem(name: "Deleted", username: key.publicKey, password: key.privateKey, type: .sshKey, deletedAt: Date()),
            VaultItem(name: "Archived", username: key.publicKey, password: key.privateKey, type: .sshKey, archivedAt: Date()),
            VaultItem(name: "Restricted", username: key.publicKey, password: key.privateKey, type: .sshKey, organization: "Team")
        ] {
            XCTAssertFalse(store.canUseSSHKey(excluded))
        }

        let disabled = Task { await agent.handle(payload) }
        try await waitForPrompt(agent)
        store.settings.sshAgentAllowedKeyIDs = []
        let disabledResult = await disabled.value
        XCTAssertEqual(disabledResult, SSHAgentRequest.failure)
        let emptyIdentities = await agent.handle(Data([11]))
        XCTAssertEqual(emptyIdentities, SSHAgentRequest.identities([]))
        store.settings.sshAgentEnabled = false
        XCTAssertFalse(agent.isRunning)
        let stoppedResult = await agent.handle(payload)
        XCTAssertEqual(stoppedResult, SSHAgentRequest.failure)
    }

    private func waitForPrompt(_ agent: MacSSHAgent) async throws {
        for _ in 0..<200 {
            if agent.prompt != nil { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Authorization prompt was not presented")
        throw SSHAgentError.unavailable
    }

    private func verifyWithOpenSSH(privateKey: String, publicKey: String) async throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let publicURL = directory.appendingPathComponent("key.pub")
        try publicKey.write(to: publicURL, atomically: true, encoding: .utf8)
        let path = directory.appendingPathComponent("agent.sock").path
        let socket = try Self.testSocket(privateKey: privateKey, publicKey: publicKey)
        try socket.start(at: path)
        defer { socket.stop() }
        let listed = try await Task.detached {
            try Self.run("/usr/bin/ssh-add", ["-L"], socketPath: path)
        }.value
        XCTAssertTrue(listed.contains(publicKey.split(separator: " ")[1]))
        _ = try await Task.detached {
            try Self.run("/usr/bin/ssh-add", ["-T", publicURL.path], socketPath: path)
        }.value
    }

    nonisolated private static func testSocket(privateKey: String, publicKey: String) throws -> SSHAgentSocket {
        let blob = try SSHAgentSigner.publicBlob(publicKey)
        return SSHAgentSocket { payload in
            guard let request = try? SSHAgentRequest.decode(payload) else { return SSHAgentRequest.failure }
            switch request {
            case .identities: return SSHAgentRequest.identities([(blob, "Test key")])
            case let .sign(requested, message, flags):
                guard requested == blob else { return SSHAgentRequest.failure }
                return (try? SSHAgentSigner.sign(privateKey: privateKey, publicKey: blob,
                                                 message: message, flags: flags)) ?? SSHAgentRequest.failure
            case .unsupported: return SSHAgentRequest.failure
            }
        }
    }

    nonisolated private static func directory() throws -> URL {
        let directory = URL(fileURLWithPath: "/tmp/va-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return directory
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String], socketPath: String? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let socketPath {
            var environment = ProcessInfo.processInfo.environment
            environment["SSH_AUTH_SOCK"] = socketPath
            process.environment = environment
        }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw SSHAgentError.unavailable }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
