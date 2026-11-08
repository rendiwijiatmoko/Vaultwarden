import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// Moving the vault in and out as encrypted archives, and the offline copy on this device.
struct DataSettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var transferMode: VaultTransferMode?
    @State private var pendingImportData: Data?
    @State private var exportedArchive: URL?
    @State private var status: String?
    @State private var isImportingFile = false
    @State private var isConfirmingClearCache = false
    @State private var cacheCleared = false

    var body: some View {
        Form {
            SettingsHero(
                Text("Import & Export"),
                subtitle: Text("Move your vault in and out with encrypted archives."),
                systemImage: "externaldrive.fill",
                tint: .orange
            )

            Section {
                #if os(macOS)
                SettingsDetailRow(
                    title: Text("Export Vault"),
                    detail: Text("Save your items as an archive locked with a password you choose.")
                ) {
                    Button("Export…") { transferMode = .export }
                }
                if let exportedArchive {
                    SettingsDetailRow(
                        title: Text("Last Export"),
                        detail: Text(verbatim: exportedArchive.lastPathComponent)
                    ) {
                        Button("Save…") { saveArchive(exportedArchive) }
                    }
                }
                SettingsDetailRow(
                    title: Text("Import Vault"),
                    detail: Text("Add the items from an encrypted archive to this vault.")
                ) {
                    Button("Import…") { isImportingFile = true }
                }
                #else
                Button("Export Vault…") { transferMode = .export }
                if let exportedArchive {
                    ShareLink(item: exportedArchive) {
                        Text("Save or Share Export…")
                    }
                }
                Button("Import Vault…") { isImportingFile = true }
                #endif
            } header: {
                Text("Encrypted Archive")
            } footer: {
                if let status {
                    Text(verbatim: status)
                } else {
                    Text("Archives are encrypted with AES-256 and a password only you know. Organization items and passkeys aren’t included.")
                }
            }

            Section {
                #if os(macOS)
                SettingsDetailRow(
                    title: Text("Offline Copy"),
                    detail: Text("The encrypted copy of your vault on this Mac. It downloads again on the next sync.")
                ) {
                    clearCacheButton
                }
                #else
                clearCacheButton
                #endif
            } header: {
                Text("This Device")
            } footer: {
                #if os(iOS)
                Text("Clearing removes the encrypted copy of your vault on this device. It downloads again on the next sync, and changes waiting to upload are kept.")
                #endif
            }
        }
        #if os(macOS)
        .settingsPane()
        #else
        .settingsPage(Text("Import & Export"))
        #endif
        .fileImporter(isPresented: $isImportingFile, allowedContentTypes: [.data]) { result in
            readArchive(result)
        }
        .sheet(item: $transferMode) { mode in
            VaultTransferPasswordSheet(mode: mode) { password in
                await performTransfer(mode: mode, password: password)
            }
        }
    }

    private var clearCacheButton: some View {
        Button(role: .destructive) {
            isConfirmingClearCache = true
        } label: {
            Text(cacheCleared ? "Cleared" : "Clear Offline Copy…")
        }
        .disabled(cacheCleared)
        .confirmationDialog(
            L10n.string("Clear Offline Copy?"),
            isPresented: $isConfirmingClearCache,
            titleVisibility: .visible
        ) {
            Button("Clear Offline Copy", role: .destructive) {
                Task { await clearCache() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The encrypted copy of your vault is removed from this device and downloads again on the next sync. Changes waiting to upload are kept, and nothing on your server is deleted.")
        }
    }

    private func readArchive(_ result: Result<URL, any Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            pendingImportData = try Data(contentsOf: url)
            transferMode = .importArchive
        } catch {
            status = L10n.string("That file couldn’t be read. Choose a Vaultwarden archive and try again.")
            SecureLog.failure("Archive file read", error: error, logger: SecureLog.crypto)
        }
    }

    private func clearCache() async {
        guard await BiometricAuthenticator.authenticate(
            reason: L10n.string("Clear the offline copy of your vault"),
            allowPasscode: true
        ) else { return }
        do {
            try await store.clearEncryptedLocalCache()
            cacheCleared = true
        } catch {
            status = L10n.string("The offline copy couldn’t be cleared. Try again.")
            SecureLog.failure("Offline cache clear", error: error, logger: SecureLog.crypto)
        }
    }

    /// Returns a message for the sheet to show when the transfer didn't happen.
    private func performTransfer(mode: VaultTransferMode, password: String) async -> String? {
        guard await BiometricAuthenticator.authenticate(
            reason: L10n.string(mode == .export ? "Export your encrypted vault" : "Import items into your vault"),
            allowPasscode: true
        ) else {
            return L10n.string("Verification didn’t succeed, so nothing was changed.")
        }
        do {
            switch mode {
            case .export:
                exportedArchive = try await store.exportEncryptedVault(password: password)
                #if os(macOS)
                status = L10n.string("Your archive is ready. Choose Save… to keep it somewhere safe.")
                #else
                status = L10n.string("Your archive is ready. Save it somewhere safe.")
                #endif
            case .importArchive:
                guard let pendingImportData else { throw VaultArchiveError.invalidArchive }
                let summary = try await store.importEncryptedVault(data: pendingImportData, password: password)
                self.pendingImportData = nil
                status = SettingsWords.importSummary(
                    items: summary.importedItems,
                    folders: summary.importedFolders,
                    failed: summary.failedItems
                )
            }
            transferMode = nil
            return nil
        } catch {
            SecureLog.failure("Encrypted archive transfer", error: error, logger: SecureLog.crypto)
            return mode == .export
                ? L10n.string("The archive couldn’t be created. Try again.")
                : L10n.string("The archive couldn’t be opened. Check the password and try again.")
        }
    }

    #if os(macOS)
    private func saveArchive(_ archive: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = archive.lastPathComponent
        panel.canCreateDirectories = true
        panel.title = L10n.string("Save Encrypted Archive")
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            do {
                // NSSavePanel grants access to the selected destination. Atomic
                // writing honors an existing file's replacement confirmation.
                try Data(contentsOf: archive).write(to: destination, options: .atomic)
                status = L10n.string("Archive saved.")
            } catch {
                status = L10n.string("The archive couldn’t be saved there. Choose another place.")
                SecureLog.failure("Archive file save", error: error, logger: SecureLog.crypto)
            }
        }
    }
    #endif
}

enum VaultTransferMode: String, Identifiable {
    case importArchive
    case export

    var id: String { rawValue }
    var title: String { L10n.string(self == .export ? "Export Vault" : "Import Vault") }
}

/// Asks for the archive's password. Stays open with the reason when the transfer fails.
struct VaultTransferPasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: VaultTransferMode
    /// Returns nil on success, or what went wrong.
    let action: (String) async -> String?
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case password, confirmation }

    private var canSubmit: Bool {
        isWorking == false && password.count >= 12 && (mode == .importArchive || password == confirmation)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("Password", text: $password)
                        .vaultTextContentType(mode == .export ? VaultTextContentType.newPassword : VaultTextContentType.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(mode == .export ? .next : .go)
                        .onSubmit {
                            if mode == .export { focusedField = .confirmation } else { submit() }
                        }
                    if mode == .export {
                        SecureField("Confirm Password", text: $confirmation)
                            .vaultTextContentType(.newPassword)
                            .focused($focusedField, equals: .confirmation)
                            .submitLabel(.go)
                            .onSubmit(submit)
                    }
                } footer: {
                    if let errorMessage {
                        StatusTone.failure.apply(to: Text(verbatim: errorMessage))
                    } else if mode == .export {
                        Text("Use at least 12 characters. This password can’t be recovered, and the archive can’t be opened without it.")
                    } else {
                        Text("Enter the password used when this archive was exported.")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(mode.title)
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(mode == .export ? "Export" : "Import", action: submit)
                            .disabled(canSubmit == false)
                    }
                }
            }
        }
        .vaultSheetSize(width: 460, height: 300)
        .interactiveDismissDisabled(isWorking)
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            focusedField = .password
        }
        .onDisappear {
            password = ""
            confirmation = ""
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isWorking = true
        errorMessage = nil
        let entered = password
        Task {
            let failure = await action(entered)
            isWorking = false
            if let failure {
                errorMessage = failure
                if mode == .importArchive { password = "" }
            }
        }
    }
}
