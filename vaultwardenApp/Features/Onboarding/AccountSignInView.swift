import SwiftUI

/// Signing in after signing out, or when a saved session has ended. As the app's root
/// it has no Cancel; as a sheet (`onSuccess` set) it does.
struct AccountSignInView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSuccess: (() -> Void)? = nil
    @State private var serverAddress = ""
    @State private var email = ""
    @State private var masterPassword = ""
    @State private var verificationCode = ""
    @State private var requiresTwoFactor = false
    @State private var errorMessage: String?
    @State private var isConnecting = false
    @State private var signIns = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case server, email, password, verificationCode
    }

    private var isSheet: Bool { onSuccess != nil }

    private var canConnect: Bool {
        serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@")
            && masterPassword.isEmpty == false
            && (requiresTwoFactor == false || verificationCode.count == 6)
            && isConnecting == false
    }

    var body: some View {
        NavigationStack {
            Form {
                SettingsHero(
                    isSheet ? Text("Sign In Again") : Text("Sign In"),
                    subtitle: Text("Sign in to your Vaultwarden server to open your vault."),
                    systemImage: "lock.shield.fill",
                    tint: .vaultBlue
                )

                Section {
                    TextField("Server Address", text: $serverAddress, prompt: Text(verbatim: "vault.example.com"))
                        .vaultKeyboardType(.URL)
                        .vaultTextContentType(.URL)
                        .vaultTextInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .server)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .email }
                    TextField("Email", text: $email, prompt: Text("Email"))
                        .vaultKeyboardType(.emailAddress)
                        .vaultTextContentType(.username)
                        .vaultTextInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .password }
                    SecureField("Master Password", text: $masterPassword, prompt: Text("Master Password"))
                        .vaultTextContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(requiresTwoFactor ? .next : .go)
                        .onSubmit {
                            if requiresTwoFactor { focusedField = .verificationCode } else { connect() }
                        }
                } footer: {
                    if requiresTwoFactor == false {
                        footer
                    }
                }

                if requiresTwoFactor {
                    Section {
                        TextField("Verification Code", text: $verificationCode, prompt: Text("6-Digit Code"))
                            .vaultKeyboardType(.numberPad)
                            .vaultTextContentType(.oneTimeCode)
                            .monospacedDigit()
                            .focused($focusedField, equals: .verificationCode)
                            .onSubmit(connect)
                            .onChange(of: verificationCode) { _, newValue in
                                let digits = String(newValue.filter(\.isNumber).prefix(6))
                                if digits != newValue { verificationCode = digits }
                            }
                    } header: {
                        Text("Two-Step Verification")
                    } footer: {
                        footer
                    }
                }

                #if os(iOS)
                Section {
                    Button(action: connect) {
                        HStack(spacing: SettingsSpacing.standard) {
                            if isConnecting { ProgressView() }
                            Text(isConnecting ? "Signing In…" : "Sign In")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .disabled(canConnect == false)
                }
                #else
                Section {
                } footer: {
                    HStack(spacing: SettingsSpacing.standard) {
                        Spacer()
                        if isConnecting { ProgressView().controlSize(.small) }
                        Button("Sign In", action: connect)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                            .disabled(canConnect == false)
                    }
                }
                #endif
            }
            .formStyle(.grouped)
            .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: requiresTwoFactor)
            .navigationTitle(Text(verbatim: ""))
            .vaultNavigationTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isConnecting)
                    }
                }
            }
            .onAppear {
                serverAddress = store.settings.serverURL
                email = store.settings.email
            }
            .task {
                try? await Task.sleep(for: .milliseconds(450))
                guard Task.isCancelled == false else { return }
                focusedField = serverAddress.isEmpty ? .server : (email.isEmpty ? .email : .password)
            }
            .onDisappear {
                masterPassword = ""
                verificationCode = ""
            }
        }
        .interactiveDismissDisabled(isConnecting)
        .sensoryFeedback(.success, trigger: signIns) { _, _ in store.settings.haptics }
        .vaultSheetSize(width: 520, height: 560)
        #if os(macOS)
        .frame(maxWidth: 680, maxHeight: 640)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.vaultBackground)
        #endif
    }

    @ViewBuilder
    private var footer: some View {
        if let errorMessage {
            StatusTone.failure.apply(to: Text(verbatim: errorMessage))
        } else if requiresTwoFactor {
            Text("Enter the code from your authenticator app.")
        } else {
            Text("Your master password is never stored, and never sent to your server as plain text.")
        }
    }

    private func connect() {
        guard canConnect else { return }
        let address: String
        switch ServerAddress.normalized(serverAddress) {
        case .failure(let problem):
            errorMessage = problem.message
            focusedField = .server
            return
        case .success(let url):
            address = url.absoluteString
            serverAddress = address
        }
        errorMessage = nil
        isConnecting = true
        let usesCode = requiresTwoFactor
        Task {
            defer { isConnecting = false }
            do {
                try await store.connect(
                    serverURL: address,
                    email: email,
                    masterPassword: masterPassword,
                    twoFactorCode: usesCode ? verificationCode : nil
                )
                masterPassword = ""
                verificationCode = ""
                signIns += 1
                onSuccess?()
            } catch VaultwardenServiceError.twoFactorRequired {
                verificationCode = ""
                if usesCode {
                    errorMessage = L10n.string("That code didn’t work. Enter the newest one from your authenticator app.")
                }
                requiresTwoFactor = true
                focusedField = .verificationCode
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                focusedField = usesCode ? .verificationCode : .password
            }
        }
    }
}
