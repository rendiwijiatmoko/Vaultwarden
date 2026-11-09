import QuickLook
import PhotosUI
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
import UniformTypeIdentifiers

/// Where a Send stands, in the order the list shows them.
private enum SendStatus: CaseIterable, Identifiable {
    case active, deactivated, expired

    var id: Self { self }

    init(_ send: SendItem) {
        if send.isDisabled {
            self = .deactivated
        } else if send.isExpired {
            self = .expired
        } else {
            self = .active
        }
    }

    var title: String {
        switch self {
        case .active: L10n.string("Active")
        case .deactivated: L10n.string("Deactivated")
        case .expired: L10n.string("Expired")
        }
    }

    var color: Color {
        switch self {
        case .active: .vaultGreen
        case .deactivated: .secondary
        case .expired: .vaultRed
        }
    }
}

private extension SendItem {
    /// Activating an expired Send would not bring its link back.
    var canChangeActivation: Bool { isDisabled || !isExpired }

    var activationTitle: String { L10n.string(isDisabled ? "Activate" : "Deactivate") }
    var activationSymbol: String { isDisabled ? "play.fill" : "pause.fill" }
}

struct SendView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingCreate = false
    @State private var sendPendingDeletion: SendItem?
    @State private var showingDeleteConfirmation = false

    var body: some View {
        NavigationStack {
            Group {
                if store.sends.isEmpty {
                    ContentUnavailableView {
                        Label("No Sends", systemImage: "paperplane")
                    } description: {
                        Text("Share text or a file through an encrypted link.")
                    } actions: {
                        Button("New Send") { showingCreate = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(SendStatus.allCases) { status in
                            let group = sends(with: status)
                            if !group.isEmpty {
                                Section(status.title) {
                                    ForEach(group) { send in
                                        SendListRow(
                                            send: send,
                                            onDelete: requestDeletion,
                                            onToggleActivation: toggleActivation
                                        )
                                    }
                                }
                            }
                        }
                    }
                    .vaultInsetGroupedListStyle()
                }
            }
            .navigationTitle("Send")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .vaultTrailing) {
                    Button("New Send", systemImage: "plus") { showingCreate = true }
                        .help("New Send")
                }
            }
            .sheet(isPresented: $showingCreate) {
                CreateSendView()
                    .environmentObject(store)
            }
            .alert(
                L10n.format("Delete “%@”?", sendPendingDeletion?.name ?? ""),
                isPresented: $showingDeleteConfirmation,
                presenting: sendPendingDeletion
            ) { send in
                Button("Delete", role: .destructive) {
                    sendPendingDeletion = nil
                    Task { await store.deleteSend(send) }
                }
                Button("Cancel", role: .cancel) { sendPendingDeletion = nil }
            } message: { _ in
                Text("Its link stops working for everyone.")
            }
        }
        .vaultSheetSize(width: 640, height: 640)
    }

    private func sends(with status: SendStatus) -> [SendItem] {
        store.sends
            .filter { SendStatus($0) == status }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func toggleActivation(_ send: SendItem) {
        guard send.canChangeActivation else { return }
        var updated = send
        updated.isDisabled.toggle()
        Task { _ = await store.updateSend(updated) }
    }

    private func requestDeletion(_ send: SendItem) {
        sendPendingDeletion = send
        #if os(macOS)
        showingDeleteConfirmation = true
        #else
        Task { @MainActor in
            // Let List finish dismissing its swipe host before presenting from
            // the stable navigation container. Presenting during that animation
            // makes SwiftUI dismiss and re-present the alert, and can crash.
            try? await Task.sleep(for: .milliseconds(400))
            guard sendPendingDeletion?.id == send.id,
                  store.sends.contains(where: { $0.id == send.id }) else {
                sendPendingDeletion = nil
                return
            }
            showingDeleteConfirmation = true
        }
        #endif
    }
}

private struct SendListRow: View {
    let send: SendItem
    let onDelete: (SendItem) -> Void
    let onToggleActivation: (SendItem) -> Void

    var body: some View {
        NavigationLink {
            SendDetailView(sendID: send.id)
        } label: {
            SendRow(send: send)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(send) }
            if send.canChangeActivation {
                Button(send.activationTitle, systemImage: send.activationSymbol) { onToggleActivation(send) }
                    .tint(send.isDisabled ? Color.vaultGreen : .orange)
            }
        }
        .swipeActions(edge: .leading) {
            if let shareURL = send.shareURL {
                Button("Copy Link", systemImage: "link") { Clipboard.copy(shareURL.absoluteString) }
                    .tint(.vaultBlue)
            }
        }
        .contextMenu {
            if let shareURL = send.shareURL {
                Button("Copy Link", systemImage: "doc.on.doc") { Clipboard.copy(shareURL.absoluteString) }
                ShareLink(item: shareURL) {
                    Label("Share Link", systemImage: "square.and.arrow.up")
                }
                Divider()
            }
            if send.canChangeActivation {
                Button(send.activationTitle, systemImage: send.activationSymbol) { onToggleActivation(send) }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) { onDelete(send) }
        }
    }
}

private struct SendRow: View {
    let send: SendItem

    private var iconSize: CGFloat {
        #if os(macOS)
        28
        #else
        36
        #endif
    }

    var body: some View {
        let status = SendStatus(send)
        HStack(spacing: 12) {
            VaultIcon(systemName: send.kind.icon, color: status == .active ? .vaultBlue : .gray, size: iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(send.name)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 4) {
                    Text(send.kind.localizedTitle)
                    Text(verbatim: "·")
                    Text(statusText(status))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            if send.passwordProtected {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Password Protected")
            }
        }
        .padding(.vertical, 2)
    }

    private func statusText(_ status: SendStatus) -> String {
        switch status {
        case .deactivated:
            return status.title
        case .expired:
            let endedAt = [send.expiresAt, send.deletesAt].compactMap { $0 }.filter { $0 <= Date() }.min()
            guard let endedAt else { return status.title }
            return L10n.format("Expired %@", endedAt.formatted(.relative(presentation: .named)))
        case .active:
            if let expiresAt = send.expiresAt, expiresAt < send.deletesAt {
                return L10n.format("Expires %@", expiresAt.formatted(.relative(presentation: .named)))
            }
            return L10n.format("Deletes %@", send.deletesAt.formatted(.relative(presentation: .named)))
        }
    }
}

struct SendDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let sendID: UUID
    @State private var showingDelete = false
    @State private var showingEdit = false
    @State private var showingDownloadPassword = false
    @State private var downloadPassword = ""
    @State private var downloadedFileURL: URL?
    @State private var isDownloading = false
    @State private var isUpdating = false

    private var send: SendItem? { store.sends.first { $0.id == sendID } }

    var body: some View {
        Group {
            if let send {
                details(for: send)
            } else {
                ContentUnavailableView("Send Unavailable", systemImage: "paperplane")
            }
        }
        .vaultNavigationTitleDisplayMode(.inline)
        .onDisappear {
            if let downloadedFileURL {
                removeTemporaryDownload(downloadedFileURL)
                self.downloadedFileURL = nil
            }
        }
    }

    private func details(for send: SendItem) -> some View {
        let status = SendStatus(send)
        let temporaryPassword = store.temporaryPassword(for: send.id)
        return List {
            Section {
                HStack(spacing: 14) {
                    VaultIcon(systemName: send.kind.icon, color: status == .active ? .vaultBlue : .gray, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(send.name)
                            .font(.title3.bold())
                        Text(status.title)
                            .font(.subheadline)
                            .foregroundStyle(status.color)
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                if let shareURL = send.shareURL {
                    Text(shareURL.absoluteString)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                    AnimatedCopyButton(value: shareURL.absoluteString, title: "Copy Link", accessibilityName: "Send link")
                    ShareLink(item: shareURL) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
                    }
                    Link(destination: shareURL) {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    if let temporaryPassword {
                        AnimatedCopyButton(value: temporaryPassword, title: "Copy Password", accessibilityName: "Send password")
                    }
                } else {
                    Label("Waiting for Server", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Link")
            } footer: {
                if temporaryPassword != nil {
                    Text("The password stays in memory until the vault locks.")
                }
            }

            Section("Details") {
                LabeledContent("Type", value: send.kind.localizedTitle)
                LabeledContent("Access Count", value: accessSummary(send))
                if let expiresAt = send.expiresAt {
                    LabeledContent("Expires", value: expiresAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Deletes", value: send.deletesAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Password", value: L10n.string(send.passwordProtected ? "On" : "Off"))
            }

            if send.kind == .text, !send.text.isEmpty {
                Section("Text") {
                    Text(send.text)
                        .textSelection(.enabled)
                    AnimatedCopyButton(value: send.text, title: "Copy Text", accessibilityName: "Send text")
                }
            }

            if let fileName = send.fileName {
                Section("File") {
                    Label(fileName, systemImage: "doc.fill")
                    if let fileSize = send.fileSize {
                        LabeledContent("Size", value: fileSize)
                    }
                    Button {
                        if send.passwordProtected {
                            showingDownloadPassword = true
                        } else {
                            Task { await download(send, password: nil) }
                        }
                    } label: {
                        if isDownloading {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Downloading…")
                            }
                        } else {
                            Label("Download", systemImage: "arrow.down.circle")
                        }
                    }
                    .disabled(isDownloading)
                }
            }

            Section {
                if send.canChangeActivation {
                    Button(send.activationTitle) { toggleActivation(send) }
                        .disabled(isUpdating)
                }
                Button("Delete Send", role: .destructive) { showingDelete = true }
            }
        }
        .toolbar {
            ToolbarItem(placement: .vaultTrailing) {
                Button("Edit") { showingEdit = true }
            }
        }
        .sheet(isPresented: $showingEdit) {
            CreateSendView(editing: send)
                .environmentObject(store)
        }
        .confirmationDialog(
            L10n.format("Delete “%@”?", send.name),
            isPresented: $showingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Send", role: .destructive) {
                Task {
                    await store.deleteSend(send)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its link stops working for everyone.")
        }
        .alert("Enter Send Password", isPresented: $showingDownloadPassword) {
            SecureField("Password", text: $downloadPassword)
            Button("Cancel", role: .cancel) { downloadPassword = "" }
            Button("Download") {
                let password = downloadPassword
                downloadPassword = ""
                Task { await download(send, password: password) }
            }
            .disabled(downloadPassword.isEmpty)
        } message: {
            Text("This file is protected with a password.")
        }
        .quickLookPreview($downloadedFileURL)
        .onChange(of: downloadedFileURL) { oldURL, newURL in
            if let oldURL, newURL == nil {
                removeTemporaryDownload(oldURL)
            }
        }
    }

    private func accessSummary(_ send: SendItem) -> String {
        if let maximum = send.maximumAccessCount {
            return L10n.format("%lld of %lld", send.accessCount, maximum)
        }
        return send.accessCount.formatted()
    }

    private func toggleActivation(_ send: SendItem) {
        guard !isUpdating else { return }
        var updated = send
        updated.isDisabled.toggle()
        isUpdating = true
        Task {
            _ = await store.updateSend(updated)
            isUpdating = false
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
    private let original: SendDraft
    private let openedAt: Date
    @State private var draft: SendDraft
    @State private var fileName: String?
    @State private var selectedFileURL: URL?
    @State private var selectedFileSize: String?
    @State private var passwordIsVisible = false
    @State private var showingFileImporter = false
    #if os(iOS)
    @State private var showingCamera = false
    #endif
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isImportingFile = false
    @State private var fileSelectionError: String?
    @State private var isSaving = false
    @State private var showingDiscardConfirmation = false

    init(editing: SendItem? = nil) {
        let now = Date()
        let draft = SendDraft(editing: editing, now: now)
        editingSend = editing
        original = draft
        openedAt = now
        _draft = State(initialValue: draft)
        _fileName = State(initialValue: editing?.fileName)
    }

    private var hasChanges: Bool { draft != original || selectedFileURL != nil }

    private var canSave: Bool {
        !isImportingFile && !isSaving && draft.isValid(
            existing: editingSend,
            hasNewFile: selectedFileURL != nil,
            hasFileName: fileName != nil
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if editingSend == nil {
                        Picker("Type", selection: $draft.kind) {
                            Label(SendKind.text.localizedTitle, systemImage: SendKind.text.icon).tag(SendKind.text)
                            Label(SendKind.file.localizedTitle, systemImage: SendKind.file.icon).tag(SendKind.file)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    TextField("Name", text: $draft.name)
                }

                if draft.kind == .text {
                    Section("Text") {
                        TextEditor(text: $draft.text)
                            .frame(minHeight: 120)
                    }
                } else {
                    fileSection
                }

                Section("Availability") {
                    DatePicker(
                        "Deletion Date",
                        selection: $draft.deletionDate,
                        in: SendDraft.deletionRange(now: openedAt, current: original.deletionDate)
                    )
                    Toggle("Expiration", isOn: $draft.expires)
                    if draft.expires {
                        DatePicker(
                            "Expires",
                            selection: $draft.expirationDate,
                            in: draft.expirationRange(now: openedAt, current: editingSend?.expiresAt)
                        )
                    }
                    Toggle("Limit Access", isOn: $draft.limitsAccess)
                    if draft.limitsAccess {
                        Stepper(value: $draft.maximumAccessCount, in: SendDraft.accessCountRange) {
                            LabeledContent("Maximum Accesses") {
                                Text(draft.maximumAccessCount, format: .number)
                                    .monospacedDigit()
                            }
                        }
                    }
                    Toggle("Active", isOn: $draft.isActive)
                }

                passwordSection
            }
            .formStyle(.grouped)
            .navigationTitle(editingSend == nil ? "New Send" : "Edit Send")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges { showingDiscardConfirmation = true } else { cancel() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving { ProgressView() } else { Text(editingSend == nil ? "Create" : "Save") }
                    }
                    .disabled(!canSave)
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Discard Changes?", isPresented: $showingDiscardConfirmation, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { cancel() }
                Button("Keep Editing", role: .cancel) {}
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
            .onChange(of: draft.deletionDate) { _, deletionDate in
                if draft.expirationDate > deletionDate { draft.expirationDate = deletionDate }
            }
        }
        .vaultSheetSize(width: 620, height: 640)
    }

    private var fileSection: some View {
        Section {
            if let fileName {
                LabeledContent {
                    if let selectedFileSize { Text(selectedFileSize) }
                } label: {
                    Label(fileName, systemImage: "doc.fill")
                }
            }
            if editingSend == nil {
                if isImportingFile {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing File…")
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    #if os(iOS)
                    Button {
                        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
                            fileSelectionError = L10n.string("Camera is not available on this device.")
                            return
                        }
                        showingCamera = true
                    } label: {
                        SendFileSourceLabel(title: "Camera", systemImage: "camera.fill")
                    }
                    #endif

                    PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                        SendFileSourceLabel(title: "Photos", systemImage: "photo.on.rectangle")
                    }

                    Button {
                        showingFileImporter = true
                    } label: {
                        SendFileSourceLabel(title: "Files", systemImage: "folder.fill")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isImportingFile)

                if let fileSelectionError {
                    Label(fileSelectionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
        } header: {
            Text("File")
        } footer: {
            if editingSend == nil {
                Text("Encrypted on this device before upload. Up to 100 MB.")
            }
        }
    }

    private var passwordSection: some View {
        Section {
            Toggle("Require Password", isOn: $draft.requiresPassword)
            if draft.requiresPassword {
                HStack(spacing: 8) {
                    Group {
                        if passwordIsVisible {
                            TextField(passwordPrompt, text: $draft.password)
                        } else {
                            SecureField(passwordPrompt, text: $draft.password)
                        }
                    }
                    .vaultTextContentType(.newPassword)
                    .autocorrectionDisabled()
                    .vaultTextInputAutocapitalization(.never)

                    Button {
                        passwordIsVisible.toggle()
                    } label: {
                        Image(systemName: passwordIsVisible ? "eye.slash" : "eye")
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(passwordIsVisible ? "Hide Password" : "Show Password")

                    AnimatedCopyButton(value: draft.password, accessibilityName: "Send password")
                        .id(draft.password)
                        .buttonStyle(.borderless)
                        .disabled(draft.password.isEmpty)
                }

                Button("Generate Password") {
                    draft.password = SecretGenerator.password(
                        SecretGenerator.PasswordOptions(length: 24, includesSymbols: false)
                    )
                    passwordIsVisible = true
                }
            }
        } footer: {
            if editingSend?.passwordProtected == true && !draft.requiresPassword {
                Text("Saving removes the password from this Send.")
            }
        }
    }

    private var passwordPrompt: String {
        L10n.string(editingSend?.passwordProtected == true ? "New Password (Optional)" : "Password")
    }

    private func save() async {
        guard canSave else { return }
        let send = draft.makeSend(
            id: editingSend?.id ?? UUID(),
            existing: editingSend,
            fileName: fileName,
            fileSize: selectedFileSize
        )
        isSaving = true
        defer { isSaving = false }
        let didSave: Bool
        if editingSend != nil {
            didSave = await store.updateSend(send, passwordUpdate: draft.passwordUpdate(existing: editingSend))
        } else {
            didSave = await store.addSend(
                send,
                password: draft.requiresPassword ? draft.password : nil,
                fileURL: selectedFileURL
            )
        }
        if didSave {
            removeSelectedTemporaryFile()
            dismiss()
        }
    }

    private func cancel() {
        removeSelectedTemporaryFile()
        dismiss()
    }

    private func importFile(from url: URL) {
        prepareSelection(suggestsName: true) {
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
        suggestsName: Bool = false,
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
                apply(staged, suggestsName: suggestsName)
            } catch {
                fileSelectionError = error.localizedDescription
            }
        }
    }

    private func apply(_ staged: StagedSendFile, suggestsName: Bool = false) {
        removeSelectedTemporaryFile()
        selectedFileURL = staged.url
        fileName = staged.fileName
        selectedFileSize = ByteCountFormatter.string(
            fromByteCount: staged.byteCount,
            countStyle: .file
        )
        // A file chosen from Files has a meaningful name; photos don't.
        if suggestsName, draft.trimmedName.isEmpty {
            draft.name = (staged.fileName as NSString).deletingPathExtension
        }
    }

    private func removeSelectedTemporaryFile() {
        guard let selectedFileURL else { return }
        SendFileStager.removeStagedFile(at: selectedFileURL)
        self.selectedFileURL = nil
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
