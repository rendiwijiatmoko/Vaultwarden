import CryptoKit
import Foundation
import LocalAuthentication
import SwiftUI

enum BiometricAuthenticator {
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

struct LockView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var masterPassword = ""
    @State private var showPasswordUnlock = false
    @State private var biometricFailed = false
    @State private var isUnlocking = false
    @State private var lastAutomaticAttemptGeneration: Int?

    var body: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.vaultBlue.gradient)
            VStack(spacing: 8) {
                Text("Vault Locked")
                    .font(.largeTitle.bold())
                Text("Authenticate to access your encrypted vault.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                Task { await attemptDeviceUnlock() }
            } label: {
                HStack {
                    if isUnlocking { ProgressView().tint(.white) }
                    Label(
                        biometricFailed ? "Try Face ID or Device Passcode" : "Unlock with Face ID",
                        systemImage: biometricFailed ? "lock.open.fill" : "faceid"
                    )
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isUnlocking)

            if biometricFailed {
                Text(store.lastUnlockError
                     ?? "Face ID was not completed. Try again to use Face ID or the iPhone passcode, or unlock with your master password.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Button("Use Master Password") { showPasswordUnlock.toggle() }
                .buttonStyle(.bordered)

            if showPasswordUnlock {
                SecureField("Master password", text: $masterPassword)
                    .textContentType(.password)
                    .padding(14)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                Button("Unlock") {
                    guard !masterPassword.isEmpty else { return }
                    Task {
                        isUnlocking = true
                        let success = await store.unlock(masterPassword: masterPassword)
                        if success { masterPassword = "" }
                        biometricFailed = !success
                        isUnlocking = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isUnlocking || masterPassword.isEmpty)
            }
            Spacer()
            Text("Vault key protected by iOS Keychain")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .task(id: store.unlockPromptGeneration) {
            await attemptAutomaticUnlockIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await attemptAutomaticUnlockIfNeeded() }
        }
    }

    private func attemptAutomaticUnlockIfNeeded() async {
        guard scenePhase == .active,
              store.isLocked,
              store.settings.biometricUnlock,
              store.shouldAutomaticallyPromptUnlock,
              lastAutomaticAttemptGeneration != store.unlockPromptGeneration else { return }
        lastAutomaticAttemptGeneration = store.unlockPromptGeneration
        await attemptDeviceUnlock()
    }

    private func attemptDeviceUnlock() async {
        guard !isUnlocking else { return }
        isUnlocking = true
        let success = await store.unlockWithBiometrics()
        biometricFailed = !success
        isUnlocking = false
    }
}
