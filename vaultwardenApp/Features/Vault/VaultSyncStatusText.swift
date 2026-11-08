import SwiftUI

/// One quiet line about sync. It takes a color only when something needs attention.
struct VaultSyncStatusText: View {
    @EnvironmentObject private var store: AppStore

    var body: some View {
        // Relative times ("5 min. ago") are refreshed once a minute, not every render.
        TimelineView(.everyMinute) { _ in
            let appearance = appearance
            Text(appearance.text)
                .font(.footnote)
                .lineLimit(1)
                .foregroundStyle(appearance.color)
                .contentTransition(.opacity)
        }
        .animation(VaultMotion.fade, value: store.isSyncing)
        .accessibilityElement(children: .combine)
    }

    private var appearance: (text: String, color: Color) {
        if store.isSyncing {
            return (L10n.string("Syncing…"), .secondary)
        }
        if store.pendingMutationCount > 0 {
            return (SettingsWords.queueSummary(store.pendingMutationCount), .orange)
        }
        if store.lastSyncError != nil {
            return (L10n.string("Sync Failed · Pull to Try Again"), .red)
        }
        if store.lastSyncUsedOfflineCache {
            return (L10n.string("Offline · Pull to Try Again"), .orange)
        }
        let date = store.lastSuccessfulSync ?? store.lastSync
        return (L10n.format("Synced %@", date.formatted(.relative(presentation: .named))), .secondary)
    }
}
