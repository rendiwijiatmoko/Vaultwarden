import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Who you're signed in as, on which server, and the way out. Pushed from the iPhone
/// root's account row; the Account pane on the Mac.
struct AccountSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var connection: ConnectionTest = .idle
    @State private var isConfirmingSignOut = false
    @State private var isSigningOut = false
    @State private var isShowingSignIn = false
    #if os(macOS)
    @State private var isShowingLoginRequests = false
    #endif

    enum ConnectionTest: Equatable {
        case idle, testing, connected, failed
    }

    private var host: String { SettingsWords.serverHost(store.settings.serverURL) }

    private var isServerSecure: Bool {
        store.settings.serverURL.isEmpty || ServerAddress.isSecure(store.settings.serverURL)
    }

    private var deviceName: String {
        #if os(macOS)
        L10n.string("Mac")
        #else
        UIDevice.current.model
        #endif
    }

    var body: some View {
        Form {
            SettingsHero(
                title: Text(verbatim: store.settings.email),
                subtitle: heroLine
            ) {
                AccountAvatar(email: store.settings.email, baseSide: SettingsHero<AccountAvatar, EmptyView>.tileSide)
            } accessory: {
                EmptyView()
            }

            Section {
                LabeledContent("Address") {
                    Text(verbatim: host)
                        .textSelection(.enabled)
                }
                if let version = store.discoveredServerVersion, version.isEmpty == false {
                    LabeledContent("Version") {
                        Text(verbatim: version)
                    }
                }
                HStack {
                    Button("Test Connection", action: testConnection)
                        .disabled(connection == .testing || store.settings.serverURL.isEmpty)
                    Spacer(minLength: SettingsSpacing.standard)
                    ConnectionTestStatus(state: connection)
                }
                .animation(SettingsMotion.flip, value: connection)
            } header: {
                Text("Server")
            } footer: {
                serverFooter
            }

            if store.organizations.isEmpty == false {
                Section("Organizations") {
                    ForEach(store.organizations, id: \.self) { name in
                        Text(verbatim: name)
                    }
                }
            }

            if store.sessionNeedsSignIn {
                Section {
                    Button("Sign In Again…") { isShowingSignIn = true }
                } footer: {
                    Text("Your session on \(host) ended. Sign in to keep syncing.")
                }
            }

            #if os(macOS)
            Section {
                SettingsDetailRow(
                    title: Text("Login Requests"),
                    detail: Text("Approve sign-ins from your other devices."),
                    systemImage: "checkmark.shield.fill",
                    tint: .blue
                ) {
                    Button("Review…") { isShowingLoginRequests = true }
                }
            }
            #endif

            Section {
                #if os(macOS)
                SettingsDetailRow(
                    title: Text("Sign Out"),
                    detail: Text("Removes your vault and AutoFill data from this Mac. Your vault on \(host) isn’t affected.")
                ) {
                    signOutButton
                }
                #else
                signOutButton
                #endif
            } footer: {
                #if os(iOS)
                Text("Removes your vault and AutoFill data from this \(deviceName). Your vault on \(host) isn’t affected.")
                #endif
            }
        }
        #if os(macOS)
        .settingsPane()
        .sheet(isPresented: $isShowingLoginRequests) {
            NavigationStack {
                PendingLoginRequestsView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { isShowingLoginRequests = false }
                        }
                    }
            }
            .environmentObject(store)
            .frame(minWidth: 520, minHeight: 480)
        }
        #else
        .settingsPage(Text("Account"))
        #endif
        .sheet(isPresented: $isShowingSignIn) {
            AccountSignInView(onSuccess: { isShowingSignIn = false })
                .environmentObject(store)
        }
        .task(id: connection) {
            // A result reads for a moment, then the row offers the test again.
            guard connection == .connected || connection == .failed else { return }
            try? await Task.sleep(for: .seconds(connection == .failed ? 8 : 4))
            guard Task.isCancelled == false else { return }
            withAnimation(SettingsMotion.flip) { connection = .idle }
        }
    }

    private var heroLine: Text {
        if store.sessionNeedsSignIn {
            return StatusTone.attention.apply(to: Text("Sign in again to keep syncing"))
        }
        return Text(verbatim: host)
    }

    @ViewBuilder
    private var serverFooter: some View {
        if connection == .failed {
            StatusTone.failure.apply(to: Text("Couldn’t reach \(host). Check your internet connection and try again."))
        } else if isServerSecure == false {
            StatusTone.attention.apply(to: Text("This address doesn’t use HTTPS, so Vaultwarden can’t connect to it. Sign out, then sign in with an https:// address."))
        } else {
            Text("To use a different server, sign out, then sign in with its address.")
        }
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            isConfirmingSignOut = true
        } label: {
            if isSigningOut {
                HStack(spacing: SettingsSpacing.standard) {
                    ProgressView().controlSize(.small)
                    Text("Signing Out…")
                }
            } else {
                Text("Sign Out…")
            }
        }
        .disabled(store.isAuthenticated == false || isSigningOut)
        .confirmationDialog(
            SettingsWords.signOutTitle(pendingChanges: store.pendingMutationCount),
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible
        ) {
            Button("Sign Out", role: .destructive, action: signOut)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(verbatim: SettingsWords.signOutMessage(
                host: host,
                pendingChanges: store.pendingMutationCount,
                device: deviceName
            ))
        }
    }

    private func testConnection() {
        connection = .testing
        let address = store.settings.serverURL
        Task {
            do {
                _ = try await store.testConnection(serverURL: address)
                connection = .connected
            } catch {
                SecureLog.failure("Server connection test", error: error, logger: SecureLog.sync)
                connection = .failed
            }
        }
    }

    private func signOut() {
        isSigningOut = true
        Task {
            await store.logoutAndDeleteLocalData()
            isSigningOut = false
        }
    }
}

/// The trailing status of Test Connection, sized so the row never jumps.
private struct ConnectionTestStatus: View {
    var state: AccountSettingsView.ConnectionTest

    var body: some View {
        switch state {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: SettingsSpacing.standard) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .foregroundStyle(.secondary)
            }
            .font(.callout)
        case .connected:
            SettingsStatusBadge(text: Text("Connected"), systemImage: "checkmark.circle.fill", tone: .plain)
                .transition(.opacity)
        case .failed:
            SettingsStatusBadge(text: Text("Couldn’t Connect"), systemImage: "exclamationmark.triangle.fill", tone: .failure)
                .transition(.opacity)
        }
    }
}
