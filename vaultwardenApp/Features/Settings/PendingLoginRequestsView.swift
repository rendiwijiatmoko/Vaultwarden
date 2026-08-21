import SwiftUI

struct PendingLoginRequestsView: View {
    @EnvironmentObject private var store: AppStore

    @State private var requests: [PendingLoginRequest] = []
    @State private var isLoading = false
    @State private var processingIDs: Set<String> = []
    @State private var errorMessage: String?
    @State private var confirmation: Confirmation?

    private struct Confirmation: Identifiable {
        enum Action {
            case approve
            case reject
        }

        let request: PendingLoginRequest
        let action: Action
        var id: String { "\(request.id)-\(action)" }
    }

    var body: some View {
        List {
            Section {
                Label {
                    Text("Only approve a request you started on another device. Check the device and IP address before continuing.")
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
        .toolbarTitleDisplayMode(.inlineLarge)
        .refreshable { await loadRequests() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
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
                .accessibilityLabel("Refresh login requests")
            }
        }
        .task { await loadRequests() }
        .alert(item: $confirmation) { confirmation in
            switch confirmation.action {
            case .approve:
                Alert(
                    title: Text("Approve Login Request?"),
                    message: Text(L10n.format(
                        "This gives %@ access to your encrypted vault. Only continue if you started this login.",
                        confirmation.request.deviceType
                    )),
                    primaryButton: .default(Text("Approve")) {
                        respond(to: confirmation.request, approved: true)
                    },
                    secondaryButton: .cancel()
                )
            case .reject:
                Alert(
                    title: Text("Reject Login Request?"),
                    message: Text(L10n.format(
                        "The pending request from %@ will be denied.",
                        confirmation.request.deviceType
                    )),
                    primaryButton: .destructive(Text("Reject")) {
                        respond(to: confirmation.request, approved: false)
                    },
                    secondaryButton: .cancel()
                )
            }
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

            HStack(spacing: 10) {
                Button(role: .destructive) {
                    confirmation = Confirmation(request: request, action: .reject)
                } label: {
                    Text("Reject")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    confirmation = Confirmation(request: request, action: .approve)
                } label: {
                    Text("Approve")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
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
