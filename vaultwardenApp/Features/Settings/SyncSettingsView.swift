import SwiftUI

/// Where the vault stands with the server, what's waiting to upload, and when it syncs.
struct SyncSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var isShowingSignIn = false
    /// Counts syncs this page started and finished, so the haptic answers the person's tap.
    @State private var finishedSyncs = 0

    private var state: SettingsWords.SyncState {
        SettingsWords.syncState(
            isSyncing: store.isSyncing,
            needsSignIn: store.sessionNeedsSignIn,
            error: store.lastSyncError,
            pendingChanges: store.pendingMutationCount
        )
    }

    private var heroLine: Text {
        SettingsWords.syncTone(state).apply(to: Text(verbatim: SettingsWords.syncHeadline(
            state,
            lastSynced: store.lastSuccessfulSync ?? store.lastSync,
            usesOfflineCopy: store.lastSyncUsedOfflineCache
        )))
    }

    var body: some View {
        Form {
            SettingsHero(
                Text("Sync"),
                subtitle: heroLine,
                systemImage: "arrow.triangle.2.circlepath",
                tint: .cyan
            ) {
                #if os(macOS)
                syncButton
                #endif
            }

            #if os(iOS)
            Section {
                syncButton
            } footer: {
                problemFooter
            }
            #else
            if store.lastSyncError != nil || store.sessionNeedsSignIn {
                Section {
                } footer: {
                    problemFooter
                }
            }
            #endif

            if store.sessionNeedsSignIn {
                Section {
                    Button("Sign In Again…") { isShowingSignIn = true }
                }
            }

            Section {
                LabeledContent("Waiting to Upload") {
                    Text(verbatim: store.pendingMutationCount > 0
                         ? SettingsWords.inflected("^[\(store.pendingMutationCount) Change](inflect: true)")
                         : L10n.string("None"))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(store.pendingMutationCount)))
                }
            } header: {
                Text("Changes")
            } footer: {
                #if os(macOS)
                Text("Changes you make offline are encrypted on this Mac and upload on their own once the server can be reached.")
                #else
                Text("Changes you make offline are encrypted on this device and upload on their own once the server can be reached.")
                #endif
            }

            Section {
                Toggle("Sync When Unlocked", isOn: $store.settings.syncOnOpen)
                Toggle("Background Refresh", isOn: $store.settings.backgroundRefresh)
            } header: {
                Text("Automatic Sync")
            } footer: {
                Text(verbatim: automaticFooter)
                    .contentTransition(.opacity)
            }
        }
        .animation(SettingsMotion.flip, value: state)
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage(Text("Sync"))
        .refreshable { await store.syncFromPullToRefresh() }
        .sensoryFeedback(.success, trigger: finishedSyncs) { _, _ in store.settings.haptics }
        #endif
        .sheet(isPresented: $isShowingSignIn) {
            AccountSignInView(onSuccess: { isShowingSignIn = false })
                .environmentObject(store)
        }
    }

    private var syncButton: some View {
        Button {
            Task { await syncNow() }
        } label: {
            if store.isSyncing {
                HStack(spacing: SettingsSpacing.standard) {
                    ProgressView().controlSize(.small)
                    Text("Syncing…")
                }
            } else {
                Text("Sync Now")
            }
        }
        .disabled(store.isSyncing || store.isLocked || store.isAuthenticated == false)
    }

    private func syncNow() async {
        await store.sync()
        if store.lastSyncError == nil { finishedSyncs += 1 }
    }

    @ViewBuilder
    private var problemFooter: some View {
        if store.sessionNeedsSignIn {
            Text("Your session ended. Sign in again to upload changes and get new ones.")
        } else if store.lastSyncError?.isEmpty == false {
            Text("Vaultwarden couldn’t reach your server. Changes stay on this device until the next sync.")
        }
    }

    private var automaticFooter: String {
        var sentences: [String] = []
        sentences.append(store.settings.syncOnOpen
            ? L10n.string("Vaultwarden gets the latest from your server each time you unlock it.")
            : L10n.string("Vaultwarden opens with what’s on this device, and syncs when you choose Sync Now."))
        #if os(macOS)
        sentences.append(store.settings.backgroundRefresh
            ? L10n.string("While it’s running, it also checks for changes in the background. It stops when you quit.")
            : L10n.string("It doesn’t check for changes in the background."))
        #else
        sentences.append(store.settings.backgroundRefresh
            ? L10n.string("In the background, it uploads waiting changes and refreshes its encrypted copy, without unlocking your vault.")
            : L10n.string("It doesn’t refresh in the background."))
        #endif
        return sentences.joined(separator: " ")
    }
}
