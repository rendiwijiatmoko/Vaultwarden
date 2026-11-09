import AuthenticationServices
import SwiftUI
#if os(macOS)
import AppKit
#endif

private enum OnboardingStep: Int, CaseIterable {
    case welcome
    case server
    case signIn
    case twoFactor
    case security
    case autofill
    case done

    /// Steps before signing in can go back; after it, the account exists and the way is forward.
    var previous: OnboardingStep? {
        switch self {
        case .server: .welcome
        case .signIn: .server
        case .twoFactor: .signIn
        case .welcome, .security, .autofill, .done: nil
        }
    }
}

/// First run, as a setup assistant: one question per screen, a big title, a short
/// sentence, the primary action at the bottom and the alternative under it.
struct OnboardingView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var isMovingForward = true
    @State private var serverAddress = ""
    @State private var email = ""
    @State private var masterPassword = ""
    @State private var verificationCode = ""
    @State private var biometricUnlock = false
    @State private var requireBiometricForFill = true
    @State private var allowPasscodeFallback = false
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var isAutoFillEnabled = false
    @State private var openedAutoFillSettings = false
    @State private var biometry = BiometryKind.current
    @State private var completedSteps = 0
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case server, email, password, verificationCode
    }

    private var serverHost: String { SettingsWords.serverHost(serverAddress) }

    private var sensorName: String { biometry.name ?? L10n.string("Biometrics") }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                page
                    .id(step)
                    .transition(pageTransition)
                    .frame(maxWidth: 460)
                    .padding(.horizontal, SettingsSpacing.section)
                    .padding(.top, SettingsSpacing.standard)
                    .padding(.bottom, SettingsSpacing.section)
                    .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        .background(Color.vaultBackground)
        .sensoryFeedback(.success, trigger: completedSteps) { _, _ in store.settings.haptics }
        .vaultSheetSize(width: 640, height: 680)
        #if os(macOS)
        .frame(maxWidth: 680, maxHeight: 760)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.vaultBackground)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAutoFillState() }
        }
        #endif
        .onAppear {
            serverAddress = store.settings.serverURL
            email = store.settings.email
            biometricUnlock = store.settings.biometricUnlock
            requireBiometricForFill = store.settings.requireBiometricForSensitiveActions
            allowPasscodeFallback = store.settings.devicePasscodeFallback
        }
        .onDisappear {
            masterPassword = ""
            verificationCode = ""
        }
        .task(id: step) {
            if step == .autofill { await refreshAutoFillState() }
            guard let field = firstField(of: step) else { return }
            // Wait for the page to arrive; focus set during the insertion is dropped.
            try? await Task.sleep(for: .milliseconds(450))
            guard Task.isCancelled == false else { return }
            focusedField = field
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, step == .autofill else { return }
            Task { await refreshAutoFillState() }
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            if let previous = step.previous {
                Button {
                    move(to: previous)
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .buttonStyle(.borderless)
                .disabled(isWorking)
                .keyboardShortcut(.cancelAction)
            }
            Spacer()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 16)
    }

    private var pageTransition: AnyTransition {
        guard reduceMotion == false else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: isMovingForward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: isMovingForward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    private var actions: some View {
        VStack(spacing: SettingsSpacing.row) {
            Button(action: advance) {
                HStack(spacing: SettingsSpacing.standard) {
                    if isWorking {
                        ProgressView().controlSize(.small)
                    }
                    Text(primaryTitle)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(canAdvance == false || isWorking)

            if let secondaryTitle {
                Button(secondaryTitle, action: secondaryAction)
                    .buttonStyle(.borderless)
                    .disabled(isWorking)
            }
        }
        .frame(maxWidth: 460)
        .padding(.horizontal, SettingsSpacing.section)
        .padding(.top, SettingsSpacing.standard)
        .padding(.bottom, SettingsSpacing.row)
        .frame(maxWidth: .infinity)
        .background(Color.vaultBackground)
    }

    // MARK: - Pages

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome: welcomePage
        case .server: serverPage
        case .signIn: signInPage
        case .twoFactor: twoFactorPage
        case .security: securityPage
        case .autofill: autofillPage
        case .done: donePage
        }
    }

    private var welcomePage: some View {
        VStack(spacing: SettingsSpacing.section) {
            OnboardingHeader(
                systemImage: "lock.shield.fill",
                tint: .vaultBlue,
                title: Text("Welcome to Vaultwarden"),
                message: Text("Your passwords, passkeys and codes, from the Vaultwarden server you run.")
            )
            VStack(alignment: .leading, spacing: SettingsSpacing.section) {
                OnboardingFeatureRow(
                    systemImage: "key.fill",
                    tint: .vaultBlue,
                    title: Text("Passwords and Passkeys"),
                    message: Text("Sign in to websites and apps without typing a password.")
                )
                OnboardingFeatureRow(
                    systemImage: "lock.rotation",
                    tint: .vaultYellow,
                    title: Text("Verification Codes"),
                    message: Text("Keep two-factor codes beside the logins they protect.")
                )
                OnboardingFeatureRow(
                    systemImage: biometry.systemImage,
                    tint: .vaultGreen,
                    title: Text("Locked on This Device"),
                    message: Text("Everything stays encrypted until you unlock it.")
                )
            }
            .padding(.top, SettingsSpacing.standard)
        }
    }

    private var serverPage: some View {
        VStack(spacing: SettingsSpacing.section) {
            OnboardingHeader(
                systemImage: "server.rack",
                tint: .vaultCyan,
                title: Text("Your Server"),
                message: Text("Enter the address of your Vaultwarden server.")
            )
            OnboardingFieldGroup {
                TextField("Server Address", text: $serverAddress, prompt: Text(verbatim: "vault.example.com"))
                    .vaultKeyboardType(.URL)
                    .vaultTextContentType(.URL)
                    .vaultTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .server)
                    .submitLabel(.continue)
                    .onSubmit(advance)
                    .onChange(of: serverAddress) { _, _ in errorMessage = nil }
                    .onboardingFieldStyle()
            }
            OnboardingFootnote(error: errorMessage) {
                Text("Vaultwarden connects only over HTTPS.")
            }
        }
    }

    private var signInPage: some View {
        VStack(spacing: SettingsSpacing.section) {
            OnboardingHeader(
                systemImage: "person.crop.circle.fill",
                tint: .vaultBlue,
                title: Text("Sign In"),
                message: Text("Use the account you created on \(serverHost).")
            )
            OnboardingFieldGroup {
                TextField("Email", text: $email, prompt: Text("Email"))
                    .vaultKeyboardType(.emailAddress)
                    .vaultTextContentType(.username)
                    .vaultTextInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .email)
                    .submitLabel(.next)
                    .onSubmit { focusedField = .password }
                    .onboardingFieldStyle()
                Divider()
                SecureField("Master Password", text: $masterPassword, prompt: Text("Master Password"))
                    .vaultTextContentType(.password)
                    .focused($focusedField, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(advance)
                    .onboardingFieldStyle()
            }
            .onChange(of: email) { _, _ in errorMessage = nil }
            .onChange(of: masterPassword) { _, _ in errorMessage = nil }
            OnboardingFootnote(error: errorMessage) {
                Text("Your master password is never stored, and never sent to your server as plain text.")
            }
        }
    }

    private var twoFactorPage: some View {
        VStack(spacing: SettingsSpacing.section) {
            OnboardingHeader(
                systemImage: "lock.rotation",
                tint: .vaultYellow,
                title: Text("Two-Step Verification"),
                message: Text("Enter the 6-digit code from your authenticator app.")
            )
            OnboardingFieldGroup {
                TextField("Verification Code", text: $verificationCode, prompt: Text(verbatim: "000000"))
                    .vaultKeyboardType(.numberPad)
                    .vaultTextContentType(.oneTimeCode)
                    .font(.title2.monospacedDigit())
                    .multilineTextAlignment(.center)
                    .focused($focusedField, equals: .verificationCode)
                    .onSubmit(advance)
                    .onChange(of: verificationCode) { _, newValue in
                        let digits = String(newValue.filter(\.isNumber).prefix(6))
                        if digits != newValue { verificationCode = digits }
                        errorMessage = nil
                        // A full code needs no extra tap, as the system code field behaves.
                        if digits.count == 6 && isWorking == false { advance() }
                    }
                    .onboardingFieldStyle()
            }
            OnboardingFootnote(error: errorMessage) {
                EmptyView()
            }
        }
    }

    private var securityPage: some View {
        VStack(spacing: SettingsSpacing.section) {
            OnboardingHeader(
                systemImage: biometry.systemImage,
                tint: .vaultGreen,
                title: biometry.name.map { Text("Unlock with \($0)") } ?? Text("Protect Your Vault"),
                message: Text("Open your vault with \(sensorName) instead of typing your master password. You can change this later in Settings.")
            )
            OnboardingFieldGroup {
                Toggle(isOn: $biometricUnlock) {
                    Text("Unlock with \(sensorName)")
                }
                .onboardingFieldStyle()
                if biometricUnlock {
                    Divider()
                    Toggle(isOn: $allowPasscodeFallback) {
                        #if os(macOS)
                        Text("Allow Mac Login Password")
                        #else
                        Text("Allow Device Passcode")
                        #endif
                    }
                    .onboardingFieldStyle()
                }
                Divider()
                Toggle(isOn: $requireBiometricForFill) {
                    Text("Verify to Reveal or Copy")
                }
                .onboardingFieldStyle()
            }
            .animation(SettingsMotion.row(reduceMotion: reduceMotion), value: biometricUnlock)
            OnboardingFootnote(error: nil) {
                Text("Your master password always unlocks your vault. AutoFill needs \(sensorName) to be on.")
            }
        }
        .onChange(of: biometricUnlock) { _, isOn in
            if isOn == false { allowPasscodeFallback = false }
        }
    }

    private var autofillPage: some View {
        VStack(spacing: SettingsSpacing.section) {
            OnboardingHeader(
                systemImage: "key.fill",
                tint: .vaultGreen,
                title: Text("Turn On AutoFill"),
                message: Text("Fill passwords, passkeys and codes from your vault in Safari and other apps.")
            )
            VStack(alignment: .leading, spacing: SettingsSpacing.row) {
                SetupStepRow(
                    1,
                    title: Text("Open AutoFill settings"),
                    detail: autoFillSettingsPath,
                    progress: .step(done: openedAutoFillSettings || isAutoFillEnabled, after: true)
                ) {
                    if isAutoFillEnabled == false {
                        Button(action: openAutoFillSettings) {
                            HStack(spacing: 6) {
                                Text("Open Settings")
                                Image(systemName: "arrow.up.forward")
                                    .font(.caption.weight(.semibold))
                                    .accessibilityHidden(true)
                            }
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                Divider()
                SetupStepRow(
                    2,
                    title: Text("Turn on Vaultwarden"),
                    detail: Text("Under AutoFill From, turn on Vaultwarden. This checks off on its own."),
                    progress: .step(done: isAutoFillEnabled, after: openedAutoFillSettings || isAutoFillEnabled)
                )
            }
            .padding(16)
            .background(Color.vaultCard, in: .rect(cornerRadius: 12, style: .continuous))
            .animation(SettingsMotion.flip, value: isAutoFillEnabled)
            .animation(SettingsMotion.flip, value: openedAutoFillSettings)
        }
    }

    private var donePage: some View {
        OnboardingHeader(
            systemImage: "checkmark.circle.fill",
            tint: .vaultGreen,
            title: Text("You’re All Set"),
            message: Text("Your vault is ready on this device.")
        )
        .padding(.top, SettingsSpacing.section)
    }

    private var autoFillSettingsPath: Text {
        #if os(macOS)
        Text("System Settings ▸ General ▸ AutoFill & Passwords")
        #else
        Text("Settings ▸ General ▸ AutoFill & Passwords")
        #endif
    }

    // MARK: - Actions

    private var primaryTitle: String {
        let key: String = switch step {
        case .welcome: "Continue"
        case .server: isWorking ? "Connecting…" : "Continue"
        case .signIn: isWorking ? "Signing In…" : "Sign In"
        case .twoFactor: isWorking ? "Verifying…" : "Verify"
        case .security: "Continue"
        case .autofill: isAutoFillEnabled ? "Continue" : "Turn On AutoFill"
        case .done: "Open Vault"
        }
        return L10n.string(key)
    }

    private var secondaryTitle: String? {
        step == .autofill && isAutoFillEnabled == false ? L10n.string("Set Up Later") : nil
    }

    private var canAdvance: Bool {
        switch step {
        case .server:
            return serverAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        case .signIn:
            return email.trimmingCharacters(in: .whitespacesAndNewlines).contains("@") && masterPassword.isEmpty == false
        case .twoFactor:
            return verificationCode.count == 6
        case .welcome, .security, .autofill, .done:
            return true
        }
    }

    private func firstField(of step: OnboardingStep) -> Field? {
        switch step {
        case .server: .server
        case .signIn: email.isEmpty ? .email : .password
        case .twoFactor: .verificationCode
        case .welcome, .security, .autofill, .done: nil
        }
    }

    private func advance() {
        guard canAdvance, isWorking == false else { return }
        switch step {
        case .welcome:
            move(to: .server)
        case .server:
            checkServer()
        case .signIn, .twoFactor:
            signIn()
        case .security:
            applySecuritySettings()
            move(to: .autofill)
        case .autofill:
            if isAutoFillEnabled {
                leaveAutoFillStep()
            } else {
                Task { await requestAutoFill() }
            }
        case .done:
            applySecuritySettings()
            onComplete()
        }
    }

    private func secondaryAction() {
        if step == .autofill { leaveAutoFillStep() }
    }

    private func move(to newStep: OnboardingStep) {
        focusedField = nil
        errorMessage = nil
        isMovingForward = newStep.rawValue > step.rawValue
        withAnimation(reduceMotion ? SettingsMotion.contentFade : .smooth(duration: 0.35)) {
            step = newStep
        }
    }

    private func checkServer() {
        switch ServerAddress.normalized(serverAddress) {
        case .failure(let problem):
            errorMessage = problem.message
        case .success(let url):
            serverAddress = url.absoluteString
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    _ = try await store.testConnection(serverURL: url.absoluteString)
                    move(to: .signIn)
                } catch {
                    SecureLog.failure("Onboarding server check", error: error, logger: SecureLog.sync)
                    errorMessage = L10n.format("Couldn’t reach %@. Check the address and your internet connection.", serverHost)
                }
            }
        }
    }

    private func signIn() {
        let usesCode = step == .twoFactor
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                try await store.connect(
                    serverURL: serverAddress,
                    email: email,
                    masterPassword: masterPassword,
                    twoFactorCode: usesCode ? verificationCode : nil
                )
                masterPassword = ""
                verificationCode = ""
                completedSteps += 1
                move(to: .security)
            } catch VaultwardenServiceError.twoFactorRequired {
                if usesCode {
                    verificationCode = ""
                    errorMessage = L10n.string("That code didn’t work. Enter the newest one from your authenticator app.")
                    focusedField = .verificationCode
                } else {
                    verificationCode = ""
                    move(to: .twoFactor)
                }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                if usesCode {
                    verificationCode = ""
                    focusedField = .verificationCode
                } else {
                    focusedField = .password
                }
            }
        }
    }

    private func applySecuritySettings() {
        var settings = store.settings
        settings.biometricUnlock = biometricUnlock
        settings.requireBiometricForSensitiveActions = requireBiometricForFill
        settings.devicePasscodeFallback = biometricUnlock && allowPasscodeFallback
        store.settings = settings
    }

    // MARK: - AutoFill

    private func refreshAutoFillState() async {
        let enabled = await ASCredentialIdentityStore.shared.state().isEnabled
        if enabled && isAutoFillEnabled == false && step == .autofill { completedSteps += 1 }
        isAutoFillEnabled = enabled
    }

    private func requestAutoFill() async {
        isWorking = true
        markAutoFillOffered()
        _ = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
        isWorking = false
        await refreshAutoFillState()
    }

    private func openAutoFillSettings() {
        openedAutoFillSettings = true
        markAutoFillOffered()
        ASSettingsHelper.openCredentialProviderAppSettings { error in
            guard error != nil else { return }
            Task { @MainActor in
                errorMessage = L10n.string("Settings couldn’t be opened. Open it yourself and go to General ▸ AutoFill & Passwords.")
            }
        }
    }

    private func leaveAutoFillStep() {
        markAutoFillOffered()
        move(to: .done)
    }

    /// The Mac also offers AutoFill once after setup. Offering it here counts, so it
    /// isn't asked twice in a row.
    private func markAutoFillOffered() {
        #if os(macOS)
        UserDefaults.standard.set(true, forKey: "hasRequestedAutoFillSetup")
        #endif
    }
}

// MARK: - Pieces

private struct OnboardingHeader: View {
    let systemImage: String
    let tint: Color
    let title: Text
    let message: Text

    @ScaledMetric(relativeTo: .largeTitle) private var symbolSize: CGFloat = 60

    var body: some View {
        VStack(spacing: SettingsSpacing.row) {
            Image(systemName: systemImage)
                .font(.system(size: symbolSize, weight: .regular))
                .foregroundStyle(tint.gradient)
                .symbolRenderingMode(.hierarchical)
                .frame(minHeight: symbolSize * 1.1)
                .accessibilityHidden(true)
            title
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
            message
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct OnboardingFeatureRow: View {
    let systemImage: String
    let tint: Color
    let title: Text
    let message: Text

    @ScaledMetric(relativeTo: .title2) private var iconWidth: CGFloat = 40

    var body: some View {
        HStack(alignment: .top, spacing: SettingsSpacing.row + 4) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(tint)
                .frame(width: iconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                title.font(.headline)
                message
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Fields in one rounded group, divided like a grouped form's rows.
private struct OnboardingFieldGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .padding(.horizontal, 16)
        .background(Color.vaultCard, in: .rect(cornerRadius: 12, style: .continuous))
    }
}

/// The line under a group: an error when there is one, otherwise the quiet note.
private struct OnboardingFootnote<Note: View>: View {
    let error: String?
    @ViewBuilder let note: Note

    var body: some View {
        Group {
            if let error {
                StatusTone.failure.apply(to: Text(verbatim: error))
            } else {
                note.foregroundStyle(.secondary)
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .contentTransition(.opacity)
    }
}

private extension View {
    func onboardingFieldStyle() -> some View {
        textFieldStyle(.plain)
            .padding(.vertical, 14)
            .frame(minHeight: 50)
    }
}
