import SwiftUI

struct PendingLoginRequestsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var requests: [PendingLoginRequest] = []
    @State private var isLoading = false
    @State private var processingIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var confirmation: PendingLoginRequest?
    @State private var approvalRequest: PendingLoginRequest?

    var body: some View {
        List {
            Section {
                Label {
                    Text("Only approve a request you started on another device. Compare the fingerprint phrase with the requesting device before continuing.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.blue)
                }
                .padding(.vertical, 5)
            }

            if let errorMessage {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Unable to load login requests", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.red)
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Try Again") {
                            Task { await loadRequests() }
                        }
                    }
                    .padding(.vertical, 5)
                }
            }

            if isLoading && requests.isEmpty {
                Section {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Checking for login requests…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
                }
            } else if requests.isEmpty && errorMessage == nil {
                Section {
                    ContentUnavailableView(
                        "No Pending Requests",
                        systemImage: "person.badge.clock",
                        description: Text("New device login requests will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }
            } else if !requests.isEmpty {
                Section("Pending Requests") {
                    ForEach(requests) { request in
                        requestRow(request)
                    }
                }
            }
        }
        .navigationTitle("Login Requests")
        .vaultToolbarTitleDisplayMode(.inlineLarge)
        .refreshable { await loadRequests() }
        .toolbar {
            ToolbarItem(placement: .vaultTrailing) {
                Button {
                    Task { await loadRequests() }
                } label: {
                    if isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isLoading)
                .tint(nil)
                .accessibilityLabel("Refresh login requests")
            }
        }
        .task { await loadRequests() }
        .sheet(item: $approvalRequest) { request in
            LoginRequestApprovalSheet(request: request) {
                requests.removeAll { $0.id == request.id }
            }
            .environmentObject(store)
        }
        .alert(item: $confirmation) { request in
            Alert(
                title: Text("Reject Login Request?"),
                message: Text(L10n.format("The pending request from %@ will be denied.", request.deviceType)),
                primaryButton: .destructive(Text("Reject")) { respond(to: request, approved: false) },
                secondaryButton: .cancel()
            )
        }
    }

    @ViewBuilder
    private func requestRow(_ request: PendingLoginRequest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: deviceIcon(for: request.deviceType))
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .background(Color.vaultBlue.gradient, in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.deviceType)
                        .font(.headline)
                    Text(request.creationDate.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if processingIDs.contains(request.id) {
                    ProgressView()
                }
            }

            LabeledContent("IP Address", value: request.ipAddress)
                .font(.subheadline)

            if let origin = request.origin, !origin.isEmpty {
                LabeledContent("Server", value: origin)
                    .font(.subheadline)
                    .lineLimit(1)
            }

            if let phrase = request.fingerprintPhrase, !phrase.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Fingerprint Phrase").font(.caption).foregroundStyle(.secondary)
                    Text(phrase).font(.body.monospaced()).textSelection(.enabled)
                }
            } else {
                Text("The fingerprint phrase could not be generated. This request cannot be approved.")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    confirmation = request
                } label: {
                    Text("Reject")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    approvalRequest = request
                } label: {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(request.fingerprintPhrase?.isEmpty != false)
            }
            .disabled(processingIDs.contains(request.id))
        }
        .padding(.vertical, 7)
    }

    private func loadRequests() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            requests = try await store.loadPendingLoginRequests()
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
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

    private func deviceIcon(for type: String) -> String {
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

private struct LoginRequestApprovalSheet: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let request: PendingLoginRequest
    let onApproved: () -> Void
    @State private var phraseMatches = false
    @State private var masterPassword = ""
    @State private var isApproving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Verify Request") {
                    Text("Compare this phrase with the one on the device requesting access. Reject the request if they differ.")
                    Text(request.fingerprintPhrase ?? "")
                        .font(.body.monospaced()).textSelection(.enabled)
                    LabeledContent("Device", value: request.deviceType)
                    LabeledContent("IP Address", value: request.ipAddress)
                    Toggle("The fingerprint phrases match", isOn: $phraseMatches)
                }
                Section("Confirm Your Identity") {
                    if store.settings.biometricUnlock {
                        Button {
                            approve(usingMasterPassword: false)
                        } label: {
                            Label(L10n.format("Approve with %@", BiometricAuthenticator.displayName),
                                  systemImage: BiometricAuthenticator.systemImage)
                        }
                        .disabled(!phraseMatches || isApproving)
                    }
                    SecureField("Master Password", text: $masterPassword)
                        .textContentType(.password)
                        .onSubmit { approve(usingMasterPassword: true) }
                    Button("Approve with Master Password") { approve(usingMasterPassword: true) }
                        .disabled(!phraseMatches || masterPassword.isEmpty || isApproving)
                    if isApproving { ProgressView() }
                    if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Approve Login Request")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(isApproving)
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
        guard phraseMatches, !isApproving,
              !usingMasterPassword || !masterPassword.isEmpty else { return }
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
            }
        }
    }
}
