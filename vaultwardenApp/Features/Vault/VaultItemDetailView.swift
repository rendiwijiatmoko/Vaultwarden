import SwiftUI
import UniformTypeIdentifiers

struct VaultAttachmentDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// A group of fields: a grouped section on iPhone, a titled card on the Mac.
struct VaultDetailGroup<Content: View, Footer: View>: View {
    var title: String?
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        #if os(macOS)
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Text(title)
                    .font(.headline)
                    .padding(.leading, 4)
            }
            MacDetailCard { content }
            footer
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
        #else
        Section {
            content
        } header: {
            if let title { Text(title) }
        } footer: {
            footer
        }
        #endif
    }
}

extension VaultDetailGroup where Footer == EmptyView {
    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
        self.footer = EmptyView()
    }
}

/// An item's page, as Passwords lays it out: the tile and name, then the fields
/// in the order people reach for them, then notes and the rest.
struct VaultItemDetailView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    let itemID: UUID
    @StateObject private var actions = VaultItemActionModel()
    @State private var isEditing = false
    @State private var exportedAttachment: VaultAttachmentDocument?
    @State private var exportedFileName = "Attachment"
    @State private var exportedContentType: UTType = .data
    @State private var showingAttachmentExporter = false
    @State private var downloadingAttachmentID: String?

    private var item: VaultItem? { store.items.first { $0.id == itemID } }

    var body: some View {
        Group {
            if let item, isEditing {
                // Editing happens on this screen rather than in a sheet. The
                // `.id` keeps the editor's field state tied to the item.
                AddEditVaultItemView(
                    existingItem: item,
                    presentation: .inline,
                    onFinish: { withAnimation(VaultMotion.fade) { isEditing = false } }
                )
                .id(item.id)
                .transition(.opacity)
                // Suppresses both the back chevron and the swipe-to-pop gesture,
                // which would otherwise abandon the edit without asking.
                .navigationBarBackButtonHidden(true)
            } else if let item {
                page(for: item, permissions: VaultItemPermissions(item: item, store: store))
            } else {
                ContentUnavailableView("Item Unavailable", systemImage: "questionmark.folder")
            }
        }
        .vaultItemActions(actions)
        .onChange(of: item == nil) { _, isMissing in
            guard isMissing else { return }
            isEditing = false
            leaveIfStacked()
        }
        .fileExporter(
            isPresented: $showingAttachmentExporter,
            document: exportedAttachment,
            contentType: exportedContentType,
            defaultFilename: exportedFileName
        ) { result in
            if case .failure = result {
                store.userFacingNotice = L10n.string("The attachment couldn’t be saved. Try again.")
            }
            exportedAttachment = nil
        }
    }

    // MARK: Page

    @ViewBuilder
    private func page(for item: VaultItem, permissions: VaultItemPermissions) -> some View {
        #if os(macOS)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header(item, iconSize: 56)
                    .padding(.horizontal, 4)
                groups(for: item, permissions: permissions)
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle("")
        .toolbar { macToolbar(item, permissions: permissions) }
        #else
        List {
            Section {
                header(item, iconSize: 60)
                    .padding(.vertical, 4)
            }
            groups(for: item, permissions: permissions)
        }
        // The name is in the page header; the bar stays free for Edit, like Passwords.
        .navigationTitle("")
        .vaultNavigationTitleDisplayMode(.inline)
        .toolbar {
            if permissions.canEdit, !item.isDeleted {
                ToolbarItem(placement: .vaultTrailing) {
                    Button("Edit", action: beginEditing)
                        .tint(nil)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private func groups(for item: VaultItem, permissions: VaultItemPermissions) -> some View {
        Group {
            primaryGroup(item, permissions: permissions)
            websitesGroup(item)
            securityGroup(item, permissions: permissions)
            historyGroup(item, permissions: permissions)
        }
        Group {
            notesGroup(item)
            customFieldsGroup(item, permissions: permissions)
            attachmentsGroup(item)
            infoGroup(item)
            actionsGroup(item, permissions: permissions)
        }
    }

    private func header(_ item: VaultItem, iconSize: CGFloat) -> some View {
        HStack(spacing: 14) {
            VaultItemThumbnail(item: item, size: iconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                Text(L10n.format("Last modified %@", item.updatedAt.formatted(date: .abbreviated, time: .omitted)))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Fields

    @ViewBuilder
    private func primaryGroup(_ item: VaultItem, permissions: VaultItemPermissions) -> some View {
        switch item.type {
        case .login:
            if !item.username.isEmpty || !item.password.isEmpty || item.totpSecret != nil || item.passkeyCount > 0 {
                VaultDetailGroup {
                    if !item.username.isEmpty {
                        VaultDetailField(title: L10n.string("User Name"), value: item.username)
                    }
                    if !item.password.isEmpty {
                        VaultDetailField(
                            title: L10n.string("Password"),
                            value: item.password,
                            isSecret: true,
                            allowsAccess: permissions.canRevealSecrets
                        )
                    }
                    if let secret = item.totpSecret, !secret.isEmpty, permissions.canRevealSecrets {
                        VaultCodeField(secret: secret)
                    }
                    if item.passkeyCount > 0 {
                        LabeledContent {
                            if item.passkeyCount > 1 { Text(item.passkeyCount, format: .number) }
                        } label: {
                            Label("Passkey", systemImage: "person.badge.key.fill")
                        }
                    }
                }
            }
        case .card:
            if let card = item.card {
                cardGroups(card, permissions: permissions)
            }
        case .identity:
            if let identity = item.identity {
                identityGroups(identity, permissions: permissions)
            }
        case .sshKey:
            VaultDetailGroup(L10n.string("SSH Key")) {
                if !item.username.isEmpty {
                    VaultDetailField(title: L10n.string("Public Key"), value: item.username, isMonospaced: true)
                }
                if !item.displayedSSHFingerprint.isEmpty {
                    VaultDetailField(title: L10n.string("Fingerprint"), value: item.displayedSSHFingerprint, isMonospaced: true)
                }
                if !item.password.isEmpty {
                    VaultDetailField(
                        title: L10n.string("Private Key"),
                        value: item.password,
                        isSecret: true,
                        allowsAccess: permissions.canRevealSecrets
                    )
                }
            }
        case .secureNote:
            EmptyView()
        }
    }

    @ViewBuilder
    private func cardGroups(_ card: CardDetails, permissions: VaultItemPermissions) -> some View {
        VaultDetailGroup(L10n.string("Card")) {
            if !card.cardholderName.isEmpty {
                VaultDetailField(title: L10n.string("Cardholder Name"), value: card.cardholderName)
            }
            if !card.brand.isEmpty {
                VaultDetailField(title: L10n.string("Brand"), value: card.brand)
            }
            if !card.number.isEmpty {
                VaultDetailField(
                    title: L10n.string("Card Number"),
                    value: card.number,
                    isSecret: true,
                    maskedDisplay: card.maskedNumber == card.number ? nil : card.maskedNumber,
                    isMonospaced: true,
                    allowsAccess: permissions.canRevealSecrets
                )
            }
            if !card.securityCode.isEmpty {
                VaultDetailField(
                    title: L10n.string("Security Code"),
                    value: card.securityCode,
                    isSecret: true,
                    allowsAccess: permissions.canRevealSecrets
                )
            }
            if !card.expirationMonth.isEmpty || !card.expirationYear.isEmpty {
                VaultDetailField(title: L10n.string("Expires"), value: card.expirationDisplay)
            }
            let validFrom = [card.validFromMonth, card.validFromYear].filter { !$0.isEmpty }.joined(separator: "/")
            if !validFrom.isEmpty {
                VaultDetailField(title: L10n.string("Valid From"), value: validFrom)
            }
        }
    }

    @ViewBuilder
    private func identityGroups(_ identity: IdentityDetails, permissions: VaultItemPermissions) -> some View {
        let personal: [(String, String)] = [
            ("Name", identity.fullName), ("User Name", identity.username), ("Company", identity.company)
        ]
        let contact: [(String, String)] = [("Email", identity.email), ("Phone", identity.phone)]
        let address: [(String, String)] = [
            ("Address Line 1", identity.address1), ("Address Line 2", identity.address2),
            ("City", identity.city), ("State / Province", identity.state),
            ("Postal Code", identity.postalCode), ("Country", identity.country)
        ]

        identityGroup(nil, personal)
        identityGroup(L10n.string("Contact"), contact)
        if !identity.socialSecurityNumber.isEmpty || !identity.passportNumber.isEmpty || !identity.licenseNumber.isEmpty {
            VaultDetailGroup(L10n.string("Identification")) {
                ForEach(
                    [("Social Security Number", identity.socialSecurityNumber),
                     ("Passport Number", identity.passportNumber),
                     ("License Number", identity.licenseNumber)].filter { !$0.1.isEmpty },
                    id: \.0
                ) { field in
                    VaultDetailField(
                        title: L10n.string(field.0),
                        value: field.1,
                        isSecret: true,
                        allowsAccess: permissions.canRevealSecrets
                    )
                }
            }
        }
        identityGroup(L10n.string("Address"), address)
    }

    @ViewBuilder
    private func identityGroup(_ title: String?, _ fields: [(String, String)]) -> some View {
        let present = fields.filter { !$0.1.isEmpty }
        if !present.isEmpty {
            VaultDetailGroup(title) {
                ForEach(present, id: \.0) { field in
                    VaultDetailField(title: L10n.string(field.0), value: field.1)
                }
            }
        }
    }

    @ViewBuilder
    private func websitesGroup(_ item: VaultItem) -> some View {
        let websites = item.websiteURIs
        if item.type == .login, !websites.isEmpty {
            VaultDetailGroup(L10n.string(websites.count == 1 ? "Website" : "Websites")) {
                ForEach(Array(websites.enumerated()), id: \.offset) { index, uri in
                    VaultWebsiteField(
                        title: websites.count == 1 ? L10n.string("Website") : L10n.format("Website %lld", index + 1),
                        uri: uri,
                        url: item.websiteURL(for: uri)
                    )
                }
                if VaultSecurityIssue(risks: item.risks) == nil || item.isDeleted {
                    changePasswordButton(item)
                }
            }
        }
    }

    @ViewBuilder
    private func changePasswordButton(_ item: VaultItem) -> some View {
        if !item.password.isEmpty, !item.isDeleted, let url = VaultItemPresentation.changePasswordURL(for: item) {
            Link(destination: url) {
                Text("Change Password on Website")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func securityGroup(_ item: VaultItem, permissions: VaultItemPermissions) -> some View {
        if item.type == .login, !item.isDeleted, let issue = VaultSecurityIssue(risks: item.risks) {
            VaultDetailGroup {
                Label {
                    Text(issue.message)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: issue.symbol)
                        .foregroundStyle(issue.isUrgent ? Color.red : Color.orange)
                }
                changePasswordButton(item)
            }
        }
        if item.type == .login, !item.password.isEmpty, permissions.canRevealSecrets, !item.isDeleted {
            VaultDetailGroup(title: nil) {
                PasswordLeakCheckRow(password: item.password)
            } footer: {
                Text("Only part of the password’s hash leaves this device.")
            }
        }
    }

    @ViewBuilder
    private func historyGroup(_ item: VaultItem, permissions: VaultItemPermissions) -> some View {
        if let history = item.passwordHistory, !history.isEmpty {
            VaultDetailGroup(L10n.string("Password History")) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                    PasswordHistoryRow(entry: entry, canRevealSecrets: permissions.canRevealSecrets)
                }
            }
        }
    }

    @ViewBuilder
    private func notesGroup(_ item: VaultItem) -> some View {
        if !item.notes.isEmpty {
            VaultDetailGroup(L10n.string("Notes")) {
                Text(item.notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    #if os(macOS)
                    .padding(.vertical, 8)
                    #endif
            }
        }
    }

    @ViewBuilder
    private func customFieldsGroup(_ item: VaultItem, permissions: VaultItemPermissions) -> some View {
        if !item.customFields.isEmpty {
            VaultDetailGroup(L10n.string("Custom Fields")) {
                ForEach(item.customFields) { field in
                    CustomFieldDetailRow(field: field, item: item, canRevealSecrets: permissions.canRevealSecrets)
                }
            }
        }
    }

    @ViewBuilder
    private func attachmentsGroup(_ item: VaultItem) -> some View {
        if let attachments = item.attachments, !attachments.isEmpty {
            VaultDetailGroup(L10n.string("Attachments")) {
                ForEach(attachments) { attachment in
                    attachmentRow(attachment, itemID: item.id)
                }
            }
        }
    }

    @ViewBuilder
    private func infoGroup(_ item: VaultItem) -> some View {
        if item.folder != nil || item.organization != nil {
            VaultDetailGroup {
                if let folder = item.folder {
                    LabeledContent("Folder", value: folder)
                }
                if let organization = item.organization {
                    LabeledContent("Organization", value: organization)
                }
            }
        }
    }

    @ViewBuilder
    private func actionsGroup(_ item: VaultItem, permissions: VaultItemPermissions) -> some View {
        VaultDetailGroup(title: nil) {
            if permissions.canEdit {
                if item.isDeleted {
                    Button("Restore") { actions.restore([item], store: store) }
                    Button("Delete Permanently", role: .destructive) {
                        actions.requestPermanentDeletion([item])
                    }
                } else {
                    Button(item.isArchived ? L10n.string("Unarchive") : L10n.string("Archive")) {
                        actions.archive([item], store: store)
                    }
                    Button("Delete", role: .destructive) { trash(item) }
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.format("Created %@", (item.createdAt ?? item.updatedAt).formatted(date: .abbreviated, time: .shortened)))
                if item.type == .login, let passwordUpdatedAt = item.passwordUpdatedAt {
                    Text(L10n.format("Password changed %@", passwordUpdatedAt.formatted(date: .abbreviated, time: .shortened)))
                }
            }
        }
        #if os(macOS)
        .buttonStyle(.borderless)
        #endif
    }

    private func attachmentRow(_ attachment: VaultAttachment, itemID: UUID) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "doc")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.fileName).lineLimit(2)
                Text(attachment.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button {
                download(attachment, itemID: itemID)
            } label: {
                if downloadingAttachmentID == attachment.id {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Save", systemImage: "arrow.down.circle")
                        .labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
            .disabled(downloadingAttachmentID != nil)
            .accessibilityLabel(L10n.format("Save %@", attachment.fileName))
            #if os(iOS)
            .frame(minWidth: 44, minHeight: 44)
            #endif
        }
    }

    #if os(macOS)
    @ToolbarContentBuilder
    private func macToolbar(_ item: VaultItem, permissions: VaultItemPermissions) -> some ToolbarContent {
        ToolbarItemGroup(placement: .automatic) {
            Menu {
                VaultItemMenu(item: item, actions: actions)
            } label: {
                Label("Item Actions", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .help("Item Actions")
            if permissions.canEdit, !item.isDeleted {
                Button("Edit", action: beginEditing)
                    .help("Edit")
            }
        }
    }
    #endif

    // MARK: Actions

    private func beginEditing() {
        withAnimation(VaultMotion.fade) { isEditing = true }
    }

    /// Deleted items can be restored, so this doesn't ask first.
    private func trash(_ item: VaultItem) {
        actions.trash([item], store: store)
        leaveIfStacked()
    }

    private func leaveIfStacked() {
        #if os(iOS)
        if horizontalSizeClass == .compact { dismiss() }
        #endif
    }

    private func download(_ attachment: VaultAttachment, itemID: UUID) {
        Task {
            downloadingAttachmentID = attachment.id
            defer { downloadingAttachmentID = nil }
            guard let url = await store.downloadAttachment(attachment, from: itemID) else { return }
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            do {
                exportedAttachment = VaultAttachmentDocument(data: try Data(contentsOf: url))
                exportedFileName = attachment.fileName
                exportedContentType = UTType(filenameExtension: url.pathExtension) ?? .data
                showingAttachmentExporter = true
            } catch {
                store.userFacingNotice = L10n.string("The attachment couldn’t be opened. Try again.")
            }
        }
    }
}
