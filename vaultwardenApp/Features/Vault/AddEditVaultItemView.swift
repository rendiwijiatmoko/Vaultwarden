import PhotosUI
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import VisionKit
#endif

struct AddEditVaultItemView: View {
    /// `sheet` brings its own navigation stack and Cancel/Save titles.
    /// `inline` drops the stack so the editor can take over a detail screen
    /// that is already inside one, and uses the compact ✕ / ✓ controls.
    enum Presentation {
        case sheet
        case inline
    }

    private struct EditableWebsiteURI: Identifiable {
        let id = UUID()
        var value: String
    }

    private struct EditableSnapshot: Equatable {
        let name: String
        let username: String
        let password: String
        let uris: [String]
        let type: VaultItemType
        let folder: String?
        let notes: String
        let sshKeyFingerprint: String?
        let isFavorite: Bool
        let totpSecret: String?
        let card: CardDetails?
        let identity: IdentityDetails?
        let customFields: [VaultCustomField]
    }

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    private let existingItem: VaultItem?
    private let existingID: UUID?
    private let presentation: Presentation
    /// Called instead of `dismiss()` when the editor is hosted inline.
    private let onFinish: (() -> Void)?
    @State private var name: String
    @State private var username: String
    @State private var password: String
    @State private var websiteURIs: [EditableWebsiteURI]
    @State private var type: VaultItemType
    @State private var folder: String
    @State private var notes: String
    @State private var sshKeyFingerprint: String
    @State private var isFavorite: Bool
    @State private var totpSecret: String
    @State private var card: CardDetails
    @State private var identity: IdentityDetails
    @State private var customFields: [VaultCustomField]
    @State private var pendingAttachments: [StagedVaultAttachment] = []
    @State private var attachmentsMarkedForRemoval: Set<String> = []
    @State private var removedAttachmentIDs: Set<String> = []
    @State private var showingAttachmentImporter = false
    @State private var showingAttachmentPhotos = false
    @State private var selectedAttachmentPhoto: PhotosPickerItem?
    @State private var attachmentError: String?
    @State private var showingGenerator = false
    @State private var showingUsernameGenerator = false
    @State private var showingTOTPScanner = false
    @State private var totpScanError: String?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var passwordSuggestion: String
    @State private var usernameSuggestion: String
    @State private var notesFocusID = UUID()
    @State private var isKeyboardVisible = false
    @State private var showingDiscardConfirmation = false
    @State private var baseline: EditableSnapshot?
    @FocusState private var focusedCredentialField: AddEditCredentialField?

    init(
        existingItem: VaultItem? = nil,
        prefilledPassword: String = "",
        prefilledName: String = "",
        prefilledUsername: String = "",
        prefilledTOTPSecret: String = "",
        prefilledSSHFingerprint: String = "",
        prefilledType: VaultItemType = .login,
        prefilledFolder: String = "",
        presentation: Presentation = .sheet,
        onFinish: (() -> Void)? = nil
    ) {
        self.existingItem = existingItem
        existingID = existingItem?.id
        self.presentation = presentation
        self.onFinish = onFinish
        _name = State(initialValue: existingItem?.name ?? prefilledName)
        _username = State(initialValue: existingItem?.username ?? prefilledUsername)
        _password = State(initialValue: existingItem?.password ?? prefilledPassword)
        let initialURIs = existingItem?.websiteURIs ?? []
        _websiteURIs = State(
            initialValue: (initialURIs.isEmpty ? [""] : initialURIs)
                .map { EditableWebsiteURI(value: $0) }
        )
        _type = State(initialValue: existingItem?.type ?? prefilledType)
        _folder = State(initialValue: existingItem?.folder ?? prefilledFolder)
        _notes = State(initialValue: existingItem?.notes ?? "")
        _sshKeyFingerprint = State(initialValue: existingItem?.displayedSSHFingerprint ?? prefilledSSHFingerprint)
        _isFavorite = State(initialValue: existingItem?.isFavorite ?? false)
        _totpSecret = State(initialValue: existingItem?.totpSecret ?? prefilledTOTPSecret)
        _card = State(initialValue: existingItem?.card ?? CardDetails())
        _identity = State(initialValue: existingItem?.identity ?? IdentityDetails())
        _customFields = State(initialValue: existingItem?.customFields ?? [])
        // Suggestions are generated when the editor appears, not on every init.
        _passwordSuggestion = State(initialValue: "")
        _usernameSuggestion = State(initialValue: "")
    }

    var body: some View {
        switch presentation {
        case .sheet:
            NavigationStack { editor }
                .vaultSheetSize(width: 580, height: 620)
                // A swipe down mustn't silently throw away edits.
                .interactiveDismissDisabled(hasChanges)
        case .inline: editor
        }
    }

    private var editor: some View {
        Form {
                Section {
                    if existingItem == nil {
                        Picker("Type", selection: $type) {
                            ForEach(VaultItemType.allCases) {
                                Text($0.localizedTitle).tag($0)
                            }
                        }
                    }
                    LabeledFormField(
                        "Name",
                        text: $name,
                        placeholder: type == .login ? (suggestedName ?? "Required") : "Required",
                        textContentType: .name
                    )
                }

                if type == .login {
                    loginSections
                } else if type == .card {
                    cardForm
                } else if type == .identity {
                    identityForm
                } else if type == .sshKey {
                    Section("SSH Key") {
                        SSHKeyGeneratorFields(
                            privateKey: $password,
                            publicKey: $username,
                            fingerprint: $sshKeyFingerprint,
                            allowsGeneration: existingItem == nil
                        )
                    }
                }

                Section("Notes") {
                    TextField("Notes", text: $notes, axis: .vertical)
                        .lineLimit(4...)
                        .labelsHidden()
                        .focused($focusedCredentialField, equals: .nonCredential(notesFocusID))
                }

                Section {
                    Picker("Folder", selection: $folder) {
                        Text("No Folder").tag("")
                        ForEach(store.sortedFolders) { Text($0.name).tag($0.name) }
                    }
                    Toggle("Favorite", isOn: $isFavorite)
                }

                customFieldsEditor

                attachmentsSection
            }
            .formStyle(.grouped)
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .fileImporter(
                isPresented: $showingAttachmentImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    for url in urls { stageAttachment(url) }
                case let .failure(error):
                    attachmentError = error.localizedDescription
                }
            }
            .photosPicker(
                isPresented: $showingAttachmentPhotos,
                selection: $selectedAttachmentPhoto,
                matching: .images
            )
            .onChange(of: selectedAttachmentPhoto) { _, photo in
                guard let photo else { return }
                Task {
                    defer { selectedAttachmentPhoto = nil }
                    do {
                        guard let data = try await photo.loadTransferable(type: Data.self) else {
                            throw VaultAttachmentStageError.unavailable
                        }
                        let ext = photo.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let staged = try await Task.detached(priority: .userInitiated) {
                            try VaultAttachmentStager.stage(
                                data: data,
                                fileName: "Photo-\(UUID().uuidString).\(ext)"
                            )
                        }.value
                        pendingAttachments.append(staged)
                        attachmentError = nil
                    } catch {
                        attachmentError = error.localizedDescription
                    }
                }
            }
            .environment(\.addEditFocusBinding, $focusedCredentialField)
            #if os(iOS)
            .background {
                KeyboardDismissTapInstaller {
                    focusedCredentialField = nil
                }
            }
            #endif
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if showsCredentialSuggestions, let activeCredentialField {
                    CredentialKeyboardSuggestion(
                        title: activeCredentialField.suggestionTitle,
                        value: suggestion(for: activeCredentialField),
                        onUse: { useSuggestion(for: activeCredentialField) },
                        onCustomize: { presentGenerator(for: activeCredentialField) }
                    )
                    .id(activeCredentialField)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                    .accessibilityIdentifier("credentialSuggestionPanel")
                }
            }
            .navigationTitle(navigationTitleText)
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        switch presentation {
                        case .sheet: Text("Cancel")
                        case .inline: Image(systemName: "xmark")
                        }
                    }
                    .accessibilityLabel("Cancel")
                    .tint(nil)
                    .confirmationDialog(
                        "Discard Changes?",
                        isPresented: $showingDiscardConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Discard Changes", role: .destructive, action: finish)
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await save() }
                    } label: {
                        if isSaving {
                            ProgressView()
                        } else {
                            switch presentation {
                            case .sheet: Text("Save")
                            case .inline: Image(systemName: "checkmark")
                            }
                        }
                    }
                    .accessibilityLabel("Save")
                    .buttonStyle(.borderedProminent)
                    .tint(nil)
                    .disabled(!canSave)
                }
            }
            .alert("Unable to Save", isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            )) {
                Button("OK", role: .cancel) { saveError = nil }
            } message: {
                Text(saveError ?? "Please try again.")
            }
            .sheet(isPresented: $showingGenerator) {
                QuickPasswordGeneratorView { generated in
                    password = generated
                    passwordSuggestion = generated
                    showingGenerator = false
                }
            }
            .sheet(isPresented: $showingUsernameGenerator) {
                QuickUsernameGeneratorView { generated in
                    if type == .identity {
                        identity.username = generated
                    } else {
                        username = generated
                    }
                    usernameSuggestion = generated
                    showingUsernameGenerator = false
                }
            }
            .sheet(isPresented: $showingTOTPScanner) {
                NavigationStack {
                    TOTPQRCodeScannerView { scannedValue in
                        showingTOTPScanner = false
                        guard let url = URL(string: scannedValue),
                              OTPAuthSetupRequest.parse(url) != nil else {
                            totpScanError = "This QR code is not a valid TOTP authenticator setup."
                            return
                        }
                        totpSecret = scannedValue
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan Authenticator Code")
                    .vaultNavigationTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { showingTOTPScanner = false }
                                .tint(nil)
                        }
                    }
                }
                .vaultSheetSize(width: 460, height: 340)
            }
            .alert(
                "Unable to Scan Code",
                isPresented: Binding(
                    get: { totpScanError != nil },
                    set: { if !$0 { totpScanError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { totpScanError = nil }
            } message: {
                Text(totpScanError ?? "Please try again.")
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            #endif
            .onAppear {
                // Taken once, from the values the editor opened with.
                if baseline == nil { baseline = editableSnapshot(for: draftItem) }
                if passwordSuggestion.isEmpty { refreshSuggestion(for: .loginPassword) }
                if usernameSuggestion.isEmpty { refreshSuggestion(for: .loginUsername) }
            }
            .onDisappear { clearSSHDraft() }
            .onChange(of: store.isLocked) { _, locked in
                if locked { clearSSHDraft() }
            }
            .onChange(of: store.authenticatedSession?.tokenReference) { _, _ in clearSSHDraft() }
            .onChange(of: type) { oldType, newType in
                if oldType == .sshKey || newType == .sshKey { clearSSHDraft(force: true) }
            }
            .onChange(of: focusedCredentialField) { oldValue, newValue in
                guard let newValue,
                      newValue.supportsGeneratorSuggestion,
                      newValue != oldValue else { return }
                refreshSuggestion(for: newValue)
            }
    }

    // MARK: Login

    @ViewBuilder
    private var loginSections: some View {
        Section {
            ForEach($websiteURIs) { $website in
                HStack(alignment: .bottom, spacing: 12) {
                    LabeledFormField(
                        "Website",
                        text: $website.value,
                        placeholder: "example.com",
                        keyboardType: .URL,
                        capitalization: .never,
                        autocorrectionDisabled: true
                    )

                    if websiteURIs.count > 1 {
                        Button(role: .destructive) {
                            websiteURIs.removeAll { $0.id == website.id }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove Website")
                        .padding(.bottom, 2)
                    }
                }
            }

            Button {
                websiteURIs.append(EditableWebsiteURI(value: ""))
            } label: {
                Label("Add Website", systemImage: "plus.circle")
            }
        } header: {
            Text("Websites")
        } footer: {
            if hasInvalidWebsite {
                Text("Websites can’t contain spaces.")
                    .foregroundStyle(.red)
            }
        }

        Section {
            LabeledFormField(
                "User Name",
                text: $username,
                focusBinding: $focusedCredentialField,
                focusValue: .loginUsername,
                textContentType: .oneTimeCode,
                capitalization: .never,
                autocorrectionDisabled: true
            )
            if canEditSecrets {
                LabeledFormField(
                    "Password",
                    text: $password,
                    isSecure: true,
                    showsRevealButton: true,
                    focusBinding: $focusedCredentialField,
                    focusValue: .loginPassword,
                    textContentType: .oneTimeCode,
                    capitalization: .never,
                    autocorrectionDisabled: true
                )
                if password.isEmpty {
                    Button("Use Strong Password", systemImage: "key.fill", action: useStrongPassword)
                }
            } else {
                LabeledContent("Password", value: VaultDetailField.mask)
            }
        }

        if canEditSecrets {
            Section {
                LabeledFormField(
                    "Setup Key",
                    text: $totpSecret,
                    placeholder: "Optional",
                    capitalization: .characters,
                    autocorrectionDisabled: true
                )
                Button(action: scanSetupCode) {
                    #if os(macOS)
                    Label("Import QR Code…", systemImage: "qrcode")
                    #else
                    Label("Scan QR Code", systemImage: "qrcode.viewfinder")
                    #endif
                }
            } header: {
                Text("Verification Code")
            } footer: {
                if hasInvalidSetupKey {
                    Text("This setup key isn’t valid.")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: Attachments

    private var attachmentsSection: some View {
        Section("Attachments") {
            if let existingItem {
                ForEach((existingItem.attachments ?? []).filter { !removedAttachmentIDs.contains($0.id) }) { attachment in
                    let isMarked = attachmentsMarkedForRemoval.contains(attachment.id)
                    HStack(spacing: 12) {
                        Image(systemName: "doc")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(attachment.fileName)
                                .strikethrough(isMarked)
                            Text(isMarked ? L10n.string("Removed when you save") : attachment.formattedSize)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Button {
                            if isMarked {
                                attachmentsMarkedForRemoval.remove(attachment.id)
                            } else {
                                attachmentsMarkedForRemoval.insert(attachment.id)
                            }
                        } label: {
                            Image(systemName: isMarked ? "arrow.uturn.backward.circle.fill" : "minus.circle.fill")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(isMarked ? Color.accentColor : Color.red)
                        .accessibilityLabel(isMarked
                                            ? L10n.format("Keep %@", attachment.fileName)
                                            : L10n.format("Remove %@", attachment.fileName))
                    }
                }
                ForEach(pendingAttachments) { attachment in
                    HStack {
                        Label(attachment.fileName, systemImage: "doc")
                        Spacer()
                        Text(attachment.formattedSize).foregroundStyle(.secondary)
                        Button(role: .destructive) {
                            try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
                            pendingAttachments.removeAll { $0.id == attachment.id }
                        } label: { Image(systemName: "minus.circle.fill") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(L10n.format("Remove %@", attachment.fileName))
                    }
                }
                Menu {
                    Button { showingAttachmentImporter = true } label: {
                        Label("Files", systemImage: "folder")
                    }
                    Button { showingAttachmentPhotos = true } label: {
                        Label("Photos", systemImage: "photo.on.rectangle")
                    }
                } label: {
                    Label("Add Attachment", systemImage: "paperclip")
                }
            } else {
                Text("Attachments can be added after saving.")
                    .foregroundStyle(.secondary)
            }
            if let attachmentError {
                Text(attachmentError).foregroundStyle(.red)
            }
        }
    }

    // MARK: Validation

    /// Collections that hide passwords keep them out of the editor too.
    private var canEditSecrets: Bool {
        guard let existingItem else { return true }
        return store.canRevealSecrets(of: existingItem)
    }

    /// An untitled login is named after its website, as Passwords does.
    private var suggestedName: String? {
        websiteURIs.lazy.compactMap { VaultWebsiteInput.suggestedName(for: $0.value) }.first
    }

    private var resolvedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty || type != .login { return trimmed }
        return suggestedName ?? ""
    }

    private var hasInvalidWebsite: Bool {
        type == .login && websiteURIs.contains { VaultWebsiteInput.normalize($0.value) == .invalid }
    }

    /// Only a key the person typed here is checked, so an existing secret in a
    /// format this app can't read (for example Steam's) never blocks a save.
    private var hasInvalidSetupKey: Bool {
        let trimmed = totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard type == .login, !trimmed.isEmpty,
              trimmed != (existingItem?.totpSecret ?? "") else { return false }
        if trimmed.lowercased().hasPrefix("steam://") { return false }
        return TOTPGenerator.code(secret: trimmed) == nil
    }

    private var hasInvalidExpirationMonth: Bool {
        guard type == .card else { return false }
        let month = card.expirationMonth.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !month.isEmpty else { return false }
        guard let value = Int(month) else { return true }
        return !(1...12).contains(value)
    }

    private var canSave: Bool {
        !isSaving && !store.isLocked && store.authenticatedSession != nil
            && !resolvedName.isEmpty
            && !(type == .sshKey && (password.isEmpty || username.isEmpty))
            && !hasInvalidWebsite && !hasInvalidSetupKey && !hasInvalidExpirationMonth
    }

    /// True when cancelling would lose something the person typed or chose.
    private var hasChanges: Bool {
        guard let baseline else { return false }
        return !pendingAttachments.isEmpty || !attachmentsMarkedForRemoval.isEmpty
            || editableSnapshot(for: draftItem) != baseline
    }

    private func cancel() {
        if hasChanges {
            showingDiscardConfirmation = true
        } else {
            finish()
        }
    }

    private func useStrongPassword() {
        if passwordSuggestion.isEmpty { refreshSuggestion(for: .loginPassword) }
        password = passwordSuggestion
    }

    private func scanSetupCode() {
        #if os(iOS)
        guard DataScannerViewController.isSupported,
              DataScannerViewController.isAvailable else {
            totpScanError = L10n.string("This device can’t scan QR codes.")
            return
        }
        #endif
        showingTOTPScanner = true
    }

    private var showsCredentialSuggestions: Bool {
        #if os(macOS)
        activeCredentialField != nil
        #else
        isKeyboardVisible
        #endif
    }

    private var navigationTitleText: String {
        switch presentation {
        case .inline: ""
        case .sheet: L10n.string(existingID == nil ? "New Item" : "Edit Item")
        }
    }

    private var activeCredentialField: AddEditCredentialField? {
        switch focusedCredentialField {
        case .loginUsername, .loginPassword, .identityUsername:
            focusedCredentialField
        case .nonCredential, nil:
            nil
        }
    }

    private func presentGenerator(for field: AddEditCredentialField) {
        focusedCredentialField = nil
        switch field {
        case .nonCredential:
            return
        case .loginPassword:
            showingGenerator = true
        case .loginUsername, .identityUsername:
            showingUsernameGenerator = true
        }
    }

    private func suggestion(for field: AddEditCredentialField) -> String {
        switch field {
        case .nonCredential:
            ""
        case .loginPassword:
            passwordSuggestion
        case .loginUsername, .identityUsername:
            usernameSuggestion
        }
    }

    private func refreshSuggestion(for field: AddEditCredentialField) {
        switch field {
        case .nonCredential:
            return
        case .loginPassword:
            passwordSuggestion = SecretGenerator.password(SecretGenerator.PasswordOptions())
        case .loginUsername, .identityUsername:
            usernameSuggestion = PasswordGenerator.username()
        }
    }

    private func useSuggestion(for field: AddEditCredentialField) {
        switch field {
        case .nonCredential:
            return
        case .loginPassword:
            password = passwordSuggestion
        case .loginUsername:
            username = usernameSuggestion
        case .identityUsername:
            identity.username = usernameSuggestion
        }
    }

    private func clearSSHDraft(force: Bool = false) {
        guard force || type == .sshKey else { return }
        password = ""
        username = ""
        sshKeyFingerprint = ""
    }

    /// Inline hosts hand control back instead of dismissing a presentation.
    private func finish() {
        clearSSHDraft()
        for attachment in pendingAttachments {
            try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
        }
        pendingAttachments = []
        if let onFinish {
            onFinish()
        } else {
            dismiss()
        }
    }

    private var cardForm: some View {
        Group {
            Section("Card Details") {
                LabeledFormField("Cardholder Name", text: $card.cardholderName, placeholder: "Name on card", textContentType: .name)
                Picker("Brand", selection: $card.brand) {
                    ForEach(cardBrandOptions, id: \.self) { brand in
                        Text(brand.isEmpty ? "Select Brand" : brand).tag(brand)
                    }
                }
                LabeledFormField(
                    "Card Number",
                    text: $card.number,
                    placeholder: "Enter card number",
                    keyboardType: .numberPad,
                    textContentType: .creditCardNumber
                )
                LabeledFormField(
                    "Security Code",
                    text: $card.securityCode,
                    placeholder: "CVV / CVC",
                    isSecure: true,
                    keyboardType: .numberPad
                )
            }

            Section {
                HStack {
                    LabeledFormField("Month", text: $card.expirationMonth, placeholder: "MM", keyboardType: .numberPad)
                    Divider()
                    LabeledFormField("Year", text: $card.expirationYear, placeholder: "YYYY", keyboardType: .numberPad)
                }
                HStack {
                    LabeledFormField("Valid From Month", text: $card.validFromMonth, placeholder: "MM", keyboardType: .numberPad)
                    Divider()
                    LabeledFormField("Valid From Year", text: $card.validFromYear, placeholder: "YYYY", keyboardType: .numberPad)
                }
            } header: {
                Text("Expiration")
            } footer: {
                if hasInvalidExpirationMonth {
                    Text("Enter a month from 1 to 12.")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private var cardBrandOptions: [String] {
        var values = [
            "",
            "Visa",
            "Mastercard",
            "American Express",
            "Discover",
            "Diners Club",
            "JCB",
            "Maestro",
            "UnionPay",
            "RuPay",
            "Other"
        ]
        let existingBrand = card.brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingBrand.isEmpty, !values.contains(existingBrand) {
            values.insert(existingBrand, at: values.count - 1)
        }
        return values
    }

    private var identityForm: some View {
        Group {
            Section("Personal Information") {
                Picker("Title", selection: $identity.title) {
                    ForEach(identityTitleOptions, id: \.self) { title in
                        Text(title.isEmpty ? "Select Title" : title).tag(title)
                    }
                }
                LabeledFormField("First Name", text: $identity.firstName, placeholder: "Enter first name", textContentType: .givenName)
                LabeledFormField("Middle Name", text: $identity.middleName, placeholder: "Optional", textContentType: .middleName)
                LabeledFormField("Last Name", text: $identity.lastName, placeholder: "Enter last name", textContentType: .familyName)
                LabeledFormField(
                    "User Name",
                    text: $identity.username,
                    focusBinding: $focusedCredentialField,
                    focusValue: .identityUsername,
                    textContentType: .oneTimeCode,
                    capitalization: .never,
                    autocorrectionDisabled: true
                )
                LabeledFormField("Company", text: $identity.company, placeholder: "Enter company", textContentType: .organizationName)
            }

            Section("Contact") {
                LabeledFormField(
                    "Email",
                    text: $identity.email,
                    placeholder: "name@example.com",
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    capitalization: .never
                )
                LabeledFormField("Phone", text: $identity.phone, placeholder: "Enter phone number", keyboardType: .phonePad, textContentType: .telephoneNumber)
            }

            Section("Identification") {
                LabeledFormField("Social Security Number", text: $identity.socialSecurityNumber, placeholder: "Enter number", isSecure: true)
                LabeledFormField("Passport Number", text: $identity.passportNumber, placeholder: "Enter passport number", capitalization: .characters)
                LabeledFormField("License Number", text: $identity.licenseNumber, placeholder: "Enter license number", capitalization: .characters)
            }

            Section("Address") {
                LabeledFormField("Address Line 1", text: $identity.address1, placeholder: "Street address", textContentType: .streetAddressLine1)
                LabeledFormField("Address Line 2", text: $identity.address2, placeholder: "Apartment, suite, etc.", textContentType: .streetAddressLine2)
                LabeledFormField("City", text: $identity.city, placeholder: "Enter city", textContentType: .addressCity)
                LabeledFormField("State / Province", text: $identity.state, placeholder: "Enter state or province", textContentType: .addressState)
                LabeledFormField("Postal Code", text: $identity.postalCode, placeholder: "Enter postal code", textContentType: .postalCode)
                LabeledFormField("Country", text: $identity.country, placeholder: "Enter country", textContentType: .countryName)
            }
        }
    }

    private var identityTitleOptions: [String] {
        var values = ["", "Mr", "Mrs", "Ms", "Miss", "Dr", "Prof", "Mx"]
        let existingTitle = identity.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !existingTitle.isEmpty, !values.contains(existingTitle) {
            values.append(existingTitle)
        }
        return values
    }

    private var customFieldsEditor: some View {
        Section("Custom Fields") {
            ForEach($customFields) { $field in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        #if os(macOS)
                        if customFields.count > 1 {
                            Image(systemName: "line.3.horizontal")
                                .foregroundStyle(.secondary)
                                .draggable(field.id.uuidString)
                                .accessibilityLabel("Drag to reorder field")
                        }
                        #endif
                        Image(systemName: field.type.icon)
                            .foregroundStyle(Color.vaultBlue)
                            .frame(width: 24)
                        LabeledFormField("Field Name", text: $field.name, placeholder: "Enter a label")
                        Menu {
                            Picker("Field type", selection: $field.type) {
                                ForEach(VaultCustomFieldType.allCases) { type in
                                    Label(type.localizedTitle, systemImage: type.icon).tag(type)
                                }
                            }
                        } label: {
                            Text(field.type.localizedTitle)
                                .font(.caption.weight(.semibold))
                        }
                    }

                    switch field.type {
                    case .text:
                        LabeledFormField("Value", text: $field.value, placeholder: "Enter value")
                    case .hidden:
                        LabeledFormField("Value", text: $field.value, placeholder: "Enter hidden value", isSecure: true)
                    case .boolean:
                        Toggle("Enabled", isOn: booleanBinding(for: $field.value))
                    case .linked:
                        Picker("Linked value", selection: $field.value) {
                            Text("Username").tag("username")
                            Text("Password").tag("password")
                        }
                        .pickerStyle(.segmented)
                    }

                    Button("Remove Field", role: .destructive) {
                        customFields.removeAll { $0.id == field.id }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 6)
                .moveDisabled(customFields.count < 2)
                #if os(macOS)
                .dropDestination(for: String.self) { draggedIDs, _ in
                    guard let draggedID = draggedIDs.first.flatMap(UUID.init(uuidString:)) else { return false }
                    return moveCustomField(draggedID, to: field.id)
                }
                #endif
            }
            #if os(iOS)
            .onMove { offsets, destination in
                customFields.move(fromOffsets: offsets, toOffset: destination)
            }
            #endif

            Button {
                customFields.append(VaultCustomField())
            } label: {
                Label("Add Custom Field", systemImage: "plus.circle.fill")
            }
        }
    }

    #if os(macOS)
    private func moveCustomField(_ draggedID: UUID, to targetID: UUID) -> Bool {
        guard let source = customFields.firstIndex(where: { $0.id == draggedID }),
              let target = customFields.firstIndex(where: { $0.id == targetID }),
              source != target else { return false }
        customFields.move(fromOffsets: IndexSet(integer: source), toOffset: source < target ? target + 1 : target)
        return true
    }
    #endif

    private func booleanBinding(for value: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue == "true" },
            set: { value.wrappedValue = $0 ? "true" : "false" }
        )
    }

    private var draftItem: VaultItem {
        var item = existingItem ?? VaultItem(name: name)
        let normalizedURIs: [String] = websiteURIs.compactMap { entry -> String? in
            switch VaultWebsiteInput.normalize(entry.value) {
            case let .valid(value):
                return value
            case .empty:
                return nil
            case .invalid:
                // Kept as typed; Save stays disabled until it's fixed.
                return entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        item.name = resolvedName
        item.username = username
        item.password = password
        item.uri = normalizedURIs.first ?? ""
        item.additionalURIs = normalizedURIs.count > 1 ? Array(normalizedURIs.dropFirst()) : nil
        item.type = type
        item.folder = folder.isEmpty ? nil : folder
        item.notes = notes
        item.sshKeyFingerprint = type == .sshKey ? sshKeyFingerprint : nil
        item.isFavorite = isFavorite
        let trimmedSecret = totpSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        item.totpSecret = trimmedSecret.isEmpty ? nil : trimmedSecret
        item.card = type == .card ? card : nil
        item.identity = type == .identity ? identity : nil
        item.customFields = customFields.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let existingID { item.id = existingID }
        return item
    }

    private func editableSnapshot(for item: VaultItem) -> EditableSnapshot {
        EditableSnapshot(
            name: item.name.trimmingCharacters(in: .whitespacesAndNewlines),
            username: item.username,
            password: item.password,
            uris: item.websiteURIs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty },
            type: item.type,
            folder: item.folder?.isEmpty == false ? item.folder : nil,
            notes: item.notes,
            sshKeyFingerprint: item.sshKeyFingerprint,
            isFavorite: item.isFavorite,
            totpSecret: item.totpSecret?.isEmpty == false ? item.totpSecret : nil,
            card: item.type == .card ? (item.card ?? CardDetails()) : nil,
            identity: item.type == .identity ? (item.identity ?? IdentityDetails()) : nil,
            customFields: item.customFields.filter {
                !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        )
    }

    private func save() async {
        guard canSave else { return }
        let item = draftItem
        if let existingItem,
           pendingAttachments.isEmpty,
           attachmentsMarkedForRemoval.isEmpty,
           editableSnapshot(for: item) == editableSnapshot(for: existingItem) {
            finish()
            return
        }

        isSaving = true
        defer { isSaving = false }
        let needsCipherSave = existingItem.map {
            editableSnapshot(for: item) != editableSnapshot(for: $0)
        } ?? true
        if needsCipherSave {
            guard await store.save(item) else {
                saveError = store.userFacingNotice ?? store.lastSyncError ?? L10n.string("Please try again.")
                store.userFacingNotice = nil
                return
            }
        }
        for attachment in existingItem?.attachments ?? []
        where attachmentsMarkedForRemoval.contains(attachment.id) {
            guard await store.removeAttachment(attachment, from: item.id) else { return }
            attachmentsMarkedForRemoval.remove(attachment.id)
            removedAttachmentIDs.insert(attachment.id)
        }
        for attachment in pendingAttachments {
            guard await store.addAttachment(
                to: item.id, fileURL: attachment.url, fileName: attachment.fileName
            ) else { return }
            try? FileManager.default.removeItem(at: attachment.url.deletingLastPathComponent())
            pendingAttachments.removeAll { $0.id == attachment.id }
        }
        finish()
    }

    private func stageAttachment(_ url: URL) {
        Task {
            do {
                let staged = try await Task.detached(priority: .userInitiated) {
                    try VaultAttachmentStager.stage(fileAt: url)
                }.value
                pendingAttachments.append(staged)
                attachmentError = nil
            } catch {
                attachmentError = error.localizedDescription
            }
        }
    }
}
