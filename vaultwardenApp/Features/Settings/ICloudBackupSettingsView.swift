import SwiftUI

/// iCloud Backup: where the backup stands, when it runs, and the backups to go back to.
/// Pushed inside Settings on iPhone; a Settings tab's content on the Mac.
struct ICloudBackupSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var backup: ICloudBackupManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pendingRestore: ICloudBackupSummary?
    @State private var isConfirmingRestore = false
    @State private var pendingDeletion: [ICloudBackupSummary] = []
    @State private var isConfirmingDeletion = false
    @State private var restoreResult: ICloudBackupRestoreResult?
    @State private var failure: BackupFailure?
    @State private var isShowingFailure = false
    /// Counts finished actions this person started here, for the success haptic.
    @State private var completedActions = 0

    init() {
        _backup = ObservedObject(wrappedValue: ICloudBackupManager.shared)
    }

    fileprivate init(manager: ICloudBackupManager) {
        _backup = ObservedObject(wrappedValue: manager)
    }

    var body: some View {
        Form {
            SettingsHero(
                Text("iCloud Backup"),
                subtitle: backup.status.tone.apply(to: Text(backup.statusLine)),
                systemImage: "arrow.clockwise.icloud.fill",
                tint: .blue
            ) {
                #if os(macOS)
                backUpNowButton
                #endif
            }

            scheduleSection

            #if os(iOS)
            Section {
                backUpNowButton
            } footer: {
                Text(ICloudBackupWords.privacyFooter)
            }
            #endif

            if let progress = backup.restoreProgress {
                restoringSection(progress)
            } else if let restoreResult {
                restoredSection(restoreResult)
            }

            if backup.isICloudAvailable != false {
                backupsSection
                if !backup.backups.isEmpty {
                    Section {
                        Button("Delete All Backups…", role: .destructive) {
                            requestDeletion(of: backup.backups)
                        }
                        .disabled(isWorking)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .animation(rowMotion, value: backup.isEnabled)
        .animation(rowMotion, value: backup.backups)
        .animation(rowMotion, value: backup.isICloudAvailable)
        #if os(iOS)
        .settingsPage(Text("iCloud Backup"))
        .refreshable { await backup.refresh() }
        // Leaving mid-restore would look like it stopped, and it wouldn't.
        .navigationBarBackButtonHidden(backup.activity == .restoring)
        #endif
        .task { await backup.refresh() }
        .onChange(of: backup.isEnabled) { _, isOn in
            // Turning it on backs up at once, rather than waiting for the next sync.
            if isOn { backUpNow() }
        }
        .sensoryFeedback(trigger: completedActions) { _, _ in
            store.settings.haptics ? .success : nil
        }
        .confirmationDialog(
            restoreTitle,
            isPresented: $isConfirmingRestore,
            titleVisibility: .visible,
            presenting: pendingRestore
        ) { summary in
            Button {
                restore(summary)
            } label: {
                Text("Restore ^[\(summary.itemCount ?? 0) Item](inflect: true)")
            }
            Button("Cancel", role: .cancel) {}
        } message: { summary in
            Text("They’re added to your vault next to the items already there. This backup is from \(ICloudBackupWords.moment(summary.createdAt)).")
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: $isConfirmingDeletion,
            titleVisibility: .visible
        ) {
            Button(role: .destructive) {
                delete(pendingDeletion)
            } label: {
                Text("Delete ^[\(pendingDeletion.count) Backup](inflect: true)")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They’re deleted from iCloud on all your devices. Your vault isn’t changed.")
        }
        .alert(failure?.title ?? "", isPresented: $isShowingFailure, presenting: failure) { _ in
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }

    // MARK: - Sections

    private var scheduleSection: some View {
        Section {
            Toggle("Back Up Automatically", isOn: $backup.isEnabled)
                #if os(macOS)
                .toggleStyle(.switch)
                #endif
            if backup.isEnabled {
                Picker("Back Up", selection: $backup.frequency) {
                    ForEach(ICloudBackupFrequency.allCases) { frequency in
                        Text(frequency.title).tag(frequency)
                    }
                }
            }
        } footer: {
            Text(ICloudBackupWords.scheduleFooter(
                isEnabled: backup.isEnabled,
                frequency: backup.frequency,
                isICloudAvailable: backup.isICloudAvailable
            ))
            .contentTransition(.opacity)
        }
        .disabled(backup.isICloudAvailable == false || backup.activity == .restoring)
    }

    private var backupsSection: some View {
        Section {
            if !backup.hasLoadedBackups {
                HStack {
                    Spacer()
                    ProgressView()
                        .accessibilityLabel("Checking iCloud…")
                    Spacer()
                }
            } else if backup.backups.isEmpty {
                Text("No Backups Yet")
                    .foregroundStyle(.secondary)
            } else {
                let now = Date()
                ForEach(backup.backups) { summary in
                    BackupRow(
                        title: ICloudBackupWords.rowTitle(summary.createdAt, now: now, calendar: .current, locale: .current),
                        time: ICloudBackupWords.time(summary.createdAt, calendar: .current, locale: .current),
                        itemCount: summary.itemCount,
                        isEnabled: !isWorking,
                        onRestore: { requestRestore(summary) },
                        onDelete: { requestDeletion(of: [summary]) }
                    )
                }
            }
        } header: {
            Text("Backups")
        } footer: {
            backupsFooter
        }
    }

    @ViewBuilder
    private var backupsFooter: some View {
        let needsKey = backup.backups.contains(where: \.needsKey)
        #if os(macOS)
        VStack(alignment: .leading, spacing: 4) {
            if needsKey { Text(ICloudBackupWords.missingKeyFooter) }
            Text(ICloudBackupWords.privacyFooter)
        }
        #else
        if needsKey { Text(ICloudBackupWords.missingKeyFooter) }
        #endif
    }

    private func restoringSection(_ progress: ICloudBackupRestoreProgress) -> some View {
        Section {
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
                Text("Restoring \(progress.completed) of \(progress.total)…")
                    .monospacedDigit()
            }
        }
    }

    private func restoredSection(_ result: ICloudBackupRestoreResult) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Restored ^[\(result.restoredItems) item](inflect: true)")
                    if result.failedItems > 0 {
                        Text("^[\(result.failedItems) item](inflect: true) couldn’t be restored. Try again once your vault syncs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: result.failedItems > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(result.failedItems > 0 ? Color.orange : Color.green)
                    .accessibilityHidden(true)
            }
        }
    }

    // MARK: - Back Up Now

    private var backUpNowButton: some View {
        Button {
            backUpNow()
        } label: {
            #if os(macOS)
            // Both states hold the same space, so the hero row never reflows.
            ZStack {
                Text("Back Up Now").opacity(isBackingUp ? 0 : 1)
                if isBackingUp {
                    ProgressView().controlSize(.small)
                }
            }
            #else
            HStack {
                isBackingUp ? Text("Backing Up…") : Text("Back Up Now")
                Spacer()
                if isBackingUp { ProgressView() }
            }
            #endif
        }
        .disabled(!canBackUp)
        .accessibilityLabel(isBackingUp ? Text("Backing Up…") : Text("Back Up Now"))
    }

    // MARK: - State

    private var isBackingUp: Bool { backup.activity == .backingUp }
    private var isWorking: Bool { backup.activity != .idle }
    private var canUseVault: Bool { store.isAuthenticated && !store.isLocked }
    private var canBackUp: Bool { backup.canBackUp && canUseVault }

    private var rowMotion: Animation {
        SettingsMotion.row(reduceMotion: reduceMotion)
    }

    // Dialog titles show inflection markup literally, so resolve it first.
    private var restoreTitle: Text {
        let count = pendingRestore?.itemCount ?? 0
        return Text(verbatim: String(AttributedString(localized: "Restore ^[\(count) Item](inflect: true)?").characters))
    }

    private var deletionTitle: Text {
        let count = pendingDeletion.count
        return Text(verbatim: String(AttributedString(localized: "Delete ^[\(count) Backup](inflect: true)?").characters))
    }

    // MARK: - Actions

    private func backUpNow() {
        guard canBackUp else { return }
        Task {
            if await backup.backUpNow(from: store) {
                completedActions += 1
            }
        }
    }

    private func requestRestore(_ summary: ICloudBackupSummary) {
        guard canUseVault, !isWorking else { return }
        guard summary.needsKey else {
            pendingRestore = summary
            isConfirmingRestore = true
            return
        }
        // The key may have arrived through iCloud Keychain since the list loaded.
        Task {
            await backup.refresh()
            if let refreshed = backup.backups.first(where: { $0.id == summary.id }), !refreshed.needsKey {
                pendingRestore = refreshed
                isConfirmingRestore = true
            } else {
                show(BackupFailure(
                    title: L10n.string("Key Not on This Device"),
                    message: ICloudBackupError.keyUnavailable.errorDescription ?? ""
                ))
            }
        }
    }

    private func restore(_ summary: ICloudBackupSummary) {
        restoreResult = nil
        Task {
            do {
                restoreResult = try await backup.restore(summary, into: store)
                completedActions += 1
            } catch is CancellationError {
                // Locked or signed out mid-restore; the lock screen says enough.
            } catch {
                show(BackupFailure(title: L10n.string("Nothing Was Restored"), message: error.localizedDescription))
            }
        }
    }

    private func requestDeletion(of summaries: [ICloudBackupSummary]) {
        guard !summaries.isEmpty, !isWorking else { return }
        pendingDeletion = summaries
        isConfirmingDeletion = true
    }

    private func delete(_ summaries: [ICloudBackupSummary]) {
        Task {
            do {
                try await backup.delete(summaries)
            } catch {
                show(BackupFailure(
                    title: L10n.string("Couldn’t Delete Backups"),
                    message: L10n.string("Check your connection to iCloud, then try again.")
                ))
            }
        }
    }

    private func show(_ newFailure: BackupFailure) {
        failure = newFailure
        isShowingFailure = true
    }
}

private struct BackupFailure {
    let title: String
    let message: String
}

// MARK: - Rows

/// Plain values only: a Mac list row that observes the store driving the list redraws
/// inside the list's own update.
private struct BackupRow: View {
    let title: String
    let time: String
    let itemCount: Int?
    let isEnabled: Bool
    let onRestore: () -> Void
    let onDelete: () -> Void

    var body: some View {
        #if os(macOS)
        HStack(spacing: 12) {
            labels
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Restore…", action: onRestore)
                .disabled(!isEnabled)
        }
        .contextMenu { menuItems }
        #else
        Button(action: onRestore) {
            labels
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
        }
        .disabled(!isEnabled)
        .swipeActions {
            // Not role: .destructive, which removes the row before the confirmation answers.
            Button("Delete", systemImage: "trash", action: onDelete)
                .tint(.red)
        }
        .contextMenu { menuItems }
        #endif
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(Color.primary)
            facts
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var facts: Text {
        if let itemCount {
            return Text("\(time) · ^[\(itemCount) item](inflect: true)")
        }
        return Text("\(time) · Needs Key")
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Restore…", systemImage: "arrow.uturn.backward", action: onRestore)
            .disabled(!isEnabled)
        Button("Delete…", systemImage: "trash", role: .destructive, action: onDelete)
            .disabled(!isEnabled)
    }
}

// MARK: - Previews

#if DEBUG
private nonisolated struct PreviewBackupContainer: ICloudBackupContainerProviding {
    let directory: URL?
    func backupsDirectory() -> URL? { directory }
}

@MainActor
private func previewManager(directory: URL?) -> ICloudBackupManager {
    let defaults = UserDefaults(suiteName: "ICloudBackupSettingsPreview") ?? UserDefaults()
    defaults.removePersistentDomain(forName: "ICloudBackupSettingsPreview")
    return ICloudBackupManager(defaults: defaults, container: PreviewBackupContainer(directory: directory))
}

@MainActor
private func previewStore() -> AppStore {
    AppStore(settingsDefaults: UserDefaults(suiteName: "ICloudBackupSettingsPreviewStore") ?? UserDefaults())
}

#Preview("iCloud Backup, Off") {
    NavigationStack {
        ICloudBackupSettingsView(manager: previewManager(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent("ICloudBackupPreview", isDirectory: true)
        ))
    }
    .environmentObject(previewStore())
}

#Preview("iCloud Backup, iCloud Off") {
    NavigationStack {
        ICloudBackupSettingsView(manager: previewManager(directory: nil))
    }
    .environmentObject(previewStore())
}
#endif
