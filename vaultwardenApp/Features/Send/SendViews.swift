import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingCreate = false
    @State private var selection = 0

    private var displayedSends: [SendItem] {
        store.sends.filter { selection == 0 ? !$0.isExpired : $0.isExpired }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sendIntro
                Picker("Send status", selection: $selection) {
                    Text("Active").tag(0)
                    Text("Expired").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)

                if displayedSends.isEmpty {
                    EmptyStateView(icon: "paperplane", title: "No Sends", message: selection == 0 ? "Create a secure text or file link." : "Expired Sends will appear here.")
                        .frame(maxHeight: .infinity)
                } else {
                    List {
                        ForEach(displayedSends) { send in
                            NavigationLink {
                                SendDetailView(sendID: send.id)
                            } label: {
                                SendRow(send: send)
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .background(Color.vaultBackground)
            .navigationTitle("Send")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showingCreate) { CreateSendView() }
        }
    }

    private var sendIntro: some View {
        HStack(spacing: 14) {
            VaultIcon(systemName: "paperplane.fill", color: .vaultBlue, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text("Share securely")
                    .font(.headline)
                Text("Send encrypted text and files with an expiring link.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(16)
    }
}

private struct SendRow: View {
    let send: SendItem

    var body: some View {
        HStack(spacing: 13) {
            VaultIcon(systemName: send.kind.icon, color: send.isExpired ? .gray : .vaultBlue, size: 42)
            VStack(alignment: .leading, spacing: 4) {
                Text(send.name)
                    .font(.body.weight(.semibold))
                HStack(spacing: 5) {
                    Text(send.kind.rawValue)
                    Text("•")
                    Text(statusText(for: send))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
            if send.passwordProtected {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Color.vaultGreen)
            }
        }
        .padding(.vertical, 7)
    }

    private func statusText(for send: SendItem) -> String {
        if send.isExpired { return "Expired" }
        if let expiresAt = send.expiresAt {
            return "Expires \(expiresAt.formatted(.relative(presentation: .named)))"
        }
        return "Deletes \(send.deletesAt.formatted(.relative(presentation: .named)))"
    }
}

struct SendDetailView: View {
    @EnvironmentObject private var store: AppStore
    let sendID: UUID
    @State private var showDelete = false
    @State private var showingEdit = false
    @State private var showingDownloadPassword = false
    @State private var downloadPassword = ""
    @State private var downloadedFileURL: URL?
    @State private var isDownloading = false

    private var send: SendItem? { store.sends.first { $0.id == sendID } }

    var body: some View {
        Group {
            if let send {
                List {
                    Section {
                        HStack(spacing: 15) {
                            VaultIcon(systemName: send.kind.icon, color: send.isExpired ? .gray : .vaultBlue, size: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(send.name).font(.title3.bold())
                                Text(send.isExpired ? "Expired or disabled" : "Active secure link")
                                    .foregroundStyle(send.isExpired ? Color.vaultRed : Color.vaultGreen)
                            }
                        }
                        .padding(.vertical, 7)
                    }

                    Section("Link") {
                        if let shareURL = send.shareURL {
                            Text(shareURL.absoluteString)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                            AnimatedCopyButton(value: shareURL.absoluteString, title: "Copy Link", accessibilityName: "send link")
                            ShareLink(item: shareURL) { Label("Share Link", systemImage: "square.and.arrow.up") }
                        } else {
                            Label("The server link will appear after upload completes.", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Details") {
                        LabeledContent("Type", value: send.kind.rawValue)
                        LabeledContent("Access count", value: "\(send.accessCount)")
                        if let maximum = send.maximumAccessCount {
                            LabeledContent("Maximum accesses", value: "\(maximum)")
                        }
                        if let expiresAt = send.expiresAt {
                            LabeledContent("Expires", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        LabeledContent("Deletes", value: send.deletesAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Password", value: send.passwordProtected ? "Protected" : "Not set")
                    }

                    if send.kind == .text, !send.text.isEmpty {
                        Section("Protected Text") { Text(send.text) }
                    }
                    if let fileName = send.fileName {
                        Section("File") {
                            Label(fileName, systemImage: "doc.fill")
                            if let fileSize = send.fileSize {
                                LabeledContent("Encrypted size", value: fileSize)
                            }
                            Button {
                                if send.passwordProtected {
                                    showingDownloadPassword = true
                                } else {
                                    Task { await download(send, password: nil) }
                                }
                            } label: {
                                if isDownloading {
                                    HStack { ProgressView(); Text("Downloading & decrypting…") }
                                } else {
                                    Label("Download & Decrypt", systemImage: "arrow.down.doc.fill")
                                }
                            }
                            .disabled(isDownloading)
                        }
                    }

                    Section {
                        Button("Delete Send", role: .destructive) { showDelete = true }
                    }
                }
                .navigationTitle("Send Details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { showingEdit = true }
                    }
                }
                .sheet(isPresented: $showingEdit) {
                    CreateSendView(editing: send)
                }
                .confirmationDialog("Delete this Send?", isPresented: $showDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) { Task { await store.deleteSend(send) } }
                }
                .alert("Unlock File Send", isPresented: $showingDownloadPassword) {
                    SecureField("Send password", text: $downloadPassword)
                    Button("Cancel", role: .cancel) { downloadPassword = "" }
                    Button("Download") {
                        let password = downloadPassword
                        downloadPassword = ""
                        Task { await download(send, password: password) }
                    }
                    .disabled(downloadPassword.isEmpty)
                } message: {
                    Text("Vaultwarden requires this Send's password before issuing a one-time download URL.")
                }
                .quickLookPreview($downloadedFileURL)
                .onChange(of: downloadedFileURL) { oldURL, newURL in
                    if let oldURL, newURL == nil {
                        removeTemporaryDownload(oldURL)
                    }
                }
                .onDisappear {
                    if let downloadedFileURL {
                        removeTemporaryDownload(downloadedFileURL)
                        self.downloadedFileURL = nil
                    }
                }
            } else {
                EmptyStateView(icon: "paperplane", title: "Send unavailable", message: "This Send may have been deleted.")
            }
        }
    }

    private func download(_ send: SendItem, password: String?) async {
        isDownloading = true
        defer { isDownloading = false }
        downloadedFileURL = await store.downloadSendFile(send, password: password)
    }

    private func removeTemporaryDownload(_ url: URL) {
        let downloadsRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DecryptedSends", isDirectory: true)
            .standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(downloadsRoot.path + "/") else { return }
        try? FileManager.default.removeItem(at: parent)
    }
}

struct CreateSendView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private let editingSend: SendItem?
    @State private var kind: SendKind
    @State private var name: String
    @State private var text: String
    @State private var fileName: String?
    @State private var selectedFileURL: URL?
    @State private var selectedFileSize: String?
    @State private var expirationDays: Int
    @State private var deletionDays: Int
    @State private var maximumAccesses: Int
    @State private var limitAccesses: Bool
    @State private var passwordProtected: Bool
    @State private var password = ""
    @State private var disabled: Bool
    @State private var showingFileImporter = false
    @State private var isCreating = false

    init(editing: SendItem? = nil) {
        editingSend = editing
        let calendar = Calendar.current
        let now = Date()
        let expiration = editing?.expiresAt.map {
            max(1, calendar.dateComponents([.day], from: now, to: $0).day ?? 1)
        } ?? 7
        let deletion = max(
            expiration,
            editing.map { max(1, calendar.dateComponents([.day], from: now, to: $0.deletesAt).day ?? 1) } ?? 30
        )
        _kind = State(initialValue: editing?.kind ?? .text)
        _name = State(initialValue: editing?.name ?? "")
        _text = State(initialValue: editing?.text ?? "")
        _fileName = State(initialValue: editing?.fileName)
        _expirationDays = State(initialValue: min(expiration, 30))
        _deletionDays = State(initialValue: min(deletion, 31))
        _maximumAccesses = State(initialValue: editing?.maximumAccessCount ?? 10)
        _limitAccesses = State(initialValue: editing?.maximumAccessCount != nil)
        _passwordProtected = State(initialValue: editing?.passwordProtected ?? false)
        _disabled = State(initialValue: editing?.isDisabled ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $kind) {
                        Label(SendKind.text.rawValue, systemImage: SendKind.text.icon).tag(SendKind.text)
                        Label(SendKind.file.rawValue, systemImage: SendKind.file.icon).tag(SendKind.file)
                    }
                    .pickerStyle(.segmented)
                    .disabled(editingSend != nil)
                    TextField("Name", text: $name)
                }

                if kind == .text {
                    Section("Protected Text") {
                        TextEditor(text: $text)
                            .frame(minHeight: 130)
                    }
                } else {
                    Section("File") {
                        if let fileName {
                            Label(fileName, systemImage: "doc.fill")
                            if let selectedFileSize { Text(selectedFileSize).font(.caption).foregroundStyle(.secondary) }
                        }
                        if editingSend == nil {
                            Button("Choose File") { showingFileImporter = true }
                        } else {
                            Text("Replacing the encrypted file is not available from metadata editing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Lifetime") {
                    Stepper("Expires in \(expirationDays) days", value: $expirationDays, in: 1...30)
                    Stepper("Delete in \(deletionDays) days", value: $deletionDays, in: expirationDays...31)
                    Toggle("Limit access count", isOn: $limitAccesses)
                    if limitAccesses {
                        Stepper("Maximum: \(maximumAccesses)", value: $maximumAccesses, in: 1...100)
                    }
                }

                Section("Protection") {
                    Toggle("Require password", isOn: $passwordProtected)
                    if passwordProtected {
                        SecureField(
                            editingSend?.passwordProtected == true ? "New password (optional)" : "Send password",
                            text: $password
                        )
                        if editingSend?.passwordProtected == true {
                            Text("Leave blank to keep the current password.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else if editingSend?.passwordProtected == true {
                        Text("Saving will remove the current Send password.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    Toggle("Create disabled", isOn: $disabled)
                }

                Section {
                    Label(sendIntegrationMessage, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(editingSend == nil ? "New Send" : "Edit Send")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isCreating { ProgressView() } else { Text(editingSend == nil ? "Create" : "Save") }
                    }
                    .disabled(!canSave || isCreating)
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
                if case let .success(url) = result {
                    selectedFileURL = url
                    fileName = url.lastPathComponent
                    selectedFileSize = Self.formattedSize(url)
                }
            }
            .onChange(of: expirationDays) { _, value in
                if deletionDays < value { deletionDays = value }
            }
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind == .text ? !text.isEmpty : fileName != nil)
            && (editingSend != nil || kind == .text || selectedFileURL != nil)
            && (!passwordProtected || editingSend?.passwordProtected == true || !password.isEmpty)
    }

    private var sendIntegrationMessage: String {
        if editingSend != nil {
            return "Changes are encrypted on this device, saved to Vaultwarden, then synced back."
        }
        return kind == .file
            ? "The file is encrypted on this device before any bytes are uploaded. File creation requires a live server connection."
            : "Text Sends are encrypted locally and can be queued securely when offline."
    }

    private func save() async {
        let id = editingSend?.id ?? UUID()
        let send = SendItem(
            id: id,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            kind: kind,
            text: text,
            fileName: fileName,
            fileID: editingSend?.fileID,
            fileSize: editingSend?.fileSize ?? selectedFileSize,
            accessCount: editingSend?.accessCount ?? 0,
            maximumAccessCount: limitAccesses ? maximumAccesses : nil,
            expiresAt: Calendar.current.date(byAdding: .day, value: expirationDays, to: Date())!,
            deletesAt: Calendar.current.date(byAdding: .day, value: deletionDays, to: Date())!,
            passwordProtected: passwordProtected,
            isDisabled: disabled,
            shareURL: editingSend?.shareURL
        )
        isCreating = true
        defer { isCreating = false }
        let didSave: Bool
        if editingSend != nil {
            didSave = await store.updateSend(send, passwordUpdate: passwordAction)
        } else {
            didSave = await store.addSend(
                send,
                password: passwordProtected ? password : nil,
                fileURL: selectedFileURL
            )
        }
        if didSave { dismiss() }
    }

    private var passwordAction: SendPasswordUpdate {
        guard let editingSend else { return passwordProtected ? .set(password) : .preserve }
        if editingSend.passwordProtected, !passwordProtected { return .remove }
        if passwordProtected, !password.isEmpty { return .set(password) }
        return .preserve
    }

    private static func formattedSize(_ url: URL) -> String? {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}
