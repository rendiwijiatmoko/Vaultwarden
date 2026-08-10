import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

enum BiometricAuthenticator {
    static var displayName: String {
        switch currentType {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        default: "Biometrics"
        }
    }

    static var systemImage: String {
        switch currentType {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        default: "person.badge.key.fill"
        }
    }

    private static var currentType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
        return context.biometryType
    }

    static func authenticate(reason: String, allowPasscode: Bool = false) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        let policy: LAPolicy = allowPasscode ? .deviceOwnerAuthentication : .deviceOwnerAuthenticationWithBiometrics
        var error: NSError?
        guard context.canEvaluatePolicy(policy, error: &error) else { return false }
        do {
            return try await context.evaluatePolicy(policy, localizedReason: reason)
        } catch {
            return false
        }
    }
}

enum PasswordGenerator {
    private static let lowercase = Array("abcdefghijkmnopqrstuvwxyz")
    private static let uppercase = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let numbers = Array("23456789")
    private static let symbols = Array("!@#$%^&*+-=_?")
    private static let words = ["anchor", "amber", "bamboo", "beacon", "cedar", "cloud", "coral", "ember", "falcon", "forest", "harbor", "indigo", "island", "jungle", "lantern", "lotus", "mango", "meadow", "nebula", "ocean", "olive", "orbit", "pebble", "river", "saffron", "silent", "silver", "summit", "tiger", "velvet"]

    static func password(length: Int, uppercase: Bool, numbers: Bool, symbols: Bool) -> String {
        var source = lowercase
        if uppercase { source += self.uppercase }
        if numbers { source += self.numbers }
        if symbols { source += self.symbols }
        guard !source.isEmpty else { return "" }
        return String((0..<max(length, 4)).compactMap { _ in source.randomElement() })
    }

    static func passphrase(wordCount: Int, separator: String, capitalize: Bool, includeNumber: Bool) -> String {
        var result = (0..<max(wordCount, 3)).compactMap { _ in words.randomElement() }
        if capitalize { result = result.map { $0.capitalized } }
        var phrase = result.joined(separator: separator)
        if includeNumber { phrase += separator + String(Int.random(in: 10...99)) }
        return phrase
    }

    static func username() -> String {
        "\(words.randomElement() ?? "silent").\(words.randomElement() ?? "orbit").\(Int.random(in: 100...999))"
    }
}

nonisolated enum TOTPGenerator {
    static func code(secret: String, date: Date = Date(), digits: Int = 6, period: Int = 30) -> String? {
        let configuration = configuration(secret: secret, fallbackDigits: digits, fallbackPeriod: period)
        guard let keyData = decodeBase32(configuration.secret) else { return nil }
        var counter = UInt64(date.timeIntervalSince1970 / Double(configuration.period)).bigEndian
        let counterData = Data(bytes: &counter, count: MemoryLayout<UInt64>.size)
        let key = SymmetricKey(data: keyData)
        let bytes: [UInt8] = switch configuration.algorithm {
        case "SHA256": Array(HMAC<SHA256>.authenticationCode(for: counterData, using: key))
        case "SHA512": Array(HMAC<SHA512>.authenticationCode(for: counterData, using: key))
        default: Array(HMAC<Insecure.SHA1>.authenticationCode(for: counterData, using: key))
        }
        let offset = Int(bytes.last! & 0x0f)
        let value = (UInt32(bytes[offset] & 0x7f) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        let modulus = UInt32(pow(10.0, Double(configuration.digits)))
        return String(format: "%0*u", configuration.digits, value % modulus)
    }

    static func period(secret: String) -> Int {
        configuration(secret: secret, fallbackDigits: 6, fallbackPeriod: 30).period
    }

    private struct Configuration {
        let secret: String
        let algorithm: String
        let digits: Int
        let period: Int
    }

    private static func configuration(secret: String, fallbackDigits: Int, fallbackPeriod: Int) -> Configuration {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("otpauth://"),
              let components = URLComponents(string: trimmed) else {
            return Configuration(secret: trimmed, algorithm: "SHA1", digits: fallbackDigits, period: fallbackPeriod)
        }
        let parameters = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name.lowercased()] = item.value ?? ""
        }
        let resolvedDigits = Int(parameters["digits"] ?? "").flatMap { (6...8).contains($0) ? $0 : nil }
            ?? fallbackDigits
        let resolvedPeriod = Int(parameters["period"] ?? "").flatMap { $0 > 0 ? $0 : nil }
            ?? fallbackPeriod
        return Configuration(
            secret: parameters["secret"] ?? "",
            algorithm: (parameters["algorithm"] ?? "SHA1").uppercased(),
            digits: resolvedDigits,
            period: resolvedPeriod
        )
    }

    private static func decodeBase32(_ input: String) -> Data? {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let cleaned = input.uppercased().filter { !$0.isWhitespace && $0 != "=" }
        var buffer = 0
        var bitsLeft = 0
        var output = Data()
        for character in cleaned {
            guard let index = alphabet.firstIndex(of: character) else { return nil }
            buffer = (buffer << 5) | index
            bitsLeft += 5
            if bitsLeft >= 8 {
                output.append(UInt8((buffer >> (bitsLeft - 8)) & 0xff))
                bitsLeft -= 8
            }
        }
        return output
    }
}

/// A standard `otpauth://totp` payload handed to the app by iOS when the user
/// chooses Vaultwarden in Passwords & Codes > Set Up Codes In.
nonisolated struct OTPAuthSetupRequest: Identifiable, Hashable, Sendable {
    let sourceURL: URL
    let name: String
    let username: String

    var id: String { sourceURL.absoluteString }

    static func parse(_ url: URL) -> OTPAuthSetupRequest? {
        guard url.scheme?.lowercased() == "otpauth",
              url.host?.lowercased() == "totp",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let parameters = (components.queryItems ?? []).reduce(into: [String: String]()) { result, item in
            result[item.name.lowercased()] = item.value ?? ""
        }
        guard parameters["secret"]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }

        let label = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .removingPercentEncoding?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let labelParts = label.split(separator: ":", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let issuer = parameters["issuer"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let account = labelParts.count == 2 ? labelParts[1] : (labelParts.first ?? "")
        let resolvedName = !issuer.isEmpty ? issuer : (labelParts.first?.isEmpty == false ? labelParts[0] : "Verification Code")

        return OTPAuthSetupRequest(
            sourceURL: url,
            name: resolvedName,
            username: account
        )
    }
}

struct LockView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    private let isPrivacyShield: Bool
    @State private var showPasswordUnlock = false
    @State private var biometricFailed = false
    @State private var isUnlocking = false
    @State private var lastAutomaticAttemptGeneration: Int?

    init(isPrivacyShield: Bool = false) {
        self.isPrivacyShield = isPrivacyShield
    }

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.vaultBlue.gradient)
            Text("Vaultwarden Is Locked")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Button {
                Task { await attemptDeviceUnlock() }
            } label: {
                HStack {
                    Label(
                        biometricFailed ? "Try \(BiometricAuthenticator.displayName) or Device Passcode" : "Unlock",
                        systemImage: biometricFailed ? "lock.open.fill" : BiometricAuthenticator.systemImage
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isUnlocking)

            if biometricFailed, !isPrivacyShield {
                Text(store.lastUnlockError
                     ?? "\(BiometricAuthenticator.displayName) was not completed. Try again using biometrics or the device passcode, or unlock with your master password.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            if !isPrivacyShield {
                Button("Use Master Password") { showPasswordUnlock = true }
                    .buttonStyle(.plain)
            }
            Spacer()
            if !isPrivacyShield {
                Text("Vault key protected by iOS Keychain")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea(.all)
        }
        .ignoresSafeArea(.all)
        .task(id: store.unlockPromptGeneration) {
            await attemptAutomaticUnlockIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await attemptAutomaticUnlockIfNeeded() }
        }
        .fullScreenCover(isPresented: $showPasswordUnlock) {
            MasterPasswordUnlockView()
                .environmentObject(store)
        }
    }

    private func attemptAutomaticUnlockIfNeeded() async {
        guard !isPrivacyShield,
              scenePhase == .active,
              store.isLocked,
              store.settings.biometricUnlock,
              store.shouldAutomaticallyPromptUnlock,
              lastAutomaticAttemptGeneration != store.unlockPromptGeneration else { return }
        lastAutomaticAttemptGeneration = store.unlockPromptGeneration
        await attemptDeviceUnlock()
    }

    private func attemptDeviceUnlock() async {
        guard !isPrivacyShield, !isUnlocking else { return }
        isUnlocking = true
        let success = await store.unlockWithBiometrics()
        biometricFailed = !success
        isUnlocking = false
    }
}

private struct MasterPasswordUnlockView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var masterPassword = ""
    @State private var isPasswordVisible = false
    @State private var isUnlocking = false
    @State private var errorMessage: String?
    @FocusState private var passwordIsFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Master password")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.vaultBlue)

                        HStack(spacing: 12) {
                            Group {
                                if isPasswordVisible {
                                    TextField("Master password", text: $masterPassword)
                                } else {
                                    SecureField("Master password", text: $masterPassword)
                                }
                            }
                            .textContentType(.password)
                            .focused($passwordIsFocused)
                            .submitLabel(.go)
                            .onSubmit { Task { await unlockWithMasterPassword() } }

                            Button {
                                isPasswordVisible.toggle()
                            } label: {
                                Image(systemName: isPasswordVisible ? "eye.slash" : "eye")
                                    .font(.title3)
                                    .foregroundStyle(Color.vaultBlue)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(isPasswordVisible ? "Hide master password" : "Show master password")
                        }
                        .padding(.vertical, 6)

                        Divider()

                        Text("Your vault is locked. Verify your master password to continue.")
                            .foregroundStyle(.secondary)

                        Text(accountDescription)
                            .foregroundStyle(.secondary)

                        if let errorMessage {
                            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                    .padding(20)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))

                    VStack(spacing: 14) {
                        Button {
                            Task { await unlockWithBiometrics() }
                        } label: {
                            Label(
                                "Use \(BiometricAuthenticator.displayName) To Unlock",
                                systemImage: BiometricAuthenticator.systemImage
                            )
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(isUnlocking)

                        Button {
                            Task { await unlockWithMasterPassword() }
                        } label: {
                            HStack {
                                if isUnlocking { ProgressView().tint(.white) }
                                Text("Unlock")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(masterPassword.isEmpty || isUnlocking)
                    }
                }
                .padding(20)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Verify Master Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            await Task.yield()
            passwordIsFocused = true
        }
        .overlay {
            if scenePhase != .active {
                LockView(isPrivacyShield: true)
                    .environmentObject(store)
            }
        }
    }

    private var accountDescription: String {
        let server = URL(string: store.settings.serverURL)?.host ?? store.settings.serverURL
        return "Logged in as \(store.settings.email) on \(server)."
    }

    private func unlockWithMasterPassword() async {
        guard !masterPassword.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        errorMessage = nil
        let success = await store.unlock(masterPassword: masterPassword)
        isUnlocking = false
        if success {
            masterPassword = ""
            dismiss()
        } else {
            errorMessage = store.lastUnlockError ?? "The master password is incorrect."
            passwordIsFocused = true
        }
    }

    private func unlockWithBiometrics() async {
        guard !isUnlocking else { return }
        passwordIsFocused = false
        isUnlocking = true
        errorMessage = nil
        let success = await store.unlockWithBiometrics()
        isUnlocking = false
        if success {
            dismiss()
        } else {
            errorMessage = store.lastUnlockError ?? "\(BiometricAuthenticator.displayName) could not unlock the vault."
        }
    }
}
