import SwiftUI

enum AppVersion {
    /// "1.2 (34)", as Settings ▸ General ▸ About shows a version.
    static var display: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        switch (version, build) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        case let (nil, build?): return build
        case (nil, nil): return ""
        }
    }
}

/// The app's version, what it does with your data, what it's built on, and what it can
/// report about its own state.
struct AboutSettingsView: View {
    private static let projectURL = URL(string: "https://github.com/dani-garcia/vaultwarden")

    var body: some View {
        Form {
            SettingsHero(
                Text(verbatim: "Vaultwarden"),
                subtitle: Text("Version \(AppVersion.display)"),
                systemImage: "lock.shield.fill",
                tint: .blue
            )

            #if os(macOS)
            PrivacySections()
            DiagnosticsSections()
            AcknowledgmentsSections()
            #else
            Section {
                NavigationLink { PrivacySettingsView() } label: { Text("Privacy") }
                NavigationLink { DiagnosticsSettingsView() } label: { Text("Diagnostics") }
                NavigationLink { AcknowledgmentsSettingsView() } label: { Text("Acknowledgments") }
            }
            #endif

            Section {
                if let projectURL = Self.projectURL {
                    SettingsLinkRow(title: Text("Vaultwarden Project"), destination: projectURL)
                }
            } footer: {
                Text("This app is independent, and isn’t made by Bitwarden, Inc. or the Vaultwarden project.")
            }
        }
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage(Text("About"))
        #endif
    }
}

/// What leaves the device and what stays. Shared by the iPhone page and the Mac pane.
struct PrivacySections: View {
    var body: some View {
        Section {
            Text("Your vault goes only to the server you chose. Vaultwarden has no analytics, ads or tracking.")
            Text("The offline copy, changes waiting to upload and AutoFill’s list are encrypted on this device. Their keys stay in the keychain and are never exported.")
            Text("Exporting asks you to verify it’s you, and every archive is locked with its own password.")
        } header: {
            Text("Privacy")
        }
    }
}

/// A few facts that help with problems, and nothing that identifies you or your items.
struct DiagnosticsSections: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        Section {
            LabeledContent("Session") {
                Text(store.isAuthenticated ? "Signed In" : "Not Signed In")
            }
            LabeledContent("Vault") {
                Text(store.isLocked ? "Locked" : "Unlocked")
            }
            LabeledContent("Waiting to Upload") {
                Text(store.pendingMutationCount, format: .number)
                    .monospacedDigit()
            }
            LabeledContent("Offline Copy") {
                Text(store.lastSyncUsedOfflineCache ? "In Use" : "Not in Use")
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Diagnostics never include your server, email, item names, usernames, tokens, keys or error details.")
        }
    }
}

/// The open source this app is built on.
struct AcknowledgmentsSections: View {
    private static let sdkURL = URL(string: "https://github.com/bitwarden/sdk-swift")

    var body: some View {
        Section {
            LabeledContent("Bitwarden SDK for Swift") {
                Text(verbatim: "3dbc27249f48")
                    .monospaced()
                    .textSelection(.enabled)
            }
            if let sdkURL = Self.sdkURL {
                SettingsLinkRow(title: Text("Source Code"), destination: sdkURL)
            }
        } header: {
            Text("Acknowledgments")
        } footer: {
            Text("The Vaultwarden server isn’t included in this app. It talks only to the server you choose.")
        }
    }
}

#if os(iOS)
struct PrivacySettingsView: View {
    var body: some View {
        Form { PrivacySections() }
            .navigationTitle("Privacy")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticsSettingsView: View {
    var body: some View {
        Form { DiagnosticsSections() }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct AcknowledgmentsSettingsView: View {
    var body: some View {
        Form { AcknowledgmentsSections() }
            .navigationTitle("Acknowledgments")
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
