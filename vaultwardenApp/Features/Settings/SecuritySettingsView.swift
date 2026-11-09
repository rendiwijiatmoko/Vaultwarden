import SwiftUI

/// How the vault unlocks, when it locks itself, and what asks again before a secret leaves it.
struct SecuritySettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var biometry = BiometryKind.current

    private var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var sensorName: String {
        biometry.name ?? L10n.string("Biometrics")
    }

    var body: some View {
        Form {
            SettingsHero(
                Text("Security"),
                subtitle: Text(verbatim: SettingsWords.unlockHeadline(
                    biometry: biometry,
                    biometricUnlock: store.settings.biometricUnlock
                )),
                systemImage: store.settings.biometricUnlock ? biometry.systemImage : "lock.fill",
                tint: .red
            )

            Section {
                Toggle(isOn: biometricUnlock) {
                    Text("Unlock with \(sensorName)")
                }
                if store.settings.biometricUnlock {
                    Toggle(isOn: $store.settings.devicePasscodeFallback) {
                        #if os(macOS)
                        Text("Allow Mac Login Password")
                        #else
                        Text("Allow Device Passcode")
                        #endif
                    }
                }
            } header: {
                Text("Unlock")
            } footer: {
                Text(verbatim: SettingsWords.unlockFooter(
                    biometry: biometry,
                    biometricUnlock: store.settings.biometricUnlock,
                    passcodeFallback: store.settings.devicePasscodeFallback,
                    isMac: isMac
                ))
                .contentTransition(.opacity)
            }

            Section {
                Picker("Lock Vault", selection: $store.settings.vaultTimeout) {
                    ForEach(VaultTimeout.allCases) { timeout in
                        Text(verbatim: SettingsWords.timeoutTitle(timeout)).tag(timeout)
                    }
                }
            } header: {
                Text("Auto-Lock")
            } footer: {
                Text(verbatim: SettingsWords.autoLockFooter(store.settings.vaultTimeout, isMac: isMac))
                    .contentTransition(.opacity)
            }

            Section {
                Toggle(isOn: $store.settings.requireBiometricForSensitiveActions) {
                    Text("Verify to Reveal or Copy")
                }
                Toggle(isOn: $store.settings.clearClipboard) {
                    Text("Clear Clipboard")
                }
            } header: {
                Text("Passwords and Codes")
            } footer: {
                Text(verbatim: sensitiveFooter)
                    .contentTransition(.opacity)
            }
        }
        .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: store.settings.biometricUnlock)
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage(Text("Security"))
        #endif
    }

    /// Turning biometrics off also turns its fallback off, so the pair never disagrees.
    private var biometricUnlock: Binding<Bool> {
        Binding(
            get: { store.settings.biometricUnlock },
            set: { isOn in
                var settings = store.settings
                settings.biometricUnlock = isOn
                if isOn == false { settings.devicePasscodeFallback = false }
                store.settings = settings
            }
        )
    }

    private var sensitiveFooter: String {
        let verify = store.settings.requireBiometricForSensitiveActions
            ? L10n.string("Vaultwarden asks you to verify it’s you before a password is shown or copied.")
            : L10n.string("Passwords are shown and copied without asking again while the vault is unlocked.")
        let clipboard = store.settings.clearClipboard
            ? L10n.string("Copied items are cleared from the clipboard after 30 seconds.")
            : L10n.string("Copied items stay on the clipboard until you copy something else.")
        return "\(verify) \(clipboard)"
    }
}
