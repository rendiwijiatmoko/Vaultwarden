import AuthenticationServices
import Combine
import LocalAuthentication
import SwiftUI
#if os(macOS)
import AppKit
private typealias AutoFillHostingController = NSHostingController
private typealias AutoFillImage = NSImage
private enum AutoFillKeyboardType { case `default`, URL }
private enum AutoFillCapitalization { case never, characters }
private typealias AutoFillTextContentType = NSTextContentType
#else
import UIKit
private typealias AutoFillHostingController = UIHostingController
private typealias AutoFillImage = UIImage
private typealias AutoFillKeyboardType = UIKeyboardType
private typealias AutoFillCapitalization = TextInputAutocapitalization
private typealias AutoFillTextContentType = UITextContentType
#endif

final class CredentialProviderViewController: ASCredentialProviderViewController {
    private enum RequestMode {
        case password
        case oneTimeCode
        case passkey
        case passkeyRegistration
        case passwordSave
        case passwordGeneration
        case configuration
    }

    private let viewModel = AutoFillCredentialListViewModel()
    private var hostingController: AutoFillHostingController<AutoFillCredentialListView>?
    private var mode: RequestMode = .password
    private var serviceIdentifiers: [String] = []
    private var credentials: [AutoFillCredentialRecord] = []
    private var pendingRequest: (any ASCredentialRequest)?
    #if os(iOS)
    private var pendingSavePasswordRequest: ASSavePasswordRequest?
    private var pendingGeneratePasswordsRequest: ASGeneratePasswordsRequest?
    #endif
    private var passkeyRequestParameters: ASPasskeyCredentialRequestParameters?
    private var unlockedVault: AutoFillUnlockedVault?
    private var accountDisplayName = L10n.string("Vaultwarden account")
    private var pendingUnlockReason: String?
    private var isUnlockingVault = false
    private var isViewPresented = false
    private var isAuthenticationPresentationReady = false
    private var presentationGeneration = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        configureView()
    }

    #if os(macOS)
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 560))
        preferredContentSize = NSSize(width: 620, height: 560)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        didPresentView()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        didDismissView()
    }
    #else
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        didPresentView()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        didDismissView()
    }
    #endif

    private func ensureViewLoaded() {
        #if os(macOS)
        _ = view
        #else
        loadViewIfNeeded()
        #endif
    }

    private func didPresentView() {
        isViewPresented = true
        isAuthenticationPresentationReady = false
        presentationGeneration += 1
        let generation = presentationGeneration
        Task { @MainActor [weak self] in
            // A credential-provider view can report `viewDidAppear` just before the
            // extension host accepts interactive LocalAuthentication requests.
            // Give the presentation transaction one moment to finish first.
            try? await Task.sleep(for: .milliseconds(250))
            guard let self,
                  self.isViewPresented,
                  self.presentationGeneration == generation,
                  self.isViewLoaded,
                  self.view.window != nil else { return }
            self.isAuthenticationPresentationReady = true
            self.startPendingUnlockIfPossible()
        }
    }

    private func didDismissView() {
        isViewPresented = false
        isAuthenticationPresentationReady = false
        presentationGeneration += 1
    }

    override func prepareInterfaceForExtensionConfiguration() {
        mode = .configuration
        pendingRequest = nil
        serviceIdentifiers = []
        unlockVault(reason: L10n.string("Enable Vaultwarden as your password provider"))
    }

    override func prepareCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        prepareList(mode: .password, serviceIdentifiers: serviceIdentifiers)
    }

    @available(iOSApplicationExtension 17.0, *)
    override func prepareCredentialList(
        for serviceIdentifiers: [ASCredentialServiceIdentifier],
        requestParameters: ASPasskeyCredentialRequestParameters
    ) {
        passkeyRequestParameters = requestParameters
        prepareList(mode: .passkey, serviceIdentifiers: serviceIdentifiers)
    }

    @available(iOSApplicationExtension 17.0, *)
    override func prepareInterface(forPasskeyRegistration registrationRequest: any ASCredentialRequest) {
        guard let request = registrationRequest as? ASPasskeyCredentialRequest,
              let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }
        mode = .passkeyRegistration
        pendingRequest = request
        passkeyRequestParameters = nil
        serviceIdentifiers = [identity.relyingPartyIdentifier]
        unlockVault(reason: L10n.string("Authenticate to create this passkey"))
    }

    #if os(iOS)
    @available(iOSApplicationExtension 26.2, *)
    override func performWithoutUserInteractionIfPossible(
        savePasswordRequest: ASSavePasswordRequest
    ) {
        pendingSavePasswordRequest = savePasswordRequest
        cancelRequest(code: .userInteractionRequired)
    }

    @available(iOSApplicationExtension 26.2, *)
    override func prepareInterface(for savePasswordRequest: ASSavePasswordRequest) {
        mode = .passwordSave
        pendingRequest = nil
        pendingSavePasswordRequest = savePasswordRequest
        pendingGeneratePasswordsRequest = nil
        passkeyRequestParameters = nil
        serviceIdentifiers = [savePasswordRequest.serviceIdentifier.identifier]
        unlockVault(reason: L10n.string("Authenticate to save this password"))
    }

    @available(iOSApplicationExtension 26.2, *)
    override func performWithoutUserInteraction(
        generatePasswordsRequest: ASGeneratePasswordsRequest
    ) {
        let results = AutoFillPasswordGeneration.results(for: generatePasswordsRequest)
        extensionContext.completeGeneratePasswordRequest(results: results, completionHandler: nil)
    }

    @available(iOSApplicationExtension 26.2, *)
    override func prepareInterface(for generatePasswordsRequest: ASGeneratePasswordsRequest) {
        mode = .passwordGeneration
        pendingRequest = nil
        pendingSavePasswordRequest = nil
        pendingGeneratePasswordsRequest = generatePasswordsRequest
        passkeyRequestParameters = nil
        serviceIdentifiers = [generatePasswordsRequest.serviceIdentifier.identifier]
        ensureViewLoaded()
        viewModel.generatedPasswords = AutoFillPasswordGeneration.options(for: generatePasswordsRequest)
        viewModel.state = .passwordGeneration(
            L10n.string("Choose a generated password that follows this website’s password rules.")
        )
    }

    #endif

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        prepareList(mode: .oneTimeCode, serviceIdentifiers: serviceIdentifiers)
    }

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        pendingRequest = credentialRequest
        if let request = credentialRequest as? ASPasswordCredentialRequest {
            mode = .password
            serviceIdentifiers = [request.credentialIdentity.serviceIdentifier.identifier]
        } else if let request = credentialRequest as? ASOneTimeCodeCredentialRequest {
            mode = .oneTimeCode
            serviceIdentifiers = [request.credentialIdentity.serviceIdentifier.identifier]
        } else if let request = credentialRequest as? ASPasskeyCredentialRequest {
            mode = .passkey
            if let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
                serviceIdentifiers = [identity.relyingPartyIdentifier]
            }
        } else {
            cancelRequest(code: .credentialIdentityNotFound)
            return
        }
        unlockVault(reason: L10n.string("Authenticate to fill this credential"))
    }

    override func prepareInterfaceToProvideCredential(
        for credentialIdentity: ASPasswordCredentialIdentity
    ) {
        mode = .password
        pendingRequest = nil
        passkeyRequestParameters = nil
        serviceIdentifiers = [credentialIdentity.serviceIdentifier.identifier]
        unlockVault(reason: L10n.string("Authenticate to choose a password"))
    }

    override func provideCredentialWithoutUserInteraction(for credentialRequest: any ASCredentialRequest) {
        // The shared key requires user presence, so silent credential delivery is intentionally disabled.
        cancelRequest(code: .userInteractionRequired)
    }

    override func provideCredentialWithoutUserInteraction(
        for credentialIdentity: ASPasswordCredentialIdentity
    ) {
        cancelRequest(code: .userInteractionRequired)
    }

    private func prepareList(
        mode: RequestMode,
        serviceIdentifiers: [ASCredentialServiceIdentifier]
    ) {
        self.mode = mode
        pendingRequest = nil
        viewModel.searchText = ""
        viewModel.showsAllCredentials = false
        if mode != .passkey { passkeyRequestParameters = nil }
        self.serviceIdentifiers = serviceIdentifiers.map(\.identifier)
        let reasonKey: String = switch mode {
        case .oneTimeCode: "Authenticate to choose a verification code"
        case .passkey: "Authenticate to choose a passkey"
        case .passkeyRegistration: "Authenticate to create this passkey"
        case .passwordSave: "Authenticate to save this password"
        default: "Authenticate to choose a password"
        }
        let reason = L10n.string(reasonKey)
        unlockVault(reason: reason)
    }

    private func unlockVault(reason: String) {
        ensureViewLoaded()
        showLoading(message: L10n.string("Unlocking encrypted AutoFill vault…"))
        pendingUnlockReason = reason
        startPendingUnlockIfPossible()
    }

    private func startPendingUnlockIfPossible() {
        guard isViewPresented,
              isAuthenticationPresentationReady,
              !isUnlockingVault,
              let reason = pendingUnlockReason else { return }
        pendingUnlockReason = nil
        isUnlockingVault = true
        viewModel.state = .loading(L10n.string("Unlocking encrypted AutoFill vault…"))
        Task {
            defer { isUnlockingVault = false }
            do {
                let unlocked = try await AutoFillSharedVault.load(reason: reason)
                unlockedVault = unlocked
                handleUnlocked(unlocked)
            } catch {
                if isRecoverableAuthenticationError(error) {
                    pendingUnlockReason = reason
                    showAuthenticationRetry(reason: reason)
                } else {
                    showError(error.localizedDescription)
                }
            }
        }
    }

    private func isRecoverableAuthenticationError(_ error: Error) -> Bool {
        if let sharedError = error as? AutoFillSharedVaultError,
           case .authenticationFailed = sharedError {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == LAError.errorDomain {
            return true
        }

        // errSecInteractionNotAllowed is commonly returned as -25308 when an
        // extension attempts to access protected Keychain state too early.
        return nsError.domain == NSOSStatusErrorDomain
            && OSStatus(nsError.code) == errSecInteractionNotAllowed
    }

    private func showAuthenticationRetry(reason: String) {
        #if os(macOS)
        viewModel.state = .retry(
            L10n.string("Authenticate with Touch ID or your Mac password to open the encrypted vault.")
        )
        viewModel.primaryActionTitle = L10n.string("Unlock Vault")
        #else
        viewModel.state = .retry(
            L10n.string("Authenticate with Face ID or your device passcode to open the encrypted vault.")
        )
        viewModel.primaryActionTitle = L10n.string("Unlock with Face ID")
        #endif
        viewModel.onPrimaryAction = { [weak self] in
            guard let self else { return }
            self.pendingUnlockReason = reason
            self.startPendingUnlockIfPossible()
        }
    }

    private func handleUnlocked(_ unlocked: AutoFillUnlockedVault) {
        let payload = unlocked.payload
        #if os(iOS)
        if mode == .passwordSave,
           let request = pendingSavePasswordRequest {
            showPasswordSave(request: request, payload: payload)
            return
        }
        #endif
        if mode == .passkeyRegistration,
           let request = pendingRequest as? ASPasskeyCredentialRequest {
            showPasskeyRegistration(request: request, payload: payload, unlocked: unlocked)
            return
        }
        if mode == .passkey {
            credentials = (payload.passkeys ?? [])
                .filter { passkey in
                    guard let parameters = passkeyRequestParameters else { return true }
                    return passkey.relyingPartyIdentifier == parameters.relyingPartyIdentifier
                        && (parameters.allowedCredentials.isEmpty
                            || parameters.allowedCredentials.contains(passkey.credentialID))
                }
                .map { passkey in
                    AutoFillCredentialRecord(
                        id: passkey.credentialID.base64EncodedString(),
                        name: passkey.userName.isEmpty ? passkey.relyingPartyIdentifier : passkey.userName,
                        username: passkey.relyingPartyIdentifier,
                        password: "",
                        serviceIdentifier: passkey.relyingPartyIdentifier,
                        totpSecret: nil,
                        uriRules: [
                            AutoFillURIRule(uri: passkey.relyingPartyIdentifier, match: .exact)
                        ]
                    )
                }
        } else {
            credentials = payload.credentials
            .filter { credential in
                switch mode {
                case .password: !credential.password.isEmpty
                case .oneTimeCode: credential.totpSecret?.isEmpty == false
                case .passkey: false
                case .passkeyRegistration: false
                case .passwordSave, .passwordGeneration: false
                case .configuration: true
                }
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        if mode == .configuration {
            showConfiguration(payload)
            return
        }
        if let passkeyRequest = pendingRequest as? ASPasskeyCredentialRequest {
            providePasskey(request: passkeyRequest, unlocked: unlocked)
            return
        }

        updateAccountAvatar(payload)
        viewModel.credentials = credentials
        viewModel.serviceIdentifiers = serviceIdentifiers
        viewModel.defaultURIMatchType = AutoFillSharedVault.defaultURIMatchType
        viewModel.showsWebsiteIcons = AutoFillSharedVault.showsWebsiteIcons
        viewModel.websiteIconServerURL = payload.writeSession?.serverURL
        viewModel.folders = payload.folders ?? []
        viewModel.kind = switch mode {
        case .oneTimeCode: .oneTimeCode
        case .passkey: .passkey
        case .password, .passkeyRegistration, .passwordSave,
             .passwordGeneration, .configuration: .password
        }
        viewModel.state = .credentials(requestMessage)
    }

    #if os(iOS)
    @available(iOSApplicationExtension 26.2, *)
    private func showPasswordSave(
        request: ASSavePasswordRequest,
        payload: AutoFillVaultPayload
    ) {
        updateAccountAvatar(payload)
        viewModel.folders = payload.folders ?? []
        viewModel.state = .passwordSave(
            L10n.string("Review the credential before saving it to your encrypted Vaultwarden vault.")
        )
        viewModel.beginCreate(
            suggestedURI: request.serviceIdentifier.identifier,
            suggestedName: request.title,
            username: request.credential.user,
            password: request.credential.password
        )
    }

    #endif

    @available(iOSApplicationExtension 17.0, *)
    private func showPasskeyRegistration(
        request: ASPasskeyCredentialRequest,
        payload: AutoFillVaultPayload,
        unlocked: AutoFillUnlockedVault
    ) {
        guard let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity else {
            showError(AutoFillPasskeyError.credentialNotFound.localizedDescription)
            return
        }
        updateAccountAvatar(payload)
        viewModel.registrationRelyingParty = identity.relyingPartyIdentifier
        viewModel.registrationUserName = identity.userName
        viewModel.state = .passkeyRegistration(
            L10n.string("A new Login item will be encrypted and saved to your Vaultwarden vault.")
        )
        viewModel.primaryActionTitle = L10n.string("Create Passkey")
        viewModel.onPrimaryAction = { [weak self] in
            guard let self else { return }
            self.viewModel.state = .loading(L10n.string("Creating and saving passkey…"))
            Task { await self.registerPasskey(request: request, unlocked: unlocked) }
        }
    }

    @available(iOSApplicationExtension 17.0, *)
    private func registerPasskey(
        request: ASPasskeyCredentialRequest,
        unlocked: AutoFillUnlockedVault
    ) async {
        do {
            let result = try await AutoFillPasskeySupport.register(
                request: request,
                unlockedVault: unlocked
            )
            let oldPayload = unlocked.payload
            let updatedPayload = AutoFillVaultPayload(
                schemaVersion: 4,
                accountReference: oldPayload.accountReference,
                generatedAt: Date(),
                credentials: oldPayload.credentials,
                passkeys: (oldPayload.passkeys ?? []) + [result.passkey],
                passkeyCiphers: (oldPayload.passkeyCiphers ?? []) + [result.cipher],
                cryptoContext: oldPayload.cryptoContext,
                writeSession: result.writeSession,
                userKey: unlocked.userKey,
                folders: oldPayload.folders
            )
            try AutoFillSharedVault.publish(payload: updatedPayload, userKey: unlocked.userKey)
            unlockedVault = AutoFillUnlockedVault(payload: updatedPayload, userKey: unlocked.userKey)
            await replaceCredentialIdentities(updatedPayload)
            await extensionContext.completeRegistrationRequest(using: result.credential)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showConfiguration(_ payload: AutoFillVaultPayload) {
        let passkeyCount = payload.passkeys?.count ?? 0
        viewModel.state = .configuration(L10n.format(
            "%lld credentials and %lld passkeys are ready. Finish setup to enable passkey, password, and verification-code suggestions.",
            payload.credentials.count,
            passkeyCount
        ))
        viewModel.primaryActionTitle = L10n.string("Finish Setup")
        viewModel.onPrimaryAction = { [weak self] in
            guard let self else { return }
            Task {
                await self.replaceCredentialIdentities(payload)
                self.extensionContext.completeExtensionConfigurationRequest()
            }
        }
    }

    private func provide(_ record: AutoFillCredentialRecord) {
        switch mode {
        case .password:
            let credential = ASPasswordCredential(user: record.username, password: record.password)
            extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
        case .oneTimeCode:
            guard let secret = record.totpSecret,
                  let code = AutoFillTOTP.code(secret: secret) else {
                showError("This verification code is invalid or unsupported.")
                return
            }
            extensionContext.completeOneTimeCodeRequest(
                using: ASOneTimeCodeCredential(code: code),
                completionHandler: nil
            )
        case .passkey:
            guard let unlockedVault,
                  let parameters = passkeyRequestParameters,
                  let selected = unlockedVault.payload.passkeys?.first(where: {
                      $0.credentialID.base64EncodedString() == record.id
                  }) else {
                showError(AutoFillPasskeyError.credentialNotFound.localizedDescription)
                return
            }
            Task {
                do {
                    let credential = try await AutoFillPasskeySupport.assertion(
                        requestParameters: parameters,
                        selectedPasskey: selected,
                        unlockedVault: unlockedVault
                    )
                    await extensionContext.completeAssertionRequest(using: credential)
                } catch {
                    showError(error.localizedDescription)
                }
            }
        case .passkeyRegistration, .passwordSave, .passwordGeneration, .configuration:
            break
        }
    }

    @available(iOSApplicationExtension 17.0, *)
    private func providePasskey(
        request: ASPasskeyCredentialRequest,
        unlocked: AutoFillUnlockedVault
    ) {
        Task {
            do {
                let credential = try await AutoFillPasskeySupport.assertion(
                    request: request,
                    unlockedVault: unlocked
                )
                await extensionContext.completeAssertionRequest(using: credential)
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func recordIdentifier(from request: any ASCredentialRequest) -> String? {
        let value: String?
        if let request = request as? ASPasswordCredentialRequest {
            value = request.credentialIdentity.recordIdentifier
        } else if let request = request as? ASOneTimeCodeCredentialRequest {
            value = request.credentialIdentity.recordIdentifier
        } else {
            value = nil
        }
        return value?.split(separator: "|").last.map(String.init)
    }

    private func replaceCredentialIdentities(_ payload: AutoFillVaultPayload) async {
        var identities = payload.credentials.reduce(into: [any ASCredentialIdentity]()) { values, record in
            guard let serviceValue = record.serviceIdentifier else { return }
            let service = ASCredentialServiceIdentifier(identifier: serviceValue, type: .domain)
            if !record.password.isEmpty {
                let password = ASPasswordCredentialIdentity(
                    serviceIdentifier: service,
                    user: record.username,
                    recordIdentifier: "password|\(record.id)"
                )
                password.rank = 100
                values.append(password)
            }
            if record.totpSecret?.isEmpty == false {
                values.append(ASOneTimeCodeCredentialIdentity(
                    serviceIdentifier: service,
                    label: record.name,
                    recordIdentifier: "totp|\(record.id)"
                ))
            }
        }
        if #available(iOSApplicationExtension 17.0, *) {
            identities.append(contentsOf: (payload.passkeys ?? []).map { passkey in
                ASPasskeyCredentialIdentity(
                    relyingPartyIdentifier: passkey.relyingPartyIdentifier,
                    userName: passkey.userName,
                    credentialID: passkey.credentialID,
                    userHandle: passkey.userHandle,
                    recordIdentifier: passkey.cipherID
                )
            })
        }
        try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    private var requestMessage: String {
        let trimmedTarget = serviceIdentifiers.first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let target = trimmedTarget?.isEmpty == false ? trimmedTarget : nil
        return switch mode {
        case .oneTimeCode:
            target.map { L10n.format("Choose a verification code for “%@”.", $0) }
                ?? L10n.string("Choose a verification code.")
        case .passkey:
            target.map { L10n.format("Choose a passkey for “%@”.", $0) }
                ?? L10n.string("Choose a passkey.")
        case .passkeyRegistration:
            target.map { L10n.format("Create a passkey for “%@”.", $0) }
                ?? L10n.string("Create a passkey.")
        case .passwordSave:
            target.map { L10n.format("Save a password for “%@”.", $0) }
                ?? L10n.string("Save this password.")
        case .passwordGeneration:
            target.map { L10n.format("Generate a password for “%@”.", $0) }
                ?? L10n.string("Generate a password.")
        case .password:
            target.map { L10n.format("Choose a password for “%@”.", $0) }
                ?? L10n.string("Choose a password.")
        case .configuration:
            L10n.string("Set up Vaultwarden AutoFill.")
        }
    }

    private func updateAccountAvatar(_ payload: AutoFillVaultPayload) {
        let email = payload.cryptoContext?.email.trimmingCharacters(in: .whitespacesAndNewlines)
        accountDisplayName = email.flatMap { $0.isEmpty ? nil : $0 } ?? payload.accountReference
        let initial = accountDisplayName.first.map { String($0).uppercased() } ?? "V"
        viewModel.avatarInitial = initial
        viewModel.accountDisplayName = accountDisplayName
    }

    private func showAccountInformation() {
        #if os(macOS)
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = accountDisplayName
        alert.informativeText = L10n.string("Credentials are loaded from this encrypted Vaultwarden account.")
        alert.addButton(withTitle: L10n.string("Done"))
        alert.beginSheetModal(for: window)
        #else
        let alert = UIAlertController(
            title: accountDisplayName,
            message: L10n.string("Credentials are loaded from this encrypted Vaultwarden account."),
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: L10n.string("Done"), style: .cancel))
        if let popover = alert.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(x: view.bounds.maxX - 44, y: 44, width: 1, height: 1)
        }
        present(alert, animated: true)
        #endif
    }

    private func saveNewLogin(_ input: AutoFillNewLoginInput) async throws -> AutoFillCredentialRecord {
        guard let unlockedVault else { throw AutoFillCreateLoginError.unavailable }
        let result = try await AutoFillCreateLoginSupport.create(
            input: input,
            unlockedVault: unlockedVault
        )
        let oldPayload = unlockedVault.payload
        let updatedPayload = AutoFillVaultPayload(
            schemaVersion: 4,
            accountReference: oldPayload.accountReference,
            generatedAt: Date(),
            credentials: oldPayload.credentials + [result.record],
            passkeys: oldPayload.passkeys,
            passkeyCiphers: oldPayload.passkeyCiphers,
            cryptoContext: oldPayload.cryptoContext,
            writeSession: result.writeSession,
            userKey: unlockedVault.userKey,
            folders: oldPayload.folders
        )
        try AutoFillSharedVault.publish(payload: updatedPayload, userKey: unlockedVault.userKey)
        let updatedVault = AutoFillUnlockedVault(payload: updatedPayload, userKey: unlockedVault.userKey)
        self.unlockedVault = updatedVault
        credentials.append(result.record)
        credentials.sort {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        viewModel.credentials = credentials
        await replaceCredentialIdentities(updatedPayload)
        return result.record
    }

    private func configureView() {
        viewModel.onCancel = { [weak self] in self?.cancelRequest(code: .userCanceled) }
        viewModel.onAdd = { [weak self] in
            guard let self else { return }
            #if os(iOS)
            self.pendingSavePasswordRequest = nil
            #endif
            self.viewModel.beginCreate(suggestedURI: self.serviceIdentifiers.first ?? "")
        }
        viewModel.onAccount = { [weak self] in self?.showAccountInformation() }
        viewModel.onSelect = { [weak self] credential in self?.provide(credential) }
        viewModel.onSaveNewLogin = { [weak self] input in
            guard let self else { throw AutoFillCreateLoginError.unavailable }
            return try await self.saveNewLogin(input)
        }
        viewModel.onDidSaveNewLogin = { [weak self] record in
            guard let self else { return }
            #if os(iOS)
            if self.pendingSavePasswordRequest != nil {
                self.extensionContext.completeSavePasswordRequest(completionHandler: nil)
                return
            }
            #endif
            self.provide(record)
        }
        viewModel.onCancelCreate = { [weak self] in
            guard let self else { return }
            self.viewModel.isPresentingCreate = false
            #if os(iOS)
            if self.pendingSavePasswordRequest != nil {
                self.cancelRequest(code: .userCanceled)
            }
            #endif
        }
        #if os(iOS)
        viewModel.onSelectGeneratedPassword = { [weak self] option in
            guard let self else { return }
            self.extensionContext.completeGeneratePasswordRequest(
                results: [option.generatedPassword],
                completionHandler: nil
            )
        }
        viewModel.onRegeneratePasswords = { [weak self] in
            guard let self,
                  let request = self.pendingGeneratePasswordsRequest else { return }
            self.viewModel.generatedPasswords = AutoFillPasswordGeneration.options(for: request)
        }

        #endif

        let hostingController = AutoFillHostingController(
            rootView: AutoFillCredentialListView(viewModel: viewModel)
        )
        #if os(iOS)
        hostingController.view.backgroundColor = .clear
        #endif
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hostingController)
        view.addSubview(hostingController.view)
        NSLayoutConstraint.activate([
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        #if os(iOS)
        hostingController.didMove(toParent: self)
        #endif
        self.hostingController = hostingController
    }

    private func showLoading(message: String) {
        viewModel.state = .loading(message)
    }

    private func showError(_ message: String) {
        viewModel.state = .error(message)
    }

    private func cancelRequest(code: ASExtensionError.Code) {
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: code.rawValue
        ))
    }
}

private enum AutoFillCredentialListKind: Equatable {
    case password
    case oneTimeCode
    case passkey
}

private enum AutoFillCredentialListState {
    case loading(String)
    case credentials(String)
    case retry(String)
    case passkeyRegistration(String)
    case passwordSave(String)
    case passwordGeneration(String)
    case configuration(String)
    case error(String)
}

#if os(iOS)
@available(iOSApplicationExtension 26.2, *)
private struct AutoFillGeneratedPasswordOption: Identifiable {
    let id = UUID()
    let kind: ASGeneratedPassword.Kind
    let value: String

    var generatedPassword: ASGeneratedPassword {
        ASGeneratedPassword(kind: kind, value: value)
    }

    var title: String { generatedPassword.localizedName }
}

#endif

@available(iOSApplicationExtension 26.2, *)
private enum AutoFillPasswordGeneration {
    private struct Policy {
        var minimumLength = 16
        var maximumLength = 64
        var requiresUpper = true
        var requiresLower = true
        var requiresDigit = true
        var requiresSpecial = true
        var allowsUpper = true
        var allowsLower = true
        var allowsDigit = true
        var allowsSpecial = true
        var extraAllowedCharacters: [Character] = []
        var hasExplicitRules = false
    }

    private static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")
    private static let lower = Array("abcdefghijkmnopqrstuvwxyz")
    private static let digits = Array("23456789")
    private static let special = Array("!@#$%^&*()-_=+")
    private static let words = [
        "amber", "atlas", "bamboo", "breeze", "canyon", "cedar", "comet", "coral",
        "ember", "falcon", "forest", "harbor", "indigo", "jungle", "lantern", "maple",
        "meadow", "meteor", "ocean", "orbit", "pebble", "raven", "river", "silver",
        "solar", "summit", "thunder", "violet", "willow", "zephyr"
    ]

    #if os(iOS)
    static func results(for request: ASGeneratePasswordsRequest) -> [ASGeneratedPassword] {
        options(for: request).map(\.generatedPassword)
    }

    static func options(for request: ASGeneratePasswordsRequest) -> [AutoFillGeneratedPasswordOption] {
        let rules = request.passwordFieldPasswordRules
            ?? request.confirmPasswordFieldPasswordRules
            ?? request.passwordRulesFromQuirks
        let policy = policy(from: rules)
        var values = [
            AutoFillGeneratedPasswordOption(
                kind: .strong,
                value: generatedPassword(policy: policy, includeSpecial: policy.allowsSpecial)
            ),
            AutoFillGeneratedPasswordOption(
                kind: policy.requiresSpecial ? .strong : .alphanumeric,
                value: generatedPassword(
                    policy: policy,
                    includeSpecial: policy.requiresSpecial
                )
            )
        ]
        if !policy.hasExplicitRules {
            values.append(AutoFillGeneratedPasswordOption(kind: .passphrase, value: passphrase()))
        } else {
            values.append(AutoFillGeneratedPasswordOption(
                kind: .strong,
                value: generatedPassword(policy: policy, includeSpecial: policy.allowsSpecial)
            ))
        }
        return values
    }

    #endif

    static func strongPassword(rules: String?) -> String {
        let value = policy(from: rules)
        return generatedPassword(policy: value, includeSpecial: value.allowsSpecial)
    }

    static func username() -> String {
        let first = words.randomElement() ?? "silent"
        let second = words.randomElement() ?? "orbit"
        return "\(first).\(second).\(Int.random(in: 100...999))"
    }

    private static func policy(from rules: String?) -> Policy {
        guard let rules, !rules.isEmpty else { return Policy() }
        var policy = Policy()
        policy.hasExplicitRules = true
        var explicitRequired = false
        var explicitAllowed = false

        for rawSegment in rules.lowercased().split(separator: ";") {
            let pair = rawSegment.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = Set(value.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            })

            switch key {
            case "minlength":
                if let length = Int(value) { policy.minimumLength = max(4, min(length, 128)) }
            case "maxlength":
                if let length = Int(value) { policy.maximumLength = max(4, min(length, 128)) }
            case "required":
                if !explicitRequired {
                    policy.requiresUpper = false
                    policy.requiresLower = false
                    policy.requiresDigit = false
                    policy.requiresSpecial = false
                    explicitRequired = true
                }
                policy.requiresUpper = policy.requiresUpper || tokens.contains("upper")
                policy.requiresLower = policy.requiresLower || tokens.contains("lower")
                policy.requiresDigit = policy.requiresDigit || tokens.contains("digit")
                policy.requiresSpecial = policy.requiresSpecial || tokens.contains("special")
            case "allowed":
                if !explicitAllowed {
                    policy.allowsUpper = false
                    policy.allowsLower = false
                    policy.allowsDigit = false
                    policy.allowsSpecial = false
                    explicitAllowed = true
                }
                let printable = tokens.contains("ascii-printable") || tokens.contains("unicode")
                policy.allowsUpper = policy.allowsUpper || printable || tokens.contains("upper")
                policy.allowsLower = policy.allowsLower || printable || tokens.contains("lower")
                policy.allowsDigit = policy.allowsDigit || printable || tokens.contains("digit")
                policy.allowsSpecial = policy.allowsSpecial || printable || tokens.contains("special")
                let known = Set(["ascii-printable", "unicode", "upper", "lower", "digit", "special"])
                for token in tokens where !known.contains(token) {
                    policy.extraAllowedCharacters += token.filter {
                        !$0.isWhitespace && $0 != "[" && $0 != "]" && $0 != "'" && $0 != "\""
                    }
                }
            default:
                continue
            }
        }

        policy.allowsUpper = policy.allowsUpper || policy.requiresUpper
        policy.allowsLower = policy.allowsLower || policy.requiresLower
        policy.allowsDigit = policy.allowsDigit || policy.requiresDigit
        policy.allowsSpecial = policy.allowsSpecial || policy.requiresSpecial
        policy.maximumLength = max(policy.minimumLength, policy.maximumLength)
        return policy
    }

    private static func generatedPassword(policy: Policy, includeSpecial: Bool) -> String {
        var generator = SystemRandomNumberGenerator()
        var requiredSets: [[Character]] = []
        if policy.requiresUpper { requiredSets.append(upper) }
        if policy.requiresLower { requiredSets.append(lower) }
        if policy.requiresDigit { requiredSets.append(digits) }
        if policy.requiresSpecial {
            requiredSets.append(policy.extraAllowedCharacters.isEmpty ? special : policy.extraAllowedCharacters)
        }

        var available: [Character] = []
        if policy.allowsUpper { available += upper }
        if policy.allowsLower { available += lower }
        if policy.allowsDigit { available += digits }
        if policy.allowsSpecial && includeSpecial { available += special }
        available += policy.extraAllowedCharacters
        if available.isEmpty { available = upper + lower + digits }

        let preferredLength = min(max(20, policy.minimumLength), policy.maximumLength)
        let length = max(preferredLength, requiredSets.count)
        var output = requiredSets.compactMap { $0.randomElement(using: &generator) }
        while output.count < length {
            guard let character = available.randomElement(using: &generator) else { break }
            output.append(character)
        }
        output.shuffle(using: &generator)
        return String(output)
    }

    private static func passphrase() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<5).compactMap { _ in words.randomElement(using: &generator) }.joined(separator: "-")
    }
}

@MainActor
private final class AutoFillCredentialListViewModel: ObservableObject {
    @Published var state: AutoFillCredentialListState = .loading(L10n.string("Preparing AutoFill…"))
    @Published var credentials: [AutoFillCredentialRecord] = []
    @Published var serviceIdentifiers: [String] = []
    @Published var defaultURIMatchType: AutoFillURIMatchType = .baseDomain
    @Published var showsWebsiteIcons = true
    @Published var websiteIconServerURL: URL?
    @Published var searchText = ""
    @Published var showsAllCredentials = false
    @Published var avatarInitial = "V"
    @Published var accountDisplayName = L10n.string("Vaultwarden account")
    @Published var registrationRelyingParty = ""
    @Published var registrationUserName = ""
    #if os(iOS)
    @Published var generatedPasswords: [AutoFillGeneratedPasswordOption] = []
    #endif
    @Published var kind: AutoFillCredentialListKind = .password
    @Published var primaryActionTitle = L10n.string("Continue")
    @Published var isPresentingCreate = false
    @Published var isSavingNewLogin = false
    @Published var newLoginName = ""
    @Published var newLoginUsername = ""
    @Published var newLoginPassword = ""
    @Published var newLoginURI = ""
    @Published var newLoginFavorite = false
    @Published var newLoginTOTPSecret = ""
    @Published var newLoginFolderID = ""
    @Published var newLoginNotes = ""
    @Published var newLoginCustomFields: [AutoFillNewCustomField] = []
    @Published var folders: [AutoFillFolderRecord] = []
    @Published var createError: String?

    var onCancel: () -> Void = {}
    var onAdd: () -> Void = {}
    var onAccount: () -> Void = {}
    var onPrimaryAction: () -> Void = {}
    var onSelect: (AutoFillCredentialRecord) -> Void = { _ in }
    var onDidSaveNewLogin: (AutoFillCredentialRecord) -> Void = { _ in }
    var onCancelCreate: () -> Void = {}
    #if os(iOS)
    var onSelectGeneratedPassword: (AutoFillGeneratedPasswordOption) -> Void = { _ in }
    var onRegeneratePasswords: () -> Void = {}
    #endif
    var onSaveNewLogin: (AutoFillNewLoginInput) async throws -> AutoFillCredentialRecord = { _ in
        throw AutoFillCreateLoginError.unavailable
    }

    var filteredCredentials: [AutoFillCredentialRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            guard hasRequestContext, !showsAllCredentials else { return credentials }
            return credentials
                .filter {
                    $0.bestMatch(
                        serviceIdentifiers: serviceIdentifiers,
                        defaultMatchType: defaultURIMatchType
                    ) != nil
                }
                .sorted { lhs, rhs in
                    let lhsMatch = lhs.bestMatch(
                        serviceIdentifiers: serviceIdentifiers,
                        defaultMatchType: defaultURIMatchType
                    )
                    let rhsMatch = rhs.bestMatch(
                        serviceIdentifiers: serviceIdentifiers,
                        defaultMatchType: defaultURIMatchType
                    )
                    if lhsMatch != rhsMatch { return (lhsMatch ?? .baseDomain) > (rhsMatch ?? .baseDomain) }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
        }
        return credentials.filter { credential in
            credential.name.localizedCaseInsensitiveContains(query)
                || credential.username.localizedCaseInsensitiveContains(query)
                || (credential.serviceIdentifier?.localizedCaseInsensitiveContains(query) ?? false)
                || (credential.uriRules?.contains { rule in
                    rule.uri.localizedCaseInsensitiveContains(query)
                } ?? false)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasRequestContext: Bool {
        serviceIdentifiers.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var requestTarget: String? {
        serviceIdentifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    var noMatchMessage: String {
        if let requestTarget {
            return L10n.format("No saved credential matches “%@” using its URI match rules. Search or show all items to find another credential.", requestTarget)
        }
        return L10n.string("No matching credential was detected. Search or show all items to find another credential.")
    }

    var showsCredentialList: Bool {
        if case .credentials = state { return true }
        return false
    }

    var subtitle: String {
        switch state {
        case let .loading(message), let .credentials(message), let .retry(message),
             let .passkeyRegistration(message), let .passwordSave(message),
             let .passwordGeneration(message), let .configuration(message), let .error(message):
            message
        }
    }

    var canSaveNewLogin: Bool {
        !newLoginName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !newLoginPassword.isEmpty
            && !isSavingNewLogin
    }

    func beginCreate(
        suggestedURI: String,
        suggestedName: String? = nil,
        username: String = "",
        password: String = ""
    ) {
        newLoginURI = suggestedURI
        newLoginUsername = username
        newLoginPassword = password
        newLoginFavorite = false
        newLoginTOTPSecret = ""
        newLoginFolderID = ""
        newLoginNotes = ""
        newLoginCustomFields = []
        createError = nil
        if let suggestedName,
           !suggestedName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newLoginName = suggestedName
        } else if let host = URL(string: suggestedURI)?.host
            ?? URL(string: "https://\(suggestedURI)")?.host {
            newLoginName = host
        } else {
            newLoginName = suggestedURI
        }
        isPresentingCreate = true
    }

    func saveNewLogin() async {
        guard canSaveNewLogin else { return }
        isSavingNewLogin = true
        createError = nil
        do {
            let record = try await onSaveNewLogin(AutoFillNewLoginInput(
                name: newLoginName,
                username: newLoginUsername,
                password: newLoginPassword,
                uri: newLoginURI,
                favorite: newLoginFavorite,
                totpSecret: newLoginTOTPSecret,
                folderID: newLoginFolderID.isEmpty ? nil : newLoginFolderID,
                notes: newLoginNotes,
                customFields: newLoginCustomFields
            ))
            isSavingNewLogin = false
            isPresentingCreate = false
            onDidSaveNewLogin(record)
        } catch {
            isSavingNewLogin = false
            createError = error.localizedDescription
        }
    }

    func generatePassword() {
        newLoginPassword = AutoFillPasswordGeneration.strongPassword(rules: nil)
    }
}

private struct AutoFillCredentialListView: View {
    @ObservedObject var viewModel: AutoFillCredentialListViewModel

    var body: some View {
        #if os(macOS)
        // Safari hosts this view inside its own sheet, without an app toolbar.
        // Keep navigation and dismissal inside the hosted content itself.
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vaultwarden").font(.headline)
                    Text(viewModel.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(action: viewModel.onCancel) {
                    Label("Close", systemImage: "xmark")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel("Close AutoFill")
            }
            .padding(16)

            if viewModel.showsCredentialList {
                VStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Search all available credentials", text: $viewModel.searchText)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Search credentials")
                        if !viewModel.searchText.isEmpty {
                            Button { viewModel.searchText = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    if viewModel.hasRequestContext && !viewModel.credentials.isEmpty {
                        Picker("Show credentials", selection: $viewModel.showsAllCredentials) {
                            Text("Suggested").tag(false)
                            Text("All Items").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
            }
            Divider()
            Group {
                if viewModel.showsCredentialList { credentialList }
                else { statusContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if viewModel.showsCredentialList && viewModel.kind == .password {
                Divider()
                HStack {
                    Button(action: viewModel.onAdd) {
                        Label("New Password", systemImage: "plus")
                    }
                    Spacer()
                }
                .padding(16)
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .sheet(isPresented: $viewModel.isPresentingCreate) {
            AutoFillNewLoginView(viewModel: viewModel)
                .frame(minWidth: 500, minHeight: 560)
        }
        #else
        NavigationStack {
            Group {
                if viewModel.showsCredentialList {
                    credentialList
                        .searchable(
                            text: $viewModel.searchText,
                            placement: .toolbar,
                            prompt: "Search"
                        )
                        .searchToolbarBehavior(.automatic)
                        .searchPresentationToolbarBehavior(.avoidHidingContent)
                } else {
                    statusContent
                }
            }
            .navigationTitle("Vaultwarden")
            .navigationSubtitle(viewModel.subtitle)
            .autoFillInlineToolbarTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: viewModel.onCancel) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close AutoFill")
                }

                if viewModel.showsCredentialList {
                    ToolbarItem(placement: .primaryAction) {
                        Button(action: viewModel.onAdd) {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create new password")
                    }

                    #if os(iOS)
                    DefaultToolbarItem(kind: .search, placement: .bottomBar)
                    #endif
                }
            }
        }
        .sheet(isPresented: $viewModel.isPresentingCreate) {
            AutoFillNewLoginView(viewModel: viewModel)
                #if os(macOS)
                .frame(minWidth: 500, minHeight: 560)
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
        #endif
    }

    @ViewBuilder
    private var credentialList: some View {
        if viewModel.filteredCredentials.isEmpty {
            if viewModel.isSearching {
                ContentUnavailableView.search(text: viewModel.searchText)
            } else if viewModel.credentials.isEmpty {
                ContentUnavailableView(
                    "No Credentials",
                    systemImage: "key.slash",
                    description: Text("No compatible credentials are available. Open Vaultwarden and sync your vault, then try AutoFill again.")
                )
            } else {
                ContentUnavailableView {
                    Label("No Matching Credentials", systemImage: "magnifyingglass")
                } description: {
                    Text(viewModel.noMatchMessage)
                } actions: {
                    Button("Show All Items") { viewModel.showsAllCredentials = true }
                        .buttonStyle(.bordered)
                }
            }
        } else {
            List {
                Section {
                    ForEach(viewModel.filteredCredentials) { credential in
                        Button {
                            viewModel.onSelect(credential)
                        } label: {
                            AutoFillCredentialRow(
                                credential: credential,
                                kind: viewModel.kind,
                                showsWebsiteIcon: viewModel.showsWebsiteIcons,
                                serverURL: viewModel.websiteIconServerURL
                            )
                        }
                        .buttonStyle(.plain)
                        .alignmentGuide(.listRowSeparatorLeading) { _ in 55 }
                    }
                }
                #if os(iOS)
                .listSectionSeparator(.hidden, edges: .top)
                #endif
            }
            .listStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case let .loading(message):
            VStack(spacing: 12) {
                ProgressView()
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case let .retry(message):
            ContentUnavailableView {
                #if os(macOS)
                Label("Unlock AutoFill", systemImage: "touchid")
                #else
                Label("Unlock AutoFill", systemImage: "faceid")
                #endif
            } description: {
                Text(message)
            } actions: {
                Button(viewModel.primaryActionTitle, action: viewModel.onPrimaryAction)
                    .buttonStyle(.borderedProminent)
            }
        case let .configuration(message):
            ContentUnavailableView {
                Label("Vaultwarden AutoFill", systemImage: "key.fill")
            } description: {
                Text(message)
            } actions: {
                Button(viewModel.primaryActionTitle, action: viewModel.onPrimaryAction)
                    .buttonStyle(.borderedProminent)
            }
        case let .passkeyRegistration(message):
            ContentUnavailableView {
                Label("Create Passkey", systemImage: "person.badge.key.fill")
            } description: {
                VStack(spacing: 8) {
                    Text(viewModel.registrationRelyingParty)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if !viewModel.registrationUserName.isEmpty {
                        Text(viewModel.registrationUserName)
                    }
                    Text(message)
                        .padding(.top, 4)
                }
            } actions: {
                Button(viewModel.primaryActionTitle, action: viewModel.onPrimaryAction)
                    .buttonStyle(.borderedProminent)
            }
        case let .passwordSave(message):
            ContentUnavailableView {
                Label("Save Password", systemImage: "key.fill")
            } description: {
                Text(message)
            }
        case .passwordGeneration:
            #if os(iOS)
            generatedPasswordChoices
            #else
            EmptyView()
            #endif
        case let .error(message):
            ContentUnavailableView {
                Label("AutoFill Unavailable", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(message)
            }
        case .credentials:
            EmptyView()
        }
    }

    #if os(iOS)
    private var generatedPasswordChoices: some View {
        List {
            Section {
                ForEach(viewModel.generatedPasswords) { option in
                    Button {
                        viewModel.onSelectGeneratedPassword(option)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(option.title)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(option.value)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            } footer: {
                Text("Tap a password to insert it into the website or app.")
            }

            Section {
                Button(action: viewModel.onRegeneratePasswords) {
                    Label("Generate New Options", systemImage: "arrow.clockwise")
                }
            }
        }
        .listStyle(.insetGrouped)
    }
    #endif
}

private struct AutoFillNewLoginView: View {
    @ObservedObject var viewModel: AutoFillCredentialListViewModel
    @State private var usernameSuggestion = AutoFillPasswordGeneration.username()
    @State private var passwordSuggestion = AutoFillPasswordGeneration.strongPassword(rules: nil)
    #if os(macOS)
    @State private var isKeyboardVisible = true
    #else
    @State private var isKeyboardVisible = false
    #endif
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case name
        case username
        case password
        case uri
        case totp
    }

    private enum SuggestionKind: Hashable {
        case username
        case password

        var title: String {
            switch self {
            case .username: "Username Suggestion"
            case .password: "Strong Password Suggestion"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AutoFillLabeledFormField(
                        "Name",
                        text: $viewModel.newLoginName,
                        placeholder: "Enter item name",
                        textContentType: .name
                    )
                    .focused($focusedField, equals: .name)
                    Toggle("Favorite", isOn: $viewModel.newLoginFavorite)
                }

                Section("Credentials") {
                    AutoFillLabeledFormField(
                        "Username",
                        text: $viewModel.newLoginUsername,
                        placeholder: "Enter username",
                        textContentType: .username,
                        capitalization: .never,
                        autocorrectionDisabled: true
                    )
                    .focused($focusedField, equals: .username)
                    AutoFillLabeledFormField(
                        "Password",
                        text: $viewModel.newLoginPassword,
                        placeholder: "Enter password",
                        isSecure: true,
                        textContentType: .newPassword
                    )
                    .focused($focusedField, equals: .password)
                    Button("Generate Password", action: viewModel.generatePassword)
                }

                Section("Website") {
                    AutoFillLabeledFormField(
                        "Website URI",
                        text: $viewModel.newLoginURI,
                        placeholder: "https://example.com",
                        keyboardType: .URL,
                        textContentType: .URL,
                        capitalization: .never,
                        autocorrectionDisabled: true
                    )
                    .focused($focusedField, equals: .uri)
                }

                Section("Authenticator") {
                    AutoFillLabeledFormField(
                        "TOTP Secret",
                        text: $viewModel.newLoginTOTPSecret,
                        placeholder: "Optional",
                        capitalization: .characters,
                        autocorrectionDisabled: true
                    )
                    .focused($focusedField, equals: .totp)
                }

                Section("Organization") {
                    Picker("Folder", selection: $viewModel.newLoginFolderID) {
                        Text("No Folder").tag("")
                        ForEach(viewModel.folders) { folder in
                            Text(folder.name).tag(folder.id)
                        }
                    }
                }

                Section("Notes") {
                    TextEditor(text: $viewModel.newLoginNotes)
                        .frame(minHeight: 100)
                }

                customFieldsEditor
            }
            #if os(iOS)
            .scrollDismissesKeyboard(.interactively)
            #else
            .formStyle(.grouped)
            .safeAreaInset(edge: .top, spacing: 0) {
                HStack {
                    Button("Cancel", action: viewModel.onCancelCreate)
                        .keyboardShortcut(.cancelAction)
                        .disabled(viewModel.isSavingNewLogin)
                    Spacer()
                    Text("New Password").font(.headline)
                    Spacer()
                    Button("Save") { Task { await viewModel.saveNewLogin() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!viewModel.canSaveNewLogin)
                }
                .padding(16)
                .background(.bar)
            }
            #endif
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isKeyboardVisible, let activeSuggestionKind {
                    AutoFillCredentialSuggestion(
                        title: activeSuggestionKind.title,
                        value: suggestion(for: activeSuggestionKind),
                        onUse: { useSuggestion(for: activeSuggestionKind) },
                        onRegenerate: { refreshSuggestion(for: activeSuggestionKind) }
                    )
                    .id(activeSuggestionKind)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            .navigationTitle("New Item")
            .autoFillInlineToolbarTitle()
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: viewModel.onCancelCreate)
                    .disabled(viewModel.isSavingNewLogin)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        Task { await viewModel.saveNewLogin() }
                    } label: { if viewModel.isSavingNewLogin { ProgressView() } else { Text("Save") } }
                    .disabled(!viewModel.canSaveNewLogin)
                }
            }
            #endif
            .interactiveDismissDisabled(viewModel.isSavingNewLogin)
            .alert("Couldn’t Save Password", isPresented: Binding(
                get: { viewModel.createError != nil },
                set: { if !$0 { viewModel.createError = nil } }
            )) {
                Button("OK", role: .cancel) { viewModel.createError = nil }
            } message: {
                Text(viewModel.createError ?? "")
            }
            #if os(iOS)
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
                isKeyboardVisible = true
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
                isKeyboardVisible = false
            }
            #endif
            .onChange(of: focusedField) { oldValue, newValue in
                guard newValue != oldValue else { return }
                switch newValue {
                case .username:
                    refreshSuggestion(for: .username)
                case .password:
                    refreshSuggestion(for: .password)
                case .name, .uri, .totp, nil:
                    break
                }
            }
            .task {
                focusedField = viewModel.newLoginName.isEmpty ? .name : .username
            }
        }
    }

    private var activeSuggestionKind: SuggestionKind? {
        switch focusedField {
        case .username: .username
        case .password: .password
        case .name, .uri, .totp, nil: nil
        }
    }

    private func suggestion(for kind: SuggestionKind) -> String {
        switch kind {
        case .username: usernameSuggestion
        case .password: passwordSuggestion
        }
    }

    private func refreshSuggestion(for kind: SuggestionKind) {
        switch kind {
        case .username:
            usernameSuggestion = AutoFillPasswordGeneration.username()
        case .password:
            passwordSuggestion = AutoFillPasswordGeneration.strongPassword(rules: nil)
        }
    }

    private func useSuggestion(for kind: SuggestionKind) {
        switch kind {
        case .username:
            viewModel.newLoginUsername = usernameSuggestion
        case .password:
            viewModel.newLoginPassword = passwordSuggestion
        }
    }

    private var customFieldsEditor: some View {
        Section("Custom Fields") {
            ForEach($viewModel.newLoginCustomFields) { $field in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Image(systemName: field.type.icon)
                            .foregroundStyle(.tint)
                            .frame(width: 24)
                        AutoFillLabeledFormField(
                            "Field Name",
                            text: $field.name,
                            placeholder: "Enter a label"
                        )
                        Menu {
                            Picker("Field type", selection: $field.type) {
                                ForEach(AutoFillNewCustomFieldType.allCases) { type in
                                    Label(type.title, systemImage: type.icon).tag(type)
                                }
                            }
                        } label: {
                            Text(field.type.title)
                                .font(.caption.weight(.semibold))
                        }
                    }

                    switch field.type {
                    case .text:
                        AutoFillLabeledFormField("Value", text: $field.value, placeholder: "Enter value")
                    case .hidden:
                        AutoFillLabeledFormField(
                            "Value",
                            text: $field.value,
                            placeholder: "Enter hidden value",
                            isSecure: true
                        )
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
                        viewModel.newLoginCustomFields.removeAll { $0.id == field.id }
                    }
                    .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 6)
            }

            Button {
                viewModel.newLoginCustomFields.append(AutoFillNewCustomField())
            } label: {
                Label("Add Custom Field", systemImage: "plus.circle.fill")
            }
        }
    }

    private func booleanBinding(for value: Binding<String>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue == "true" },
            set: { value.wrappedValue = $0 ? "true" : "false" }
        )
    }
}

private struct AutoFillCredentialSuggestion: View {
    let title: String
    let value: String
    let onUse: () -> Void
    let onRegenerate: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onUse) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.monospaced().weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("Use %@", L10n.string(title).lowercased()))
            .accessibilityValue(value)

            Divider()
                .frame(height: 34)

            Button(action: onRegenerate) {
                Image(systemName: "arrow.clockwise")
                    .frame(width: 32, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
            .accessibilityLabel("Generate another suggestion")
        }
        .frame(maxWidth: .infinity)
    }
}

private struct AutoFillLabeledFormField: View {
    let title: String
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let keyboardType: AutoFillKeyboardType
    let textContentType: AutoFillTextContentType?
    let capitalization: AutoFillCapitalization?
    let autocorrectionDisabled: Bool

    init(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        keyboardType: AutoFillKeyboardType = .default,
        textContentType: AutoFillTextContentType? = nil,
        capitalization: AutoFillCapitalization? = nil,
        autocorrectionDisabled: Bool = false
    ) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.keyboardType = keyboardType
        self.textContentType = textContentType
        self.capitalization = capitalization
        self.autocorrectionDisabled = autocorrectionDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(.body)
            .textContentType(textContentType)
            #if os(iOS)
            .keyboardType(keyboardType)
            .textInputAutocapitalization(capitalization)
            #endif
            .autocorrectionDisabled(autocorrectionDisabled)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }
}

private struct AutoFillCredentialRow: View {
    let credential: AutoFillCredentialRecord
    let kind: AutoFillCredentialListKind
    let showsWebsiteIcon: Bool
    let serverURL: URL?

    var body: some View {
        HStack(spacing: 13) {
            AutoFillCredentialThumbnail(
                credential: credential,
                kind: kind,
                showsWebsiteIcon: showsWebsiteIcon,
                serverURL: serverURL
            )

            VStack(alignment: .leading, spacing: 3) {
                Text(credential.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if kind == .password, credential.totpSecret?.isEmpty == false {
                Image(systemName: "lock.rotation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 7)
        .contentShape(.rect)
    }

    private var secondaryText: String {
        if kind == .oneTimeCode, credential.username.isEmpty {
            return credential.serviceIdentifier ?? "Verification code"
        }
        return credential.username
    }
}

private struct AutoFillCredentialThumbnail: View {
    let credential: AutoFillCredentialRecord
    let kind: AutoFillCredentialListKind
    let showsWebsiteIcon: Bool
    let serverURL: URL?
    @State private var image: AutoFillImage?

    private let size: CGFloat = 42

    private var taskID: String {
        "\(showsWebsiteIcon)|\(serverURL?.absoluteString ?? "")|\(credential.serviceIdentifier ?? "")"
    }

    var body: some View {
        Group {
            if showsWebsiteIcon, let image {
                thumbnailImage(image)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.12)
                    .background(Color.white)
            } else {
                Text(initial)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(iconColor.gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: taskID) {
            image = nil
            guard showsWebsiteIcon,
                  let serverURL,
                  let website = credential.serviceIdentifier,
                  let data = AutoFillSharedVault.cachedWebsiteIconData(
                    website: website,
                    serverURL: serverURL
                  ) else { return }
            image = AutoFillImage(data: data)
        }
        .accessibilityHidden(true)
    }

    private func thumbnailImage(_ image: AutoFillImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }

    private var initial: String {
        String(credential.name.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?")
            .uppercased()
    }

    private var iconColor: Color {
        switch kind {
        case .password: Color(red: 0.12, green: 0.36, blue: 0.88)
        case .oneTimeCode: Color(red: 0.95, green: 0.66, blue: 0.08)
        case .passkey: Color(red: 0.12, green: 0.68, blue: 0.36)
        }
    }
}

private extension View {
    @ViewBuilder
    func autoFillInlineToolbarTitle() -> some View {
        #if os(iOS)
        toolbarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}
