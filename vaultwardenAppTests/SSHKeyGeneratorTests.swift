import CryptoKit
import XCTest
@testable import vaultwardenApp

final class SSHKeyGeneratorTests: XCTestCase {
    func testEd25519PublicKeyAndFingerprint() throws {
        let key = try SSHKeyGenerator.generate(comment: " laptop\nwork@example.com ")
        let fields = key.publicKey.split(separator: " ")
        XCTAssertEqual(fields.first, "ssh-ed25519")
        XCTAssertTrue(key.publicKey.hasSuffix("laptop work@example.com"))
        XCTAssertFalse(key.publicKey.contains("\n"))
        let blob = try XCTUnwrap(Data(base64Encoded: String(fields[1])))
        let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(key.fingerprint, expected)
        XCTAssertTrue(key.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        XCTAssertTrue(key.privateKey.contains("-----END OPENSSH PRIVATE KEY-----"))
        XCTAssertNotEqual(try SSHKeyGenerator.generate().publicKey, key.publicKey)
    }

    func testRSAKeysAndFingerprints() throws {
        for algorithm in [SSHKeyAlgorithm.rsa2048, .rsa4096] {
            let key = try SSHKeyGenerator.generate(algorithm: algorithm, comment: "rsa-test")
            let fields = key.publicKey.split(separator: " ")
            XCTAssertEqual(fields.first, "ssh-rsa")
            XCTAssertTrue(key.publicKey.hasSuffix(" rsa-test"))
            let blob = try XCTUnwrap(Data(base64Encoded: String(fields[1])))
            let expected = "SHA256:" + Data(SHA256.hash(data: blob)).base64EncodedString()
                .replacingOccurrences(of: "=", with: "")
            XCTAssertEqual(key.fingerprint, expected)
            XCTAssertTrue(key.privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        }
    }

    func testOlderCachedItemsDecodeWithoutFingerprintField() throws {
        let item = VaultItem(name: "Existing key", type: .sshKey, notes: "SHA256:legacy")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "sshKeyFingerprint")
        let decoded = try JSONDecoder().decode(VaultItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.sshKeyFingerprint)
        XCTAssertEqual(decoded.displayedSSHFingerprint, "SHA256:legacy")
    }

    #if os(macOS)
    func testOpenSSHReadsPrivateKeyAndMatchesPublicKeyAndFingerprint() throws {
        for algorithm in SSHKeyAlgorithm.allCases {
            try assertOpenSSHCompatibility(algorithm)
        }
    }

    private func assertOpenSSHCompatibility(_ algorithm: SSHKeyAlgorithm) throws {
        let key = try SSHKeyGenerator.generate(algorithm: algorithm, comment: "test-only")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let privateURL = directory.appendingPathComponent("key")
        let publicURL = directory.appendingPathComponent("key.pub")
        // Only disposable, generated test keys are written for interoperability testing.
        XCTAssertTrue(FileManager.default.createFile(atPath: privateURL.path,
            contents: Data(key.privateKey.utf8), attributes: [.posixPermissions: 0o600]))
        try key.publicKey.write(to: publicURL, atomically: true, encoding: .utf8)
        let derived = try sshKeygen(["-y", "-P", "", "-f", privateURL.path])
        XCTAssertEqual(Array(derived.split(separator: " ").prefix(2)),
                       Array(key.publicKey.split(separator: " ").prefix(2)))
        let fingerprint = try sshKeygen(["-l", "-E", "sha256", "-f", publicURL.path])
        XCTAssertTrue(fingerprint.contains(key.fingerprint))
        let expectedBits: String
        switch algorithm {
        case .ed25519: expectedBits = "256"
        case .rsa2048: expectedBits = "2048"
        case .rsa4096: expectedBits = "4096"
        }
        XCTAssertEqual(fingerprint.split(separator: " ").first.map(String.init), expectedBits)

        let message = Data("Disposable SSH interoperability test".utf8)
        let messageURL = directory.appendingPathComponent("message")
        let signersURL = directory.appendingPathComponent("allowed_signers")
        try message.write(to: messageURL)
        try "test-user \(key.publicKey)\n".write(to: signersURL, atomically: true, encoding: .utf8)
        _ = try sshKeygen(["-Y", "sign", "-f", privateURL.path, "-n", "vaultwarden-test", messageURL.path])
        let verification = try sshKeygen([
            "-Y", "verify", "-f", signersURL.path, "-I", "test-user",
            "-n", "vaultwarden-test", "-s", messageURL.path + ".sig"
        ], input: message)
        XCTAssertTrue(verification.contains("Good"))
    }

    private func sshKeygen(_ arguments: [String], input: Data? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        try process.run()
        if let input { stdin.fileHandleForWriting.write(input) }
        try stdin.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    #endif
}
