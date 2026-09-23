import AuthenticationServices
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case account
    case security
    case autofill
}

struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var serverURL = ""
    @State private var email = ""
    @State private var masterPassword = ""
    @State private var verificationCode = ""
    @State private var requiresTwoFactor = false
    @State private var biometricUnlock = true
    @State private var requireBiometricForFill = true
    @State private var allowPasscodeFallback = false
    @State private var isConnecting = false
    @State private var connectionError: String?
    @State private var autofillStatus: String?
    @FocusState private var focusedField: AccountField?

    private enum AccountField: Hashable {
        case server, email, password, verificationCode
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 22)
                .padding(.top, 14)
                .padding(.bottom, 16)
                .background(Color.vaultBackground)

            ScrollView {
                Group {
                    switch step {
                    case .welcome: welcomePage
                    case .account: accountPage
                    case .security: securityPage
                    case .autofill: autofillPage
                    }
                }
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
                .padding(.horizontal, 22)
                .padding(.top, 28)
                .padding(.bottom, 28)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(Color.vaultBackground)
        .safeAreaInset(edge: .bottom) { footer }
        .vaultSheetSize(width: 640, height: 680)
        #if os(macOS)
        .frame(maxWidth: 680, maxHeight: 760)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.vaultBackground)
        #endif
        .onAppear {
            serverURL = store.settings.serverURL
            email = store.settings.email
            biometricUnlock = store.settings.biometricUnlock
            requireBiometricForFill = store.settings.requireBiometricForSensitiveActions
            allowPasscodeFallback = store.settings.devicePasscodeFallback
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label {
                    Text("Vaultwarden")
                        .font(.headline)
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color.vaultBlue)
                }
                Spacer()
                Text(L10n.format("%lld of %lld", step.rawValue + 1, OnboardingStep.allCases.count))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { item in
                    Capsule()
                        .fill(item.rawValue <= step.rawValue ? Color.vaultBlue : Color.secondary.opacity(0.18))
                        .frame(height: 5)
                }
            }
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 28) {
            OnboardingHero(
                icon: "lock.rectangle.stack.fill",
                color: .vaultBlue,
                title: "Your vault, everywhere.",
                message: "Keep passwords, passkeys, verification codes, cards, and identities together in your own Vaultwarden server."
            )

            VStack(spacing: 12) {
                OnboardingFeatureRow(icon: "key.fill", color: .vaultBlue, title: "Passwords & passkeys", message: "Sign in quickly without exposing your credentials.")
                OnboardingFeatureRow(icon: "lock.rotation", color: .vaultYellow, title: "Verification codes", message: "Generate and copy time-based codes from the same vault.")
                OnboardingFeatureRow(icon: BiometricAuthenticator.systemImage, color: .vaultGreen, title: "Protected locally", message: "Require biometrics before unlock, reveal, copy, or fill.")
            }
        }
    }

    private var accountPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingHero(
                icon: "server.rack",
                color: .vaultCyan,
                title: "Connect your server",
                message: "Use the URL of your Vaultwarden server and the account you already created there."
            )

            VStack(spacing: 0) {
                OnboardingInputField(
                    title: "Server URL",
                    placeholder: "https://vault.example.com",
                    text: $serverURL,
                    keyboardType: .URL,
                    textContentType: .URL,
                    isSecure: false
                )
                .focused($focusedField, equals: .server)

                Divider()

                OnboardingInputField(
                    title: "Email",
                    placeholder: "you@example.com",
                    text: $email,
                    keyboardType: .emailAddress,
                    textContentType: .emailAddress,
                    isSecure: false
                )
                .focused($focusedField, equals: .email)

                Divider()

                OnboardingInputField(
                    title: "Master Password",
                    placeholder: "Enter your master password",
                    text: $masterPassword,
                    keyboardType: .default,
                    textContentType: .password,
                    isSecure: true
                )
                .focused($focusedField, equals: .password)

                if requiresTwoFactor {
                    Divider()

                    OnboardingInputField(
                        title: "Verification Code",
                        placeholder: "6-digit code",
                        text: $verificationCode,
                        keyboardType: .numberPad,
                        textContentType: .oneTimeCode,
                        isSecure: false
                    )
                    .focused($focusedField, equals: .verificationCode)
                    .onChange(of: verificationCode) { _, newValue in
                        verificationCode = String(newValue.filter(\.isNumber).prefix(6))
                    }
                }
            }
            .padding(.horizontal, 16)
            .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Label("Your master password is used to unlock the encrypted vault and is never saved as plain text.", systemImage: "hand.raised.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let connectionError {
                Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

        }
    }

    private var securityPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingHero(
                icon: BiometricAuthenticator.systemImage,
                color: .vaultGreen,
                title: "Protect this device",
                message: "Choose when this device should verify that it is really you. These options can be changed later."
            )

            VStack(spacing: 0) {
                OnboardingToggleRow(
                    icon: BiometricAuthenticator.systemImage,
                    title: "Unlock with biometrics",
                    message: L10n.format(
                        "Use %@ instead of typing the master password every time.",
                        BiometricAuthenticator.displayName
                    ),
                    isOn: $biometricUnlock
                )

                Divider().padding(.leading, 54)

                OnboardingToggleRow(
                    icon: "rectangle.and.pencil.and.ellipsis",
                    title: "Authenticate before filling",
                    message: "Verify before passwords, passkeys, or codes leave the vault.",
                    isOn: $requireBiometricForFill
                )

                Divider().padding(.leading, 54)

                OnboardingToggleRow(
                    icon: "ellipsis.rectangle.fill",
                    title: deviceAuthenticationTitle,
                    message: deviceAuthenticationMessage,
                    isOn: $allowPasscodeFallback
                )
            }
            .padding(.horizontal, 16)
            .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Label("The master password remains your recovery path even when biometric unlock is enabled.", systemImage: "key.horizontal.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var autofillPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            OnboardingHero(
                icon: "rectangle.and.pencil.and.ellipsis",
                color: .vaultOrange,
                title: "Fill in apps and Safari",
                message: "Enable this app as a credential provider so passwords and verification codes appear outside the vault."
            )

            VStack(alignment: .leading, spacing: 18) {
                #if os(macOS)
                OnboardingInstruction(number: 1, text: "Open AutoFill settings in System Settings.")
                OnboardingInstruction(number: 2, text: "Turn on AutoFill Passwords and Passkeys.")
                #else
                OnboardingInstruction(number: 1, text: "Open Passwords & Codes in iOS Settings.")
                OnboardingInstruction(number: 2, text: "Choose AutoFill Passwords and Passkeys.")
                #endif
                OnboardingInstruction(number: 3, text: "Select Vaultwarden as your provider.")
            }
            .padding(18)
            .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                ASSettingsHelper.openCredentialProviderAppSettings { error in
                    Task { @MainActor in
                        autofillStatus = error == nil
                            ? "AutoFill settings opened."
                            : error?.localizedDescription
                    }
                }
            } label: {
                Label("Open AutoFill Settings", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            if let autofillStatus {
                Text(autofillStatus)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }

            Text("You can finish setup now and enable AutoFill later from the app's Settings.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var footer: some View {
        VStack(spacing: 12) {
            Divider()
            HStack(spacing: 12) {
                if step != .welcome {
                    Button("Back") { moveBack() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }

                Button(action: advance) {
                    HStack(spacing: 8) {
                        if isConnecting {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(primaryButtonTitle)
                        if !isConnecting {
                            Image(systemName: step == .autofill ? "checkmark" : "arrow.right")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled((step == .account && !accountIsValid) || isConnecting)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 8)
        }
        .background(.ultraThinMaterial)
    }

    private var primaryButtonTitle: String {
        let key: String = switch step {
        case .welcome: "Get Started"
        case .account: isConnecting ? "Connecting…" : "Connect & Continue"
        case .security: "Continue"
        case .autofill: "Open My Vault"
        }
        return L10n.string(key)
    }

    private var deviceAuthenticationTitle: String {
        #if os(macOS)
        "Allow Mac login password"
        #else
        "Allow device passcode"
        #endif
    }

    private var deviceAuthenticationMessage: String {
        #if os(macOS)
        "Use your Mac login password when biometrics are unavailable."
        #else
        "Use the device passcode when biometrics are unavailable."
        #endif
    }

    private var accountIsValid: Bool {
        guard let components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return components.scheme?.lowercased() == "https"
            && components.host?.isEmpty == false
            && email.contains("@")
            && !masterPassword.isEmpty
            && (!requiresTwoFactor || verificationCode.count == 6)
    }

    private func advance() {
        focusedField = nil
        switch step {
        case .welcome:
            move(to: .account)
        case .account:
            guard accountIsValid else { return }
            isConnecting = true
            connectionError = nil
            Task {
                do {
                    try await store.connect(
                        serverURL: serverURL,
                        email: email,
                        masterPassword: masterPassword,
                        twoFactorCode: requiresTwoFactor ? verificationCode : nil
                    )
                    masterPassword = ""
                    isConnecting = false
                    move(to: .security)
                } catch {
                    isConnecting = false
                    if case VaultwardenServiceError.twoFactorRequired = error {
                        requiresTwoFactor = true
                        verificationCode = ""
                        connectionError = nil
                        focusedField = .verificationCode
                    } else {
                        connectionError = error.localizedDescription
                    }
                }
            }
        case .security:
            applySecuritySettings()
            move(to: .autofill)
        case .autofill:
            applySecuritySettings()
            onComplete()
        }
    }

    private func moveBack() {
        guard let previous = OnboardingStep(rawValue: step.rawValue - 1) else { return }
        move(to: previous)
    }

    private func move(to newStep: OnboardingStep) {
        withAnimation(.smooth) { step = newStep }
    }

    private func applySecuritySettings() {
        store.settings.biometricUnlock = biometricUnlock
        store.settings.requireBiometricForSensitiveActions = requireBiometricForFill
        store.settings.devicePasscodeFallback = allowPasscodeFallback
    }
}

private struct OnboardingHero: View {
    let icon: String
    let color: Color
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 66, height: 66)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Text(L10n.string(title))
                .font(.largeTitle.bold())

            Text(L10n.string(message))
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingFeatureRow: View {
    let icon: String
    let color: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(color.gradient, in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string(title)).font(.headline)
                Text(L10n.string(message))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.vaultCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

private struct OnboardingInputField: View {
    let title: String
    let placeholder: String
    @Binding var text: String
    let keyboardType: VaultKeyboardType
    let textContentType: VaultTextContentType?
    let isSecure: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.string(title))
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if isSecure {
                    SecureField(L10n.string(placeholder), text: $text)
                } else {
                    TextField(L10n.string(placeholder), text: $text)
                }
            }
            .vaultKeyboardType(keyboardType)
            .vaultTextContentType(textContentType)
            .vaultTextInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.vertical, 13)
    }
}

private struct OnboardingToggleRow: View {
    let icon: String
    let title: String
    let message: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.vaultBlue)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L10n.string(title)).font(.body.weight(.semibold))
                    Text(L10n.string(message))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 14)
    }
}

private struct OnboardingInstruction: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 13) {
            Text(number, format: .number)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(Color.vaultBlue.gradient, in: Circle())
            Text(L10n.string(text))
                .font(.body.weight(.medium))
            Spacer(minLength: 0)
        }
    }
}
