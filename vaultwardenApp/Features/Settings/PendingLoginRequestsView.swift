import SwiftUI

/// Sign-ins started on other devices that are waiting for this one to approve them.
struct PendingLoginRequestsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var requests: [PendingLoginRequest] = []
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var processingIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var pendingDenial: PendingLoginRequest?
    @State private var approvalRequest: PendingLoginRequest?
    /// Counts approvals made here, so the haptic answers the person's own action.
    @State private var approvals = 0

    var body: some View {
        Form {
            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: SettingsSpacing.standard) {
                        StatusTone.failure.apply(to: Text("Couldn’t Load Requests"))
                            .font(.headline)
                        Text(verbatim: errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await loadRequests() }
                        }
                        .disabled(isLoading)
                    }
                    .padding(.vertical, SettingsSpacing.tight)
                }
            }

            if requests.isEmpty {
                if isLoading || hasLoaded == false {
                    Section {
                        HStack(spacing: SettingsSpacing.row) {
                            ProgressView().controlSize(.small)
                            Text("Checking for Requests…")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, SettingsSpacing.section)
                    }
                } else if errorMessage == nil {
                    Section {
                        ContentUnavailableView(
                            "No Login Requests",
                            systemImage: "checkmark.shield",
                            description: Text("When you sign in on another device and choose to approve it here, the request appears on this page.")
                        )
                    }
                }
            } else {
                Section {
                    ForEach(requests) { request in
                        LoginRequestRow(
                            request: request,
                            isProcessing: processingIDs.contains(request.id),
                            onDeny: { pendingDenial = request },
                            onApprove: { approvalRequest = request }
                        )
                    }
                } header: {
                    Text(verbatim: SettingsWords.inflected("^[\(requests.count) Request](inflect: true)"))
                } footer: {
                    Text("Approve only a sign-in you started yourself, and only if its fingerprint phrase matches the one on that device.")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Login Requests")
        .vaultNavigationTitleDisplayMode(.inline)
        .animation(SettingsMotion.row, value: requests.map(\.id))
        .refreshable { await loadRequests() }
        .toolbar {
            ToolbarItem(placement: .vaultTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await loadRequests() }
                }
                .disabled(isLoading)
                .help("Check for new requests")
            }
        }
        .task { await loadRequests() }
        .sensoryFeedback(.success, trigger: approvals) { _, _ in store.settings.haptics }
        .sheet(item: $approvalRequest) { request in
            LoginRequestApprovalSheet(request: request) {
                requests.removeAll { $0.id == request.id }
                approvals += 1
            }
            .environmentObject(store)
        }
        .confirmationDialog(
            L10n.string("Deny This Sign-In?"),
            isPresented: Binding(
                get: { pendingDenial != nil },
                set: { if $0 == false { pendingDenial = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingDenial
        ) { request in
            Button("Deny Sign-In", role: .destructive) { respond(to: request, approved: false) }
            Button("Cancel", role: .cancel) {}
        } message: { request in
            Text("The \(request.deviceType) waiting to sign in won’t get access to your vault.")
        }
    }

    private func loadRequests() async {
        guard isLoading == false else { return }
        isLoading = true
        defer {
            isLoading = false
            hasLoaded = true
        }
        do {
            requests = try await store.loadPendingLoginRequests()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = L10n.string("Check your connection, then try again.")
            SecureLog.failure("Login request load", error: error, logger: SecureLog.security)
        }
    }

    private func respond(to request: PendingLoginRequest, approved: Bool) {
        processingIDs.insert(request.id)
        Task {
            defer { processingIDs.remove(request.id) }
            do {
                try await store.respondToLoginRequest(request, approved: approved)
                requests.removeAll { $0.id == request.id }
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

/// One waiting sign-in: the device, when and where it asked, its phrase, and the choice.
private struct LoginRequestRow: View {
    let request: PendingLoginRequest
    let isProcessing: Bool
    let onDeny: () -> Void
    let onApprove: () -> Void

    private var hasPhrase: Bool {
        request.fingerprintPhrase?.isEmpty == false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsSpacing.row) {
            HStack(spacing: SettingsSpacing.row) {
                SettingsIconTile(systemImage: Self.deviceIcon(for: request.deviceType), color: .blue, baseSide: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: request.deviceType)
                        .font(.headline)
                    Text(verbatim: facts)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isProcessing {
                    ProgressView().controlSize(.small)
                }
            }

            if let phrase = request.fingerprintPhrase, phrase.isEmpty == false {
                VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                    Text("Fingerprint Phrase")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: phrase)
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            } else {
                StatusTone.failure.apply(to: Text("This request has no fingerprint phrase, so it can’t be approved."))
                    .font(.footnote)
            }

            HStack(spacing: SettingsSpacing.standard) {
                Button(role: .destructive, action: onDeny) {
                    Text("Deny…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button(action: onApprove) {
                    Text("Approve…").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(hasPhrase == false)
            }
            .controlSize(.large)
            .disabled(isProcessing)
        }
        .padding(.vertical, SettingsSpacing.standard)
    }

    /// "2 minutes ago · 203.0.113.4 · vault.example.com"
    private var facts: String {
        var parts = [request.creationDate.formatted(.relative(presentation: .named))]
        if request.ipAddress.isEmpty == false { parts.append(request.ipAddress) }
        if let origin = request.origin, origin.isEmpty == false {
            parts.append(SettingsWords.serverHost(origin))
        }
        return parts.joined(separator: " · ")
    }

    private static func deviceIcon(for type: String) -> String {
        let value = type.lowercased()
        if value.contains("ios") || value.contains("iphone") || value.contains("android") {
            return "iphone"
        }
        if value.contains("desktop") || value.contains("windows") || value.contains("macos") || value.contains("linux") {
            return "desktopcomputer"
        }
        if value.contains("cli") {
            return "terminal.fill"
        }
        if value.contains("safari") {
            return "safari.fill"
        }
        if value.contains("browser") || value.contains("chrome") || value.contains("firefox") || value.contains("edge") || value.contains("opera") {
            return "globe"
        }
        return "laptopcomputer"
    }
}

/// Confirms the phrase matches, then asks who you are before approving.
private struct LoginRequestApprovalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: PendingLoginRequest
    let onApproved: () -> Void
    @State private var phraseMatches = false
    @State private var masterPassword = ""
    @State private var isApproving = false
    @State private var errorMessage: String?
    @FocusState private var isPasswordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(verbatim: request.fingerprintPhrase ?? "")
                        .font(.title3.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LabeledContent("Device") { Text(verbatim: request.deviceType) }
                    if request.ipAddress.isEmpty == false {
                        LabeledContent("IP Address") { Text(verbatim: request.ipAddress) }
                    }
                    Toggle("The Phrases Match", isOn: $phraseMatches)
                } header: {
                    Text("Fingerprint Phrase")
                } footer: {
                    Text("It must match the phrase on the device asking to sign in, word for word. If it doesn’t, cancel and deny the request.")
                }

                Section {
                    if store.settings.biometricUnlock {
                        Button {
                            approve(usingMasterPassword: false)
                        } label: {
                            Label(
                                L10n.format("Approve with %@", BiometricAuthenticator.displayName),
                                systemImage: BiometricAuthenticator.systemImage
                            )
                        }
                        .disabled(phraseMatches == false || isApproving)
                    }
                    SecureField("Master Password", text: $masterPassword)
                        .vaultTextContentType(.password)
                        .focused($isPasswordFocused)
                        .submitLabel(.done)
                        .onSubmit { approve(usingMasterPassword: true) }
                    Button("Approve with Master Password") { approve(usingMasterPassword: true) }
                        .disabled(phraseMatches == false || masterPassword.isEmpty || isApproving)
                } header: {
                    Text("Confirm It’s You")
                } footer: {
                    if let errorMessage {
                        StatusTone.failure.apply(to: Text(verbatim: errorMessage))
                    } else if isApproving {
                        Text("Approving…")
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Approve Sign-In")
            .vaultNavigationTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isApproving)
                }
            }
        }
        .interactiveDismissDisabled(isApproving)
        .onChange(of: store.isLocked) { _, locked in
            if locked { masterPassword = ""; dismiss() }
        }
        .onDisappear { masterPassword = "" }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 480)
        #endif
    }

    private func approve(usingMasterPassword: Bool) {
        guard phraseMatches, isApproving == false,
              usingMasterPassword == false || masterPassword.isEmpty == false else { return }
        isApproving = true
        errorMessage = nil
        let password = usingMasterPassword ? masterPassword : nil
        masterPassword = ""
        Task {
            defer { isApproving = false }
            do {
                try await store.respondToLoginRequest(
                    request, approved: true, fingerprintVerified: phraseMatches, masterPassword: password
                )
                onApproved()
                dismiss()
            } catch is CancellationError {
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                if usingMasterPassword { isPasswordFocused = true }
            }
        }
    }
}
