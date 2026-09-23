import QuickLook
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

struct SendView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var selection = 0
    @State private var pendingSwipeAction: SendSwipeAction?
    @State private var showingSwipeAlert = false

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
                            SendListRow(send: send, onSwipeAction: requestSwipeAction)
                        }
                    }
                    .vaultInsetGroupedListStyle()
                }
            }
            .background(Color.vaultBackground)
            .navigationTitle("Send")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .tint(nil)
                }
                ToolbarItem(placement: .vaultTrailing) {
                    Button { showingCreate = true } label: { Image(systemName: "plus") }
                        .tint(nil)
                }
            }
            .sheet(isPresented: $showingCreate) { CreateSendView() }
            .alert(swipeAlertTitle, isPresented: $showingSwipeAlert) {
                if case .some(.delete(_)) = pendingSwipeAction {
                    Button("Delete", role: .destructive) {
                        guard let send = pendingSwipeSend else { return }
                        pendingSwipeAction = nil
                        Task { await store.deleteSend(send) }
                    }
                } else if case .some(.changeStatus(_)) = pendingSwipeAction {
                    Button(pendingSwipeSend?.isDisabled == true ? "Activate" : "Deactivate") {
                        guard var send = pendingSwipeSend else { return }
                        pendingSwipeAction = nil
                        send.isDisabled.toggle()
                        Task { _ = await store.updateSend(send) }
                    }
                }
                Button("Cancel", role: .cancel) { pendingSwipeAction = nil }
            } message: {
                Text(swipeAlertMessage)
            }
        }
        .vaultSheetSize(width: 640, height: 680)
    }

    private var pendingSwipeSend: SendItem? {
        guard let id = pendingSwipeAction?.sendID else { return nil }
        return store.sends.first { $0.id == id }
    }

    private var swipeAlertTitle: String {
        let key: String = switch pendingSwipeAction {
        case .some(.delete(_)): "Delete Send?"
        case .some(.changeStatus(_)): pendingSwipeSend?.isDisabled == true ? "Activate Send?" : "Deactivate Send?"
        case nil: "Send"
        }
        return L10n.string(key)
    }

    private var swipeAlertMessage: String {
        guard let send = pendingSwipeSend else { return "" }
        switch pendingSwipeAction {
        case .some(.delete(_)):
            return L10n.format("This permanently deletes %@ and disables its shared link.", send.name)
        case .some(.changeStatus(_)):
            return send.isDisabled
                ? L10n.format("The shared link for %@ will become available again if it has not expired.", send.name)
                : L10n.format("The shared link for %@ will stop working until you activate it again.", send.name)
        case nil:
            return ""
        }
    }

    private func requestSwipeAction(_ action: SendSwipeAction) {
        pendingSwipeAction = action
        #if os(macOS)
        showingSwipeAlert = true
        #else
        showingSwipeAlert = false
        Task { @MainActor in
            // Let List finish dismissing its swipe host before presenting from
            // the stable navigation container. Presenting during that animation
            // makes SwiftUI dismiss/re-present the alert and can crash.
            try? await Task.sleep(for: .milliseconds(400))
            guard pendingSwipeAction == action, pendingSwipeSend != nil else {
                pendingSwipeAction = nil
                return
            }
            showingSwipeAlert = true
        }
        #endif
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

private enum SendSwipeAction: Equatable {
    case delete(UUID)
    case changeStatus(UUID)

    var sendID: UUID {
        switch self {
        case let .delete(id), let .changeStatus(id): id
        }
    }
}

private struct SendListRow: View {
    let send: SendItem
    let onSwipeAction: (SendSwipeAction) -> Void

    var body: some View {
        NavigationLink {
            SendDetailView(sendID: send.id)
        } label: {
            SendRow(send: send)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                onSwipeAction(.delete(send.id))
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)

            if send.isDisabled || !send.isExpired {
                Button {
                    onSwipeAction(.changeStatus(send.id))
                } label: {
                    Label(
                        send.isDisabled ? "Activate" : "Deactivate",
                        systemImage: send.isDisabled ? "play.fill" : "pause.fill"
                    )
                }
                .tint(send.isDisabled ? Color.vaultGreen : .orange)
            }
        }
        .contextMenu {
            if send.isDisabled || !send.isExpired {
                Button {
                    onSwipeAction(.changeStatus(send.id))
                } label: {
                    Label(send.isDisabled ? "Activate" : "Deactivate", systemImage: send.isDisabled ? "play.fill" : "pause.fill")
                }
            }
            Button(role: .destructive) {
                onSwipeAction(.delete(send.id))
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
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
                    Text(send.kind.localizedTitle)
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
        if send.isExpired { return L10n.string("Expired") }
        if let expiresAt = send.expiresAt {
            return L10n.format("Expires %@", expiresAt.formatted(.relative(presentation: .named)))
        }
        return L10n.format("Deletes %@", send.deletesAt.formatted(.relative(presentation: .named)))
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
                            Link(destination: shareURL) {
                                Label("Open Link", systemImage: "safari")
                            }
                            AnimatedCopyButton(value: shareURL.absoluteString, title: "Copy Link", accessibilityName: "send link")
                            ShareLink(item: shareURL) { Label("Share Link", systemImage: "square.and.arrow.up") }
                            if let temporaryPassword = store.temporaryPassword(for: send.id) {
                                AnimatedCopyButton(
                                    value: temporaryPassword,
                                    title: "Copy Password",
                                    accessibilityName: "send password"
                                )
                                Text("The generated password is kept only in memory and is removed when the vault locks.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Label("The server link will appear after upload completes.", systemImage: "clock")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section("Details") {
                        LabeledContent("Type", value: send.kind.localizedTitle)
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
                            .confirmationDialog(
                                "Delete this Send?",
                                isPresented: $showDelete,
                                titleVisibility: .visible
                            ) {
                                Button("Delete", role: .destructive) {
                                    Task { await store.deleteSend(send) }
                                }
                                Button("Cancel", role: .cancel) { }
                            }
                    }
                }
                .navigationTitle("Send Details")
                .vaultNavigationTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .vaultTrailing) {
                        Button("Edit") { showingEdit = true }
                            .tint(nil)
                    }
                }
                .sheet(isPresented: $showingEdit) {
                    CreateSendView(editing: send)
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
    @State private var deletionPeriod: SendDeletionPeriod
    @State private var maximumAccesses: Int
    @State private var limitAccesses: Bool
    @State private var passwordProtected: Bool
    @State private var password = ""
    @State private var passwordIsVisible = false
    @State private var disabled: Bool
    @State private var showingFileImporter = false
    #if os(iOS)
    @State private var showingCamera = false
    #endif
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var fileSelectionError: String?
    @State private var isCreating = false

    init(editing: SendItem? = nil) {
        editingSend = editing
        let calendar = Calendar.current
        let now = Date()
        let expiration = editing?.expiresAt.map {
            max(1, calendar.dateComponents([.day], from: now, to: $0).day ?? 1)
        } ?? 7
        let deletionPeriod = editing.map {
            SendDeletionPeriod.nearest(to: $0.deletesAt.timeIntervalSince(now))
        } ?? .thirtyDays
        _kind = State(initialValue: editing?.kind ?? .text)
        _name = State(initialValue: editing?.name ?? "")
        _text = State(initialValue: editing?.text ?? "")
        _fileName = State(initialValue: editing?.fileName)
        _expirationDays = State(initialValue: min(expiration, deletionPeriod.maximumExpirationDays ?? 1))
        _deletionPeriod = State(initialValue: deletionPeriod)
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
                        Label(SendKind.text.localizedTitle, systemImage: SendKind.text.icon).tag(SendKind.text)
                        Label(SendKind.file.localizedTitle, systemImage: SendKind.file.icon).tag(SendKind.file)
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
                            if isImportingFile {
                                HStack(spacing: 10) {
                                    ProgressView()
                                    Text("Preparing file…")
                                        .foregroundStyle(.secondary)
                                }
                            }

                            HStack(spacing: 8) {
                                #if os(iOS)
                                Button {
                                    guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                                        fileSelectionError = "Camera is not available on this device."
                                        return
                                    }
                                    showingCamera = true
                                } label: {
                                    SendFileSourceLabel(title: "Camera", systemImage: "camera.fill")
                                }
                                .disabled(isImportingFile)
                                #endif

                                PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                                    SendFileSourceLabel(title: "Photos", systemImage: "photo.on.rectangle")
                                }
                                .disabled(isImportingFile)

                                Button {
                                    showingFileImporter = true
                                } label: {
                                    SendFileSourceLabel(title: "Files", systemImage: "folder.fill")
                                }
                                .disabled(isImportingFile)
                            }
                            .buttonStyle(.bordered)

                            Text("Maximum file size: 100 MB.")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let fileSelectionError {
                                Label(fileSelectionError, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        } else {
                            Text("Replacing the encrypted file is not available from metadata editing.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Lifetime") {
                    Picker("Delete after", selection: $deletionPeriod) {
                        ForEach(SendDeletionPeriod.allCases) { period in
                            Text(period.title).tag(period)
                        }
                    }
                    if let maximumExpirationDays = deletionPeriod.maximumExpirationDays {
                        Stepper(
                            L10n.format("Expires in %lld days", expirationDays),
                            value: $expirationDays,
                            in: 1...maximumExpirationDays
                        )
                    } else {
                        LabeledContent("Expires", value: "At deletion")
                    }
                    Toggle("Limit access count", isOn: $limitAccesses)
                    if limitAccesses {
                        Stepper(L10n.format("Maximum: %lld", maximumAccesses), value: $maximumAccesses, in: 1...100)
                    }
                }

                Section("Protection") {
                    Toggle("Require password", isOn: $passwordProtected)
                    if passwordProtected {
                        HStack {
                            Group {
                                if passwordIsVisible {
                                    TextField(passwordPrompt, text: $password)
                                } else {
                                    SecureField(passwordPrompt, text: $password)
                                }
                            }
                            .vaultTextContentType(.newPassword)
                            .autocorrectionDisabled()
                            .vaultTextInputAutocapitalization(.never)

                            Button {
                                passwordIsVisible.toggle()
                            } label: {
                                Image(systemName: passwordIsVisible ? "eye.slash" : "eye")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(passwordIsVisible ? "Hide password" : "Show password")

                            AnimatedCopyButton(
                                value: password,
                                accessibilityName: "Send password"
                            )
                            .id(password)
                            .buttonStyle(.plain)
                            .disabled(password.isEmpty)
                        }
                        .listRowSeparator(.hidden, edges: .bottom)

                        Button {
                            password = PasswordGenerator.password(
                                length: 24,
                                uppercase: true,
                                numbers: true,
                                symbols: false
                            )
                        } label: {
                            Text("Generate Password")
                        }
                        .listRowSeparator(.hidden)
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
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                        .tint(nil)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isCreating { ProgressView() } else { Text(editingSend == nil ? "Create" : "Save") }
                    }
                    .tint(nil)
                    .disabled(!canSave || isCreating)
                }
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.item]) { result in
                switch result {
                case let .success(url):
                    importFile(from: url)
                case let .failure(error):
                    fileSelectionError = error.localizedDescription
                }
            }
            #if os(iOS)
            .fullScreenCover(isPresented: $showingCamera) {
                SendCameraPicker { image in
                    importCameraImage(image)
                }
                .ignoresSafeArea()
            }
            #endif
            .onChange(of: selectedPhotoItem) { _, item in
                guard let item else { return }
                importPhoto(item)
            }
            .onChange(of: deletionPeriod) { _, period in
                expirationDays = min(expirationDays, period.maximumExpirationDays ?? 1)
            }
        }
        .formStyle(.grouped)
        .vaultSheetSize(width: 620, height: 680)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (kind == .text ? !text.isEmpty : fileName != nil)
            && (editingSend != nil || kind == .text || selectedFileURL != nil)
            && (!passwordProtected || editingSend?.passwordProtected == true || !password.isEmpty)
            && !isImportingFile
    }

    private var sendIntegrationMessage: String {
        if editingSend != nil {
            return L10n.string("Changes are encrypted on this device, saved to Vaultwarden, then synced back.")
        }
        return kind == .file
            ? L10n.string("The file is encrypted on this device before any bytes are uploaded. File creation requires a live server connection.")
            : L10n.string("Text Sends are encrypted locally and can be queued securely when offline.")
    }

    private func save() async {
        let id = editingSend?.id ?? UUID()
        let now = Date()
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
            expiresAt: deletionPeriod == .oneHour
                ? nil
                : Calendar.current.date(byAdding: .day, value: expirationDays, to: now),
            deletesAt: now.addingTimeInterval(deletionPeriod.timeInterval),
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
        if didSave {
            removeSelectedTemporaryFile()
            dismiss()
        }
    }

    private var passwordAction: SendPasswordUpdate {
        guard let editingSend else { return passwordProtected ? .set(password) : .preserve }
        if editingSend.passwordProtected, !passwordProtected { return .remove }
        if passwordProtected, !password.isEmpty { return .set(password) }
        return .preserve
    }

    private var passwordPrompt: String {
        L10n.string(editingSend?.passwordProtected == true ? "New password (optional)" : "Send password")
    }

    private func cancel() {
        removeSelectedTemporaryFile()
        dismiss()
    }

    private func importFile(from url: URL) {
        prepareSelection {
            try SendFileStager.stage(fileAt: url)
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        isImportingFile = true
        fileSelectionError = nil
        Task {
            defer {
                isImportingFile = false
                selectedPhotoItem = nil
            }
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    throw SendFileSelectionError.unavailable
                }
                let fileExtension = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let staged = try await Task.detached(priority: .userInitiated) {
                    try SendFileStager.stage(
                        data: data,
                        suggestedName: "Photo-\(UUID().uuidString).\(fileExtension)"
                    )
                }.value
                apply(staged)
            } catch {
                fileSelectionError = error.localizedDescription
            }
        }
    }

    #if os(iOS)
    private func importCameraImage(_ image: UIImage) {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            fileSelectionError = SendFileSelectionError.unavailable.localizedDescription
            return
        }
        prepareSelection {
            try SendFileStager.stage(
                data: data,
                suggestedName: "Camera-\(UUID().uuidString).jpg"
            )
        }
    }
    #endif

    private func prepareSelection(
        operation: @escaping @Sendable () throws -> StagedSendFile
    ) {
        isImportingFile = true
        fileSelectionError = nil
        Task {
            defer { isImportingFile = false }
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try operation()
                }.value
                apply(staged)
            } catch {
                fileSelectionError = error.localizedDescription
            }
        }
    }

    private func apply(_ staged: StagedSendFile) {
        removeSelectedTemporaryFile()
        selectedFileURL = staged.url
        fileName = staged.fileName
        selectedFileSize = ByteCountFormatter.string(
            fromByteCount: staged.byteCount,
            countStyle: .file
        )
    }

    private func removeSelectedTemporaryFile() {
        guard let selectedFileURL else { return }
        SendFileStager.removeStagedFile(at: selectedFileURL)
        self.selectedFileURL = nil
    }
}

private enum SendDeletionPeriod: Int, CaseIterable, Identifiable {
    case oneHour = 3_600
    case oneDay = 86_400
    case twoDays = 172_800
    case threeDays = 259_200
    case sevenDays = 604_800
    case thirtyDays = 2_592_000

    var id: Int { rawValue }
    var timeInterval: TimeInterval { TimeInterval(rawValue) }

    var title: String {
        let key: String = switch self {
        case .oneHour: "1 hour"
        case .oneDay: "1 day"
        case .twoDays: "2 days"
        case .threeDays: "3 days"
        case .sevenDays: "7 days"
        case .thirtyDays: "30 days"
        }
        return L10n.string(key)
    }

    var maximumExpirationDays: Int? {
        switch self {
        case .oneHour: nil
        case .oneDay: 1
        case .twoDays: 2
        case .threeDays: 3
        case .sevenDays: 7
        case .thirtyDays: 30
        }
    }

    static func nearest(to interval: TimeInterval) -> SendDeletionPeriod {
        allCases.min(by: { abs($0.timeInterval - interval) < abs($1.timeInterval - interval) }) ?? .thirtyDays
    }
}

private struct SendFileSourceLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
            Text(L10n.string(title))
                .font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 42)
    }
}

private nonisolated struct StagedSendFile: Sendable {
    let url: URL
    let fileName: String
    let byteCount: Int64
}

private nonisolated enum SendFileSelectionError: LocalizedError {
    case unavailable
    case folderNotSupported
    case tooLarge

    var errorDescription: String? {
        let key: String = switch self {
        case .unavailable: "The selected file could not be read. Please select it again."
        case .folderNotSupported: "Choose a single file instead of a folder."
        case .tooLarge: "The selected file is larger than the 100 MB limit."
        }
        return L10n.string(key)
    }
}

private nonisolated enum SendFileStager {
    static let maximumByteCount: Int64 = 100 * 1_024 * 1_024
    private static let directoryName = "SendSelections"

    static func stage(fileAt sourceURL: URL) throws -> StagedSendFile {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw SendFileSelectionError.unavailable
        }
        guard !isDirectory.boolValue else { throw SendFileSelectionError.folderNotSupported }

        let destinationDirectory = try makeDestinationDirectory()
        let fileName = sourceURL.lastPathComponent.isEmpty ? "Send File" : sourceURL.lastPathComponent
        let destinationURL = destinationDirectory.appendingPathComponent(fileName, isDirectory: false)
        var coordinationError: NSError?
        var copyError: Error?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(
            readingItemAt: sourceURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                if try byteCount(of: coordinatedURL) > maximumByteCount {
                    throw SendFileSelectionError.tooLarge
                }
                try FileManager.default.copyItem(at: coordinatedURL, to: destinationURL)
            } catch {
                copyError = error
            }
        }

        if let coordinationError {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw coordinationError
        }
        if let copyError {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw copyError
        }

        let size = try byteCount(of: destinationURL)
        guard size <= maximumByteCount else {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw SendFileSelectionError.tooLarge
        }
        return StagedSendFile(url: destinationURL, fileName: fileName, byteCount: size)
    }

    static func stage(data: Data, suggestedName: String) throws -> StagedSendFile {
        guard data.count <= maximumByteCount else { throw SendFileSelectionError.tooLarge }
        let destinationDirectory = try makeDestinationDirectory()
        let destinationURL = destinationDirectory.appendingPathComponent(suggestedName, isDirectory: false)
        do {
            try data.write(to: destinationURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: destinationDirectory)
            throw error
        }
        return StagedSendFile(
            url: destinationURL,
            fileName: suggestedName,
            byteCount: Int64(data.count)
        )
    }

    static func removeStagedFile(at url: URL) {
        let root = stagingRoot.standardizedFileURL
        let parent = url.deletingLastPathComponent().standardizedFileURL
        guard parent.path.hasPrefix(root.path + "/") else { return }
        try? FileManager.default.removeItem(at: parent)
    }

    private static var stagingRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    private static func makeDestinationDirectory() throws -> URL {
        let directory = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func byteCount(of url: URL) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return Int64(try handle.seekToEnd())
    }
}

#if os(iOS)
private struct SendCameraPicker: UIViewControllerRepresentable {
    let onImagePicked: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.cameraCaptureMode = .photo
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        private let parent: SendCameraPicker

        init(parent: SendCameraPicker) {
            self.parent = parent
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
#endif
