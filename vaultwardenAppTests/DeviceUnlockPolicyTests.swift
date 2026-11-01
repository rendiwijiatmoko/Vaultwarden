import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import vaultwardenApp

final class DeviceUnlockPolicyTests: XCTestCase {
    func testNewSettingsRequireOptIn() {
        XCTAssertFalse(AppSettings().biometricUnlock)
        XCTAssertFalse(AppSettings().devicePasscodeFallback)
        XCTAssertEqual(DeviceUnlockPolicy(biometricsEnabled: false, passcodeFallback: true), .disabled)
    }

    func testFallbackOffRequiresCurrentBiometricEnrollmentInBothLayers() {
        let policy = DeviceUnlockPolicy(biometricsEnabled: true, passcodeFallback: false)
        XCTAssertEqual(policy.accessControlFlags, .biometryCurrentSet)
        XCTAssertEqual(policy.authenticationPolicy, .deviceOwnerAuthenticationWithBiometrics)
        XCTAssertThrowsError(try DeviceUnlockPolicy.disabled.makeAccessControl())
    }

    func testPasscodeIsAllowedOnlyWithExplicitFallback() {
        let policy = DeviceUnlockPolicy(biometricsEnabled: true, passcodeFallback: true)
        XCTAssertEqual(policy.accessControlFlags, .userPresence)
        XCTAssertEqual(policy.authenticationPolicy, .deviceOwnerAuthentication)
    }

    func testDisablingRevokesVaultAndAutoFillKeysAndDoesNotRecreateVaultKey() throws {
        let original = DeviceUnlockPolicy.current
        defer { try? DeviceUnlockPolicy.configure(original) }
        try DeviceUnlockPolicy.configure(.biometricsOrPasscode)
        let reference = "device-unlock-test-\(UUID().uuidString)"
        let services = [
            AutoFillSharedVault.vaultKeyService, AutoFillSharedVault.payloadKeyService,
            "xyz.0xmwehehe.vaultwardenApp.session.vault-key",
            "xyz.0xmwehehe.vaultwardenApp.autofill.payload-key"
        ]
        for service in services {
            var query = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: true)
            query[kSecAttrService as String] = service
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            query[kSecValueData as String] = Data(repeating: 7, count: 64)
            XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
        }

        try DeviceUnlockPolicy.configure(.disabled)
        try KeychainSessionStore().saveVaultKey(Data(repeating: 8, count: 64), reference: reference)
        for service in services {
            var query = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: true)
            query[kSecAttrService as String] = service
            XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, nil), errSecItemNotFound)
        }
        XCTAssertThrowsError(try KeychainSessionStore().loadVaultKey(reference: reference, reason: "Test"))
    }

    func testLegacyVaultKeyCannotBeMigratedThroughDeviceAuthentication() throws {
        let original = DeviceUnlockPolicy.current
        defer { try? DeviceUnlockPolicy.configure(original) }
        try DeviceUnlockPolicy.configure(.biometricsOrPasscode)
        let reference = "legacy-device-unlock-test-\(UUID().uuidString)"
        var query = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: true)
        query[kSecAttrService as String] = "xyz.0xmwehehe.vaultwardenApp.session.vault-key"
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = Data(repeating: 7, count: 64)
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        XCTAssertThrowsError(try KeychainSessionStore().loadVaultKey(reference: reference, reason: "Test")) { error in
            guard case SessionStoreError.masterPasswordRequired = error else {
                return XCTFail("Legacy key must require the master password, got \(error)")
            }
        }
    }

    func testDisabledAutoFillFailsBeforeAuthentication() async throws {
        let original = DeviceUnlockPolicy.current
        let defaults = try XCTUnwrap(UserDefaults(suiteName: AutoFillSharedVault.appGroupIdentifier))
        let previousReference = defaults.string(forKey: AutoFillSharedVault.activeReferenceKey)
        defer {
            defaults.set(previousReference, forKey: AutoFillSharedVault.activeReferenceKey)
            try? DeviceUnlockPolicy.configure(original)
        }
        try DeviceUnlockPolicy.configure(.disabled)
        defaults.set("disabled-autofill-test", forKey: AutoFillSharedVault.activeReferenceKey)
        do {
            _ = try await AutoFillSharedVault.load(reason: "Must not prompt")
            XCTFail("Disabled AutoFill must not unlock")
        } catch {
            guard case AutoFillSharedVaultError.vaultUnavailable = error else {
                return XCTFail("Expected disabled AutoFill, got \(error)")
            }
        }
    }

    func testChangingFallbackRevokesPreviouslyPermissiveKeys() throws {
        let original = DeviceUnlockPolicy.current
        defer { try? DeviceUnlockPolicy.configure(original) }
        try DeviceUnlockPolicy.configure(.biometricsOrPasscode)
        let reference = "device-unlock-test-\(UUID().uuidString)"
        var query = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: true)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecValueData as String] = Data(repeating: 7, count: 64)
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)

        try DeviceUnlockPolicy.configure(.biometrics)
        XCTAssertEqual(DeviceUnlockPolicy.current, .biometrics)
        let lookup = AutoFillSharedVault.vaultKeyQuery(reference: reference, shared: true)
        XCTAssertEqual(SecItemCopyMatching(lookup as CFDictionary, nil), errSecItemNotFound)
    }
}
