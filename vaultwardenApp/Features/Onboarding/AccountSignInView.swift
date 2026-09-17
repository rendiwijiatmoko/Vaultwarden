import SwiftUI

/// Authentication-only screen shown after an explicit logout.
/// Onboarding remains a first-install flow and cannot be reopened from Settings.
struct AccountSignInView: View {
    @EnvironmentObject private var store: AppStore
    @State private var serverURL = ""
    @State private var email = ""
    @State private var masterPassword = ""
    @State private var verificationCode = ""
    @State private var requiresTwoFactor = false
    @State private var errorMessage: String?
    @State private var isConnecting = false

    private var canConnect: Bool {
        !serverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !masterPassword.isEmpty
            && (!requiresTwoFactor || verificationCode.count == 6)
            && !isConnecting
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        VaultIcon(systemName: "lock.shield.fill", color: .vaultBlue, size: 52)
                        Text("Sign in to your vault")
                            .font(.title2.bold())
                        Text("Use the account on your self-hosted server. Your master password is used only to unlock the encrypted vault.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }

                Section("Account") {
                    TextField("Server URL", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Master Password", text: $masterPassword)
                        .textContentType(.password)
                }

                if requiresTwoFactor {
                    Section("Two-step login") {
                        TextField("6-digit verification code", text: $verificationCode)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .onChange(of: verificationCode) { _, newValue in
                                verificationCode = String(newValue.filter(\.isNumber).prefix(6))
                            }
                        Text("Enter the code from your authenticator app.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        connect()
                    } label: {
                        HStack {
                            Spacer()
                            if isConnecting {
                                ProgressView()
                            } else {
                                Text("Sign In").fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(!canConnect)
                }
            }
            .navigationTitle("Vaultwarden")
            .toolbarTitleDisplayMode(.inlineLarge)
            .onAppear {
                serverURL = store.settings.serverURL
                email = store.settings.email
            }
        }
    }

    private func connect() {
        guard canConnect else { return }
        errorMessage = nil
        isConnecting = true
        Task {
            defer { isConnecting = false }
            do {
                try await store.connect(
                    serverURL: serverURL,
                    email: email,
                    masterPassword: masterPassword,
                    twoFactorCode: requiresTwoFactor ? verificationCode : nil
                )
                masterPassword = ""
                verificationCode = ""
            } catch {
                if case VaultwardenServiceError.twoFactorRequired = error {
                    requiresTwoFactor = true
                    verificationCode = ""
                    errorMessage = nil
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
