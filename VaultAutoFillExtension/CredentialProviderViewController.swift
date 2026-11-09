import AuthenticationServices
import Combine
import ImageIO
import LocalAuthentication
import OSLog
import SwiftUI
#if os(macOS)
import AppKit
private typealias AutoFillHostingController = NSHostingController
private enum AutoFillKeyboardType { case `default`, URL }
private enum AutoFillCapitalization { case never, characters }
private typealias AutoFillTextContentType = NSTextContentType
#else
import UIKit
private typealias AutoFillHostingController = UIHostingController
private typealias AutoFillKeyboardType = UIKeyboardType
private typealias AutoFillCapitalization = TextInputAutocapitalization
private typealias AutoFillTextContentType = UITextContentType
#endif

private enum AutoFillHandoffLog {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "VaultAutoFillExtension",
        category: "TextInsertion"
    )
}

final class CredentialProviderViewController: ASCredentialProviderViewController {
    private enum RequestMode {
        case password
        case oneTimeCode
        case textInsert
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
    private var pendingCredentialSelection: AutoFillCredentialSelection?
    private var isRequestCancelled = false
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
    private var listGeneration = 0
    /// Set once a fill starts, so a second tap or Return can't complete the request twice.
    private var isCompletingRequest = false

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
        pendingCredentialSelection = nil
        passkeyRequestParameters = nil
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
        // This callback supports both passwords and passkeys, even when Safari
        // has an active passkey request. Keep passwords available in the picker.
        prepareList(
            mode: .password,
            serviceIdentifiers: serviceIdentifiers,
            passkeyRequestParameters: requestParameters
        )
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
        pendingCredentialSelection = nil
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
        pendingCredentialSelection = nil
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
        pendingCredentialSelection = nil
        pendingSavePasswordRequest = nil
        pendingGeneratePasswordsRequest = generatePasswordsRequest
        passkeyRequestParameters = nil
        serviceIdentifiers = [generatePasswordsRequest.serviceIdentifier.identifier]
        ensureViewLoaded()
        viewModel.generatedPasswords = AutoFillPasswordGeneration.options(for: generatePasswordsRequest)
        viewModel.serviceIdentifiers = serviceIdentifiers
        viewModel.state = .passwordGeneration
    }

    #endif

    override func prepareOneTimeCodeCredentialList(for serviceIdentifiers: [ASCredentialServiceIdentifier]) {
        prepareList(mode: .oneTimeCode, serviceIdentifiers: serviceIdentifiers)
    }

    #if os(iOS)
    override func prepareInterfaceForUserChoosingTextToInsert() {
        prepareList(mode: .textInsert, serviceIdentifiers: [])
    }
    #endif

    override func prepareInterfaceToProvideCredential(for credentialRequest: any ASCredentialRequest) {
        pendingRequest = credentialRequest
        pendingCredentialSelection = nil
        passkeyRequestParameters = nil
        if let request = credentialRequest as? ASPasswordCredentialRequest {
            mode = .password
            pendingCredentialSelection = .password(recordIdentifier: request.credentialIdentity.recordIdentifier)
            serviceIdentifiers = [request.credentialIdentity.serviceIdentifier.identifier]
        } else if let request = credentialRequest as? ASOneTimeCodeCredentialRequest {
            mode = .oneTimeCode
            pendingCredentialSelection = .oneTimeCode(recordIdentifier: request.credentialIdentity.recordIdentifier)
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
        pendingCredentialSelection = .password(recordIdentifier: credentialIdentity.recordIdentifier)
        passkeyRequestParameters = nil
        serviceIdentifiers = [credentialIdentity.serviceIdentifier.identifier]
        unlockVault(reason: L10n.string("Authenticate to fill this credential"))
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
        serviceIdentifiers: [ASCredentialServiceIdentifier],
        passkeyRequestParameters: ASPasskeyCredentialRequestParameters? = nil
    ) {
        self.mode = mode
        pendingRequest = nil
        pendingCredentialSelection = nil
        viewModel.searchText = ""
        viewModel.selectedTextCredential = nil
        self.passkeyRequestParameters = passkeyRequestParameters
        self.serviceIdentifiers = serviceIdentifiers.map(\.identifier)
        let reasonKey: String = switch mode {
        case .oneTimeCode: "Authenticate to choose a verification code"
        case .textInsert: "Authenticate to insert text from your vault"
        case .passkey: "Authenticate to choose a passkey"
        case .passkeyRegistration: "Authenticate to create this passkey"
        case .passwordSave: "Authenticate to save this password"
        default: "Authenticate to choose a password"
        }
        let reason = L10n.string(reasonKey)
        unlockVault(reason: reason)
    }

    private func unlockVault(reason: String) {
        isRequestCancelled = false
        isCompletingRequest = false
        ensureViewLoaded()
        viewModel.biometry = AutoFillBiometry.current
        showLoading(message: nil)
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
        viewModel.state = .loading(nil)
        Task {
            defer { isUnlockingVault = false }
            do {
                let unlocked = try await AutoFillSharedVault.load(reason: reason)
                guard !isRequestCancelled else { return }
                unlockedVault = unlocked
                handleUnlocked(unlocked)
            } catch {
                guard !isRequestCancelled else { return }
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
        let biometry = AutoFillBiometry.current
        viewModel.biometry = biometry
        viewModel.primaryActionTitle = biometry.unlockTitle
        viewModel.state = .retry
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
            credentials = payload.credentials.filter { credential in
                switch mode {
                case .password: credential.isLogin && !credential.password.isEmpty
                case .oneTimeCode: credential.isLogin && credential.totpSecret?.isEmpty == false
                case .textInsert: credential.hasInsertableText
                case .passkey: false
                case .passkeyRegistration: false
                case .passwordSave, .passwordGeneration: false
                case .configuration: credential.isLogin
                }
            }
        }

        if mode == .configuration {
            showConfiguration(payload)
            return
        }
        if let passkeyRequest = pendingRequest as? ASPasskeyCredentialRequest {
            providePasskey(request: passkeyRequest, unlocked: unlocked)
            return
        }

        if let selection = pendingCredentialSelection {
            guard let credential = selection.resolve(in: credentials) else {
                cancelRequest(code: .credentialIdentityNotFound)
                return
            }
            provide(credential, userInitiated: false)
            return
        }

        updateAccountAvatar(payload)
        viewModel.searchText = ""
        viewModel.credentials = credentials
        viewModel.serviceIdentifiers = serviceIdentifiers
        viewModel.showsWebsiteIcons = AutoFillSharedVault.showsWebsiteIcons
        viewModel.websiteIconServerURL = payload.writeSession?.serverURL
        viewModel.folders = payload.folders ?? []
        viewModel.allowsCredentialKindSelection = passkeyRequestParameters != nil
        let kind: AutoFillCredentialListKind = switch mode {
        case .oneTimeCode: .oneTimeCode
        case .textInsert: .textInsert
        case .passkey: .passkey
        case .password, .passkeyRegistration, .passwordSave,
             .passwordGeneration, .configuration: .password
        }
        presentCredentialList(kind: kind, accountReference: payload.accountReference)
    }

    /// Ranks, partitions and indexes the list off the main actor, then shows it.
    private func presentCredentialList(kind: AutoFillCredentialListKind, accountReference: String) {
        listGeneration += 1
        let generation = listGeneration
        let records = credentials
        // Passkeys are already restricted to the request's RP and allow list.
        // URI rules must not demote them on a subdomain page.
        let context: AutoFillPickerContext = mode == .passkey
            ? .allSuggested
            : .services(serviceIdentifiers, defaultMatchType: AutoFillSharedVault.defaultURIMatchType)
        Task { [weak self] in
            let sections = await Task.detached(priority: .userInitiated) {
                AutoFillPicker.sections(
                    records: records,
                    context: context,
                    usage: AutoFillUsageHistory(accountReference: accountReference).snapshot()
                )
            }.value
            guard let self, generation == self.listGeneration, !self.isRequestCancelled else { return }
            self.viewModel.kind = kind
            self.viewModel.setSections(sections)
            self.viewModel.state = .credentials
        }
    }

    #if os(iOS)
    @available(iOSApplicationExtension 26.2, *)
    private func showPasswordSave(
        request: ASSavePasswordRequest,
        payload: AutoFillVaultPayload
    ) {
        updateAccountAvatar(payload)
        viewModel.folders = payload.folders ?? []
        viewModel.serviceIdentifiers = serviceIdentifiers
        viewModel.state = .passwordSave
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
        viewModel.searchText = ""
        viewModel.showsWebsiteIcons = AutoFillSharedVault.showsWebsiteIcons
        viewModel.websiteIconServerURL = payload.writeSession?.serverURL
        viewModel.registrationRelyingParty = identity.relyingPartyIdentifier
        viewModel.registrationUserName = identity.userName
        viewModel.serviceIdentifiers = [identity.relyingPartyIdentifier]
        viewModel.registrationTargets = (payload.passkeyTargets ?? [])
            .filter { $0.matches(identity.relyingPartyIdentifier) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        viewModel.state = .passkeyRegistration
        viewModel.primaryActionTitle = L10n.string("Save Passkey")
        viewModel.onPrimaryAction = { [weak self] in
            guard let self else { return }
            self.viewModel.state = .loading(L10n.string("Saving Passkey…"))
            Task { await self.registerPasskey(request: request, unlocked: unlocked, targetID: nil) }
        }
        viewModel.onSelectPasskeyTarget = { [weak self] target in
            guard let self else { return }
            self.viewModel.state = .loading(L10n.string("Saving Passkey…"))
            Task { await self.registerPasskey(request: request, unlocked: unlocked, targetID: target.id) }
        }
    }

    @available(iOSApplicationExtension 17.0, *)
    private func registerPasskey(
        request: ASPasskeyCredentialRequest,
        unlocked: AutoFillUnlockedVault,
        targetID: String?
    ) async {
        do {
            let result = try await AutoFillPasskeySupport.register(
                request: request,
                unlockedVault: unlocked,
                targetID: targetID
            )
            let oldPayload = unlocked.payload
            let updatedPayload = AutoFillVaultPayload(
                schemaVersion: 4,
                accountReference: oldPayload.accountReference,
                generatedAt: Date(),
                credentials: oldPayload.credentials,
                passkeys: (oldPayload.passkeys ?? []) + [result.passkey],
                passkeyCiphers: (oldPayload.passkeyCiphers ?? []).filter { $0.id != result.cipher.id } + [result.cipher],
                cryptoContext: oldPayload.cryptoContext,
                writeSession: result.writeSession,
                userKey: unlocked.userKey,
                folders: oldPayload.folders,
                passkeyTargets: oldPayload.passkeyTargets
            )
            try await publish(updatedPayload, userKey: unlocked.userKey)
            unlockedVault = AutoFillUnlockedVault(payload: updatedPayload, userKey: unlocked.userKey)
            await replaceCredentialIdentities(updatedPayload)
            await extensionContext.completeRegistrationRequest(using: result.credential)
        } catch {
            showError(error.localizedDescription)
        }
    }

    private func showConfiguration(_ payload: AutoFillVaultPayload) {
        viewModel.state = .configuration(
            passwords: payload.credentials.filter(\.isLogin).count,
            passkeys: payload.passkeys?.count ?? 0
        )
        viewModel.primaryActionTitle = L10n.string("Finish Setup")
        viewModel.onPrimaryAction = { [weak self] in
            guard let self else { return }
            Task {
                await self.replaceCredentialIdentities(payload)
                self.extensionContext.completeExtensionConfigurationRequest()
            }
        }
    }

    private func provide(_ record: AutoFillCredentialRecord, userInitiated: Bool) {
        guard !isCompletingRequest else { return }
        switch mode {
        case .password:
            let credential = ASPasswordCredential(user: record.username, password: record.password)
            beginCompletingFill(of: record.id, userInitiated: userInitiated)
            extensionContext.completeRequest(withSelectedCredential: credential, completionHandler: nil)
        case .oneTimeCode:
            guard let secret = record.totpSecret,
                  let code = AutoFillTOTP.code(secret: secret) else {
                showError(L10n.string("Vaultwarden can’t generate this code. Check its setup key in the app."))
                return
            }
            beginCompletingFill(of: record.id, userInitiated: userInitiated)
            extensionContext.completeOneTimeCodeRequest(
                using: ASOneTimeCodeCredential(code: code),
                completionHandler: nil
            )
        case .textInsert:
            break
        case .passkey:
            guard let unlockedVault,
                  let parameters = passkeyRequestParameters,
                  let selected = unlockedVault.payload.passkeys?.first(where: {
                      $0.credentialID.base64EncodedString() == record.id
                  }) else {
                showError(AutoFillPasskeyError.credentialNotFound.localizedDescription)
                return
            }
            isCompletingRequest = true
            Task {
                do {
                    let credential = try await AutoFillPasskeySupport.assertion(
                        requestParameters: parameters,
                        selectedPasskey: selected,
                        unlockedVault: unlockedVault
                    )
                    guard !isRequestCancelled else { return }
                    beginCompletingFill(of: record.id, userInitiated: userInitiated)
                    await extensionContext.completeAssertionRequest(using: credential)
                } catch {
                    isCompletingRequest = false
                    showError(error.localizedDescription)
                }
            }
        case .passkeyRegistration, .passwordSave, .passwordGeneration, .configuration:
            break
        }
    }

    /// Records the fill for ranking and confirms a tap, just before the request completes.
    private func beginCompletingFill(of recordID: String, userInitiated: Bool) {
        isCompletingRequest = true
        pendingCredentialSelection = nil
        pendingRequest = nil
        recordUse(of: recordID)
        if userInitiated { playFillFeedback() }
    }

    private func recordUse(of recordID: String) {
        guard let reference = unlockedVault?.payload.accountReference else { return }
        AutoFillUsageHistory(accountReference: reference).recordUse(id: recordID)
    }

    private func playFillFeedback() {
        #if os(iOS)
        guard AutoFillSharedVault.hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        #endif
    }

    @available(iOSApplicationExtension 17.0, *)
    private func providePasskey(
        request: ASPasskeyCredentialRequest,
        unlocked: AutoFillUnlockedVault
    ) {
        guard !isCompletingRequest else { return }
        isCompletingRequest = true
        Task {
            do {
                let credential = try await AutoFillPasskeySupport.assertion(
                    request: request,
                    unlockedVault: unlocked
                )
                guard !isRequestCancelled else { return }
                if let identity = request.credentialIdentity as? ASPasskeyCredentialIdentity {
                    recordUse(of: identity.credentialID.base64EncodedString())
                }
                await extensionContext.completeAssertionRequest(using: credential)
            } catch {
                isCompletingRequest = false
                showError(error.localizedDescription)
            }
        }
    }

    private func replaceCredentialIdentities(_ payload: AutoFillVaultPayload) async {
        let usage = AutoFillUsageHistory(accountReference: payload.accountReference).snapshot()
        let identities = AutoFillCredentialIdentityBuilder.identities(for: payload, usage: usage)
        try? await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    /// Sealing the whole index is too slow for the main actor.
    private func publish(_ payload: AutoFillVaultPayload, userKey: Data) async throws {
        try await Task.detached(priority: .userInitiated) {
            try AutoFillSharedVault.publish(payload: payload, userKey: userKey)
        }.value
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
        alert.informativeText = L10n.string("AutoFill uses this Vaultwarden account.")
        alert.addButton(withTitle: L10n.string("Done"))
        alert.beginSheetModal(for: window)
        #else
        let alert = UIAlertController(
            title: accountDisplayName,
            message: L10n.string("AutoFill uses this Vaultwarden account."),
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
            folders: oldPayload.folders,
            passkeyTargets: oldPayload.passkeyTargets
        )
        try await publish(updatedPayload, userKey: unlockedVault.userKey)
        let updatedVault = AutoFillUnlockedVault(payload: updatedPayload, userKey: unlockedVault.userKey)
        self.unlockedVault = updatedVault
        credentials.append(result.record)
        viewModel.credentials = credentials
        if viewModel.showsCredentialList {
            presentCredentialList(kind: viewModel.kind, accountReference: updatedPayload.accountReference)
        }
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
        viewModel.onSelectCredentialKind = { [weak self] kind in
            guard let self,
                  !self.isRequestCancelled,
                  self.passkeyRequestParameters != nil,
                  self.pendingRequest == nil,
                  self.mode == .password || self.mode == .passkey,
                  let unlocked = self.unlockedVault else { return }
            switch kind {
            case .password: self.mode = .password
            case .passkey: self.mode = .passkey
            case .oneTimeCode, .textInsert: return
            }
            self.handleUnlocked(unlocked)
        }
        viewModel.onSelect = { [weak self] credential in
            guard let self else { return }
            if self.mode == .textInsert {
                self.viewModel.selectedTextCredential = AutoFillSelectedCredential(id: credential.id)
            } else {
                self.provide(credential, userInitiated: true)
            }
        }
        #if os(iOS)
        viewModel.onInsertText = { [weak self] credential, field in
            guard let self, self.mode == .textInsert, !self.isCompletingRequest else { return }
            let value: String
            switch field {
            case .username: value = credential.username
            case .password: value = credential.password
            case .oneTimeCode:
                guard let secret = credential.totpSecret,
                      let code = AutoFillTOTP.code(secret: secret) else {
                    self.showError(L10n.string("Vaultwarden can’t generate this code. Check its setup key in the app."))
                    return
                }
                value = code
            case let .saved(field):
                value = field.value
            }
            guard !value.isEmpty else { return }
            self.isCompletingRequest = true
            self.recordUse(of: credential.id)
            self.playFillFeedback()
            let startedAt = ProcessInfo.processInfo.systemUptime
            AutoFillHandoffLog.logger.info("Text insertion handoff started")
            self.extensionContext.completeRequest(withTextToInsert: value, completionHandler: nil)
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
            AutoFillHandoffLog.logger.info("Text insertion API returned in \(elapsed, privacy: .public) ms")
        }
        #endif
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
            if self.mode == .textInsert {
                self.viewModel.selectedTextCredential = AutoFillSelectedCredential(id: record.id)
            } else {
                self.provide(record, userInitiated: true)
            }
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

    private func showLoading(message: String?) {
        viewModel.state = .loading(message)
    }

    private func showError(_ message: String) {
        viewModel.state = .error(message)
    }

    private func cancelRequest(code: ASExtensionError.Code) {
        // A request is cancelled once; a second Cancel does nothing.
        guard !isRequestCancelled else { return }
        isRequestCancelled = true
        pendingCredentialSelection = nil
        pendingRequest = nil
        pendingUnlockReason = nil
        extensionContext.cancelRequest(withError: NSError(
            domain: ASExtensionErrorDomain,
            code: code.rawValue
        ))
    }
}

private enum AutoFillCredentialListKind: Equatable {
    case password
    case oneTimeCode
    case textInsert
    case passkey
}

private struct AutoFillSelectedCredential: Identifiable, Hashable {
    let id: String
}

private enum AutoFillInsertableField: Identifiable {
    case username
    case password
    case oneTimeCode
    case saved(AutoFillTextField)

    var id: String {
        switch self {
        case .username: "username"
        case .password: "password"
        case .oneTimeCode: "oneTimeCode"
        case let .saved(field): "saved|\(field.id)"
        }
    }

    var isPassword: Bool {
        if case .password = self { return true }
        return false
    }

    static func available(for credential: AutoFillCredentialRecord) -> [Self] {
        var fields: [Self] = []
        if credential.isLogin {
            if !credential.username.isEmpty { fields.append(.username) }
            if !credential.password.isEmpty { fields.append(.password) }
            if credential.totpSecret?.isEmpty == false { fields.append(.oneTimeCode) }
        }
        fields.append(contentsOf: (credential.insertableFields ?? []).map(Self.saved))
        return fields
    }

    var title: String {
        switch self {
        case .username: "Username"
        case .password: "Password"
        case .oneTimeCode: "Verification Code"
        case let .saved(field): field.title
        }
    }

    var displayTitle: String {
        if case let .saved(field) = self, field.isCustom == true { return field.title }
        return L10n.string(title)
    }

    var symbol: String {
        switch self {
        case .username: "person"
        case .password: "key"
        case .oneTimeCode: "number"
        case let .saved(field): field.symbol
        }
    }

    var section: String {
        switch self {
        case .username, .password: "Credentials"
        case .oneTimeCode: "Verification Code"
        case let .saved(field): field.section ?? "Other Fields"
        }
    }

    func preview(for credential: AutoFillCredentialRecord) -> String {
        switch self {
        case .username: return credential.username
        case .password: return String(repeating: "•", count: 12)
        case .oneTimeCode: return String(repeating: "•", count: 6)
        case let .saved(field):
            if field.isSensitive == true {
                if credential.itemType == .card, field.title == "Number" {
                    let digits = field.value.filter(\.isNumber)
                    if digits.count > 4 { return "•••• •••• •••• \(digits.suffix(4))" }
                }
                return String(repeating: "•", count: 12)
            }
            return field.value
        }
    }
}

private struct AutoFillFieldSection: Identifiable {
    let title: String
    var fields: [AutoFillInsertableField]
    var id: String { title }
}

private enum AutoFillCredentialListState {
    /// A nil message means the system is asking for Face ID, Touch ID or a passcode.
    case loading(String?)
    case credentials
    case retry
    case passkeyRegistration
    case passwordSave
    case passwordGeneration
    case configuration(passwords: Int, passkeys: Int)
    case error(String)
}

private enum AutoFillBiometry {
    case faceID
    case touchID
    case opticID
    case unavailable

    static var current: Self {
        let context = LAContext()
        // biometryType is only populated after canEvaluatePolicy runs.
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        return switch context.biometryType {
        case .faceID: .faceID
        case .touchID: .touchID
        case .opticID: .opticID
        default: .unavailable
        }
    }

    var symbol: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .unavailable: "lock.fill"
        }
    }

    var unlockTitle: String {
        let key: String = switch self {
        case .faceID: "Unlock with Face ID"
        case .touchID: "Unlock with Touch ID"
        case .opticID: "Unlock with Optic ID"
        case .unavailable: "Unlock"
        }
        return L10n.string(key)
    }
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
    @Published var state: AutoFillCredentialListState = .loading(nil)
    @Published var credentials: [AutoFillCredentialRecord] = []
    /// The ranked sections narrowed by the current search.
    @Published private(set) var visibleSections: AutoFillPickerSections = .empty
    @Published var serviceIdentifiers: [String] = []
    @Published var showsWebsiteIcons = true
    @Published var websiteIconServerURL: URL?
    @Published var searchText = "" {
        didSet {
            guard searchText != oldValue else { return }
            visibleSections = sections.filtered(by: searchText)
        }
    }
    @Published var selectedTextCredential: AutoFillSelectedCredential?
    @Published var avatarInitial = "V"
    @Published var accountDisplayName = L10n.string("Vaultwarden account")
    @Published var registrationRelyingParty = ""
    @Published var registrationUserName = ""
    @Published var registrationTargets: [AutoFillPasskeyTarget] = []
    #if os(iOS)
    @Published var generatedPasswords: [AutoFillGeneratedPasswordOption] = []
    #endif
    @Published var kind: AutoFillCredentialListKind = .password
    @Published var allowsCredentialKindSelection = false
    @Published var biometry: AutoFillBiometry = .unavailable
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

    private var sections: AutoFillPickerSections = .empty

    var onCancel: () -> Void = {}
    var onAdd: () -> Void = {}
    var onAccount: () -> Void = {}
    var onPrimaryAction: () -> Void = {}
    var onSelectPasskeyTarget: (AutoFillPasskeyTarget) -> Void = { _ in }
    var onSelect: (AutoFillCredentialRecord) -> Void = { _ in }
    var onSelectCredentialKind: (AutoFillCredentialListKind) -> Void = { _ in }
    var onInsertText: (AutoFillCredentialRecord, AutoFillInsertableField) -> Void = { _, _ in }
    var onDidSaveNewLogin: (AutoFillCredentialRecord) -> Void = { _ in }
    var onCancelCreate: () -> Void = {}
    #if os(iOS)
    var onSelectGeneratedPassword: (AutoFillGeneratedPasswordOption) -> Void = { _ in }
    var onRegeneratePasswords: () -> Void = {}
    #endif
    var onSaveNewLogin: (AutoFillNewLoginInput) async throws -> AutoFillCredentialRecord = { _ in
        throw AutoFillCreateLoginError.unavailable
    }

    func setSections(_ sections: AutoFillPickerSections) {
        self.sections = sections
        visibleSections = sections.filtered(by: searchText)
    }

    func fill(_ record: AutoFillCredentialRecord) {
        onSelect(record)
    }

    var filteredRegistrationTargets: [AutoFillPasskeyTarget] {
        let needle = AutoFillSearch.normalizedQuery(searchText)
        guard !needle.isEmpty else { return registrationTargets }
        return registrationTargets.filter { target in
            AutoFillSearch.fold(target.name).contains(needle)
                || AutoFillSearch.fold(target.username).contains(needle)
                || target.uriRules.contains { rule in
                    AutoFillSearch.displayHost(rule.uri)?.contains(needle) == true
                        || AutoFillSearch.fold(rule.uri).contains(needle)
                }
        }
    }

    var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var requestHost: String? {
        serviceIdentifiers.compactMap(AutoFillSearch.displayHost).first
    }

    var title: String {
        let key: String = switch state {
        case .credentials:
            switch kind {
            case .password: "Passwords"
            case .passkey: "Passkeys"
            case .oneTimeCode: "Verification Codes"
            case .textInsert: "Choose Item"
            }
        case .passkeyRegistration: "Save Passkey"
        case .passwordSave: "Save Password"
        case .passwordGeneration: "Choose Password"
        case .loading, .retry, .configuration, .error: "Vaultwarden"
        }
        return L10n.string(key)
    }

    /// The website asking, the way Safari names it.
    var subtitle: String {
        switch state {
        case .credentials where kind != .textInsert, .passkeyRegistration, .passwordGeneration:
            requestHost ?? ""
        default:
            ""
        }
    }

    var suggestedHeader: String? {
        visibleSections.isContextual ? L10n.string("Suggested") : nil
    }

    var otherHeader: String? {
        guard visibleSections.isContextual else { return nil }
        return L10n.string(kind == .oneTimeCode ? "Other Codes" : "Other Passwords")
    }

    var emptyTitle: String {
        let key: String = switch kind {
        case .password: "No Passwords"
        case .passkey: "No Passkeys"
        case .oneTimeCode: "No Codes"
        case .textInsert: "No Items"
        }
        return L10n.string(key)
    }

    var emptySymbol: String {
        switch kind {
        case .password: "key"
        case .passkey: "person.badge.key"
        case .oneTimeCode: "lock.rotation"
        case .textInsert: "tray"
        }
    }

    var fillTitle: String {
        let key: String = switch kind {
        case .password, .textInsert: "Fill"
        case .oneTimeCode: "Fill Code"
        case .passkey: "Use Passkey"
        }
        return L10n.string(key)
    }

    var fillSymbol: String {
        switch kind {
        case .password, .textInsert: "key"
        case .oneTimeCode: "number"
        case .passkey: "person.badge.key"
        }
    }

    /// New Password belongs to the password and text lists only, never to passkeys or codes.
    var canCreate: Bool { kind == .password || kind == .textInsert }

    var showsCredentialList: Bool {
        if case .credentials = state { return true }
        return false
    }

    var showsPasskeyTargetList: Bool {
        if case .passkeyRegistration = state { return !registrationTargets.isEmpty }
        return false
    }

    var showsSelectionList: Bool { showsCredentialList || showsPasskeyTargetList }

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
        } else if let host = AutoFillSearch.displayHost(suggestedURI) {
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
    #if os(macOS)
    @State private var macSelection: String?
    @FocusState private var isSearchFocused: Bool
    #endif

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iOSBody
        #endif
    }

    #if os(iOS)
    private var iOSBody: some View {
        NavigationStack {
            Group {
                if viewModel.showsSelectionList {
                    Group {
                        if viewModel.showsPasskeyTargetList { passkeyTargetList }
                        else { credentialList }
                    }
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
            .navigationTitle(viewModel.title)
            .autoFillNavigationSubtitle(viewModel.subtitle)
            .toolbarTitleDisplayMode(.inlineLarge)
            .navigationDestination(item: $viewModel.selectedTextCredential) { selection in
                if let credential = viewModel.credentials.first(where: { $0.id == selection.id }) {
                    textFieldList(for: credential)
                } else {
                    ContentUnavailableView("Item Unavailable", systemImage: "key.slash")
                }
            }
            .toolbar { iOSToolbar }
        }
        .sheet(isPresented: $viewModel.isPresentingCreate) {
            AutoFillNewLoginView(viewModel: viewModel)
        }
    }

    @ToolbarContentBuilder
    private var iOSToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", systemImage: "xmark", action: viewModel.onCancel)
        }
        if viewModel.showsPasskeyTargetList {
            ToolbarItem(placement: .primaryAction) {
                Button("New Login", systemImage: "plus", action: viewModel.onPrimaryAction)
            }
        } else if viewModel.showsCredentialList && viewModel.canCreate {
            ToolbarItem(placement: .primaryAction) {
                Button("New Password", systemImage: "plus", action: viewModel.onAdd)
            }
        }
        if viewModel.showsSelectionList {
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }
    }
    #endif

    #if os(macOS)
    // Safari hosts this view inside its own sheet, without an app toolbar.
    // Keep the title, search and actions inside the hosted content itself.
    private var macBody: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(viewModel.title)
                    .font(.title2.bold())
                if !viewModel.subtitle.isEmpty {
                    Text(viewModel.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 12)

            if viewModel.showsSelectionList {
                macSearchField
            }

            Group {
                if viewModel.showsCredentialList { credentialList }
                else if viewModel.showsPasskeyTargetList { passkeyTargetList }
                else { statusContent }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            macBottomBar
        }
        .frame(minWidth: 480, minHeight: 420)
        .background {
            if viewModel.showsSelectionList {
                Button("Find") { isSearchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: viewModel.visibleSections, initial: true) { _, sections in
            syncMacSelection(with: sections)
        }
        .sheet(isPresented: $viewModel.isPresentingCreate) {
            AutoFillNewLoginView(viewModel: viewModel)
                .frame(minWidth: 500, minHeight: 560)
        }
    }

    private var macSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search", text: $viewModel.searchText)
                .textFieldStyle(.plain)
                .focused($isSearchFocused)
                .onKeyPress(.downArrow) { moveMacSelection(by: 1) }
                .onKeyPress(.upArrow) { moveMacSelection(by: -1) }
            if !viewModel.searchText.isEmpty {
                Button("Clear Search", systemImage: "xmark.circle.fill") {
                    viewModel.searchText = ""
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.quaternary, in: .rect(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .onAppear { isSearchFocused = true }
    }

    private var macBottomBar: some View {
        HStack(spacing: 8) {
            if viewModel.showsCredentialList && viewModel.canCreate {
                Button("New Password", systemImage: "plus", action: viewModel.onAdd)
            } else if viewModel.showsPasskeyTargetList {
                Button("New Login", systemImage: "plus", action: viewModel.onPrimaryAction)
            }
            Spacer()
            Button("Cancel", action: viewModel.onCancel)
                .keyboardShortcut(.cancelAction)
            if viewModel.showsCredentialList && !viewModel.visibleSections.isEmpty {
                Button(viewModel.fillTitle, action: fillMacSelection)
                    .keyboardShortcut(.defaultAction)
                    .disabled(macSelection == nil)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func macCredentialList(_ sections: AutoFillPickerSections) -> some View {
        ScrollViewReader { proxy in
            List(selection: $macSelection) {
                if !sections.suggested.isEmpty {
                    Section {
                        ForEach(sections.suggested) { entry in
                            rowLabel(entry.record, kind: viewModel.kind)
                        }
                    } header: {
                        if let header = viewModel.suggestedHeader { Text(header) }
                    }
                }
                if !sections.other.isEmpty {
                    Section {
                        ForEach(sections.other) { entry in
                            rowLabel(entry.record, kind: viewModel.kind)
                        }
                    } header: {
                        if let header = viewModel.otherHeader { Text(header) }
                    }
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let entry = viewModel.visibleSections.entry(id: id) {
                    Button(viewModel.fillTitle) { viewModel.fill(entry.record) }
                }
            } primaryAction: { ids in
                guard let id = ids.first,
                      let entry = viewModel.visibleSections.entry(id: id) else { return }
                viewModel.fill(entry.record)
            }
            .onChange(of: macSelection) { _, id in
                guard let id else { return }
                proxy.scrollTo(id)
            }
        }
    }

    private func syncMacSelection(with sections: AutoFillPickerSections) {
        let ids = sections.orderedIDs
        if let current = macSelection, ids.contains(current) { return }
        macSelection = ids.first
    }

    private func moveMacSelection(by offset: Int) -> KeyPress.Result {
        guard viewModel.showsCredentialList else { return .ignored }
        let ids = viewModel.visibleSections.orderedIDs
        guard !ids.isEmpty else { return .handled }
        let current = macSelection.flatMap { ids.firstIndex(of: $0) } ?? (offset > 0 ? -1 : 0)
        macSelection = ids[min(max(current + offset, 0), ids.count - 1)]
        return .handled
    }

    private func fillMacSelection() {
        guard let id = macSelection,
              let entry = viewModel.visibleSections.entry(id: id) else { return }
        viewModel.fill(entry.record)
    }
    #endif

    private var credentialList: some View {
        VStack(spacing: 0) {
            if viewModel.allowsCredentialKindSelection {
                Picker("Credential Type", selection: Binding(
                    get: { viewModel.kind },
                    set: { viewModel.onSelectCredentialKind($0) }
                )) {
                    Text("Passwords").tag(AutoFillCredentialListKind.password)
                    Text("Passkeys").tag(AutoFillCredentialListKind.passkey)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                #if os(macOS)
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
                #else
                .padding(.horizontal)
                .padding(.vertical, 8)
                #endif
            }
            credentialListContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(iOS)
        .background(Color(uiColor: .systemGroupedBackground))
        #endif
    }

    @ViewBuilder
    private var credentialListContent: some View {
        let sections = viewModel.visibleSections
        if sections.isEmpty {
            if viewModel.isSearching {
                ContentUnavailableView.search(text: viewModel.searchText)
            } else {
                ContentUnavailableView {
                    Label(viewModel.emptyTitle, systemImage: viewModel.emptySymbol)
                } actions: {
                    #if os(iOS)
                    if viewModel.canCreate {
                        Button("New Password", action: viewModel.onAdd)
                            .buttonStyle(.borderedProminent)
                    }
                    #endif
                }
            }
        } else {
            #if os(macOS)
            macCredentialList(sections)
            #else
            List {
                if !sections.suggested.isEmpty {
                    Section {
                        ForEach(sections.suggested) { entry in
                            credentialRow(entry.record)
                        }
                    } header: {
                        if let header = viewModel.suggestedHeader { Text(header) }
                    }
                }
                if !sections.other.isEmpty {
                    Section {
                        ForEach(sections.other) { entry in
                            credentialRow(entry.record)
                        }
                    } header: {
                        if let header = viewModel.otherHeader { Text(header) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            #endif
        }
    }

    private func rowLabel(_ record: AutoFillCredentialRecord, kind: AutoFillCredentialListKind) -> some View {
        AutoFillCredentialRow(
            record: record,
            kind: kind,
            showsWebsiteIcon: viewModel.showsWebsiteIcons,
            serverURL: viewModel.websiteIconServerURL
        )
    }

    #if os(iOS)
    private func credentialRow(_ record: AutoFillCredentialRecord) -> some View {
        Group {
            if viewModel.kind == .textInsert {
                NavigationLink {
                    textFieldList(for: record)
                } label: {
                    rowLabel(record, kind: .textInsert)
                }
            } else {
                Button {
                    viewModel.fill(record)
                } label: {
                    rowLabel(record, kind: viewModel.kind)
                }
            }
        }
        .contextMenu {
            rowMenu(for: record)
        } preview: {
            AutoFillCredentialPreview(
                record: record,
                kind: viewModel.kind,
                showsWebsiteIcon: viewModel.showsWebsiteIcons,
                serverURL: viewModel.websiteIconServerURL
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.kind == .textInsert, record.isLogin {
                if !record.password.isEmpty {
                    Button("Password", systemImage: "key") {
                        viewModel.onInsertText(record, .password)
                    }
                    .tint(.blue)
                }
                if !record.username.isEmpty {
                    Button("Username", systemImage: "person") {
                        viewModel.onInsertText(record, .username)
                    }
                    .tint(.gray)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(for record: AutoFillCredentialRecord) -> some View {
        switch viewModel.kind {
        case .textInsert:
            if record.isLogin, !record.username.isEmpty {
                Button("Fill Username", systemImage: "person") {
                    viewModel.onInsertText(record, .username)
                }
            }
            if record.isLogin, !record.password.isEmpty {
                Button("Fill Password", systemImage: "key") {
                    viewModel.onInsertText(record, .password)
                }
            }
            if record.isLogin, record.totpSecret?.isEmpty == false {
                Button("Fill Code", systemImage: "number") {
                    viewModel.onInsertText(record, .oneTimeCode)
                }
            }
            Button("Show All Fields", systemImage: "list.bullet") {
                viewModel.selectedTextCredential = AutoFillSelectedCredential(id: record.id)
            }
        case .password, .oneTimeCode, .passkey:
            Button(viewModel.fillTitle, systemImage: viewModel.fillSymbol) {
                viewModel.fill(record)
            }
        }
    }

    private func textFieldList(for credential: AutoFillCredentialRecord) -> some View {
        List {
            Section {
                HStack(spacing: 16) {
                    AutoFillCredentialThumbnail(
                        record: credential,
                        kind: .textInsert,
                        showsWebsiteIcon: viewModel.showsWebsiteIcons,
                        serverURL: viewModel.websiteIconServerURL,
                        size: 54
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(credential.name).font(.title2.bold())
                        Text((credential.itemType ?? .login).localizedTitle)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }

            ForEach(textFieldSections(for: credential)) { group in
                Section {
                    ForEach(group.fields) { field in
                        Button {
                            viewModel.onInsertText(credential, field)
                        } label: {
                            VStack(alignment: .leading, spacing: 7) {
                                if group.title != "Notes" {
                                    Text(field.displayTitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(field.preview(for: credential))
                                    .font(field.isPassword ? .body.monospaced() : .body)
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 3)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(L10n.string("Inserts this value"))
                    }
                } header: {
                    Text(L10n.string(group.title))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(Text(verbatim: ""))
        .toolbarTitleDisplayMode(.inline)
    }

    private func textFieldSections(for credential: AutoFillCredentialRecord) -> [AutoFillFieldSection] {
        var sections: [AutoFillFieldSection] = []
        for field in AutoFillInsertableField.available(for: credential) {
            if let index = sections.firstIndex(where: { $0.title == field.section }) {
                sections[index].fields.append(field)
            } else {
                sections.append(AutoFillFieldSection(title: field.section, fields: [field]))
            }
        }
        return sections
    }
    #endif

    @ViewBuilder
    private var passkeyTargetList: some View {
        if viewModel.filteredRegistrationTargets.isEmpty {
            ContentUnavailableView.search(text: viewModel.searchText)
        } else {
            List {
                Section {
                    ForEach(viewModel.filteredRegistrationTargets) { target in
                        Button {
                            viewModel.onSelectPasskeyTarget(target)
                        } label: {
                            rowLabel(registrationRowCredential(for: target), kind: .password)
                        }
                        #if os(macOS)
                        .buttonStyle(.plain)
                        #endif
                    }
                } header: {
                    Text("Save to Existing Login")
                }
            }
            #if os(macOS)
            .listStyle(.inset)
            #else
            .listStyle(.insetGrouped)
            #endif
        }
    }

    private func registrationRowCredential(for target: AutoFillPasskeyTarget) -> AutoFillCredentialRecord {
        let uri = target.uriRules.first(where: { $0.match != .never })?.uri ?? ""
        return AutoFillCredentialRecord(
            id: target.id,
            name: target.name,
            username: target.username.isEmpty ? viewModel.registrationRelyingParty : target.username,
            password: "",
            serviceIdentifier: AutoFillSearch.displayHost(uri),
            totpSecret: nil,
            uriRules: target.uriRules
        )
    }

    @ViewBuilder
    private var statusContent: some View {
        switch viewModel.state {
        case let .loading(message):
            if let message {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(message)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                // The system's authentication prompt is on screen; show only what it's waiting for.
                Image(systemName: viewModel.biometry.symbol)
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        case .retry:
            ContentUnavailableView {
                Label("Vaultwarden Locked", systemImage: viewModel.biometry.symbol)
            } actions: {
                primaryStatusButton
            }
        case let .configuration(passwords, passkeys):
            ContentUnavailableView {
                Label("Vaultwarden AutoFill", systemImage: "key.fill")
            } description: {
                Text("^[\(passwords) password](inflect: true) · ^[\(passkeys) passkey](inflect: true)")
            } actions: {
                primaryStatusButton
            }
        case .passkeyRegistration:
            ContentUnavailableView {
                Label(
                    viewModel.registrationRelyingParty.isEmpty
                        ? L10n.string("Save Passkey")
                        : viewModel.registrationRelyingParty,
                    systemImage: "person.badge.key.fill"
                )
            } description: {
                if !viewModel.registrationUserName.isEmpty {
                    Text(viewModel.registrationUserName)
                }
            } actions: {
                primaryStatusButton
            }
        case .passwordSave:
            ContentUnavailableView("Save Password", systemImage: "key.fill")
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

    private var primaryStatusButton: some View {
        Button(viewModel.primaryActionTitle, action: viewModel.onPrimaryAction)
            .buttonStyle(.borderedProminent)
            #if os(macOS)
            .keyboardShortcut(.defaultAction)
            #endif
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
                                .font(.body.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 5)
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                Button("New Suggestions", systemImage: "arrow.clockwise", action: viewModel.onRegeneratePasswords)
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
                        "Website",
                        text: $viewModel.newLoginURI,
                        placeholder: "https://example.com",
                        keyboardType: .URL,
                        textContentType: .URL,
                        capitalization: .never,
                        autocorrectionDisabled: true
                    )
                    .focused($focusedField, equals: .uri)
                }

                Section("Verification Code") {
                    AutoFillLabeledFormField(
                        "Setup Key",
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
            .navigationTitle("New Password")
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
    let record: AutoFillCredentialRecord
    let kind: AutoFillCredentialListKind
    let showsWebsiteIcon: Bool
    let serverURL: URL?
    #if os(macOS)
    @State private var isHovered = false
    @Environment(\.backgroundProminence) private var backgroundProminence
    private let iconSize: CGFloat = 28
    #else
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 40
    #endif

    var body: some View {
        HStack(spacing: 12) {
            AutoFillCredentialThumbnail(
                record: record,
                kind: kind,
                showsWebsiteIcon: showsWebsiteIcon,
                serverURL: serverURL,
                size: iconSize
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(record.name)
                    #if os(macOS)
                    .font(.body.weight(.medium))
                    #else
                    .font(.body.weight(.semibold))
                    #endif
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !secondaryText.isEmpty {
                    Text(secondaryText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

            Spacer(minLength: 8)

            if kind == .oneTimeCode, let secret = record.totpSecret, !secret.isEmpty {
                AutoFillLiveCode(secret: secret)
            }
        }
        #if os(macOS)
        .padding(.vertical, 3)
        #else
        .padding(.vertical, 4)
        #endif
        .contentShape(.rect)
        #if os(macOS)
        .background {
            if isHovered && backgroundProminence != .increased {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.quaternary)
                    .padding(.horizontal, -6)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.13)) { isHovered = hovering }
        }
        #endif
        .accessibilityElement(children: .combine)
    }

    private var secondaryText: String {
        if kind == .textInsert, !record.isLogin {
            return (record.itemType ?? .secureNote).localizedTitle
        }
        if record.username.isEmpty {
            return AutoFillSearch.websites(for: record).first ?? ""
        }
        return record.username
    }
}

/// A verification code that updates once a second while it is on screen.
private struct AutoFillLiveCode: View {
    let secret: String
    @ScaledMetric(relativeTo: .body) private var ringSize: CGFloat = 16
    @Environment(\.backgroundProminence) private var backgroundProminence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: Self.wholeSecond, by: 1)) { context in
            let code = AutoFillTOTP.code(secret: secret, date: context.date) ?? ""
            let period = AutoFillTOTP.period(secret: secret)
            let remaining = AutoFillTOTP.secondsRemaining(secret: secret, date: context.date)
            HStack(spacing: 8) {
                Text(AutoFillTOTP.grouped(code))
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(ink)
                    // Digits roll over to the next code.
                    .contentTransition(reduceMotion ? .opacity : .numericText())
                    .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.45), value: code)
                    .accessibilityLabel(Text(verbatim: code.map { String($0) }.joined(separator: " ")))
                AutoFillCountdownRing(fraction: Double(remaining - 1) / Double(max(period, 1)), ink: ink)
                    .frame(width: ringSize, height: ringSize)
                    // Glide between ticks, spring full when a new code starts.
                    .animation(remaining == max(period, 1) ? .spring(duration: 0.5, bounce: 0.2) : .linear(duration: 1), value: remaining)
                    .accessibilityHidden(true)
            }
        }
    }

    /// Tinted ink is unreadable on a selected row's accent highlight.
    private var ink: AnyShapeStyle {
        backgroundProminence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(.tint)
    }

    /// Start ticks on a whole second so the code changes when the period does.
    private static var wholeSecond: Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
    }
}

private struct AutoFillCountdownRing: View {
    let fraction: Double
    let ink: AnyShapeStyle

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(ink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

#if os(iOS)
/// The long-press preview: who the account is and where it's used, never the secret.
private struct AutoFillCredentialPreview: View {
    let record: AutoFillCredentialRecord
    let kind: AutoFillCredentialListKind
    let showsWebsiteIcon: Bool
    let serverURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AutoFillCredentialThumbnail(
                    record: record,
                    kind: kind,
                    showsWebsiteIcon: showsWebsiteIcon,
                    serverURL: serverURL,
                    size: 48
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.name)
                        .font(.headline)
                        .lineLimit(2)
                    if let itemType = record.itemType, itemType != .login {
                        Text(itemType.localizedTitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if !record.username.isEmpty {
                detail(kind == .passkey ? "Website" : "Username", value: record.username)
            }
            if record.isLogin, !record.password.isEmpty {
                detail("Password", value: String(repeating: "•", count: 10))
            }
            let websites = AutoFillSearch.websites(for: record)
            if kind != .passkey, !websites.isEmpty {
                detail(websites.count == 1 ? "Website" : "Websites", value: websites.joined(separator: "\n"))
            }
        }
        .padding(20)
        .frame(width: 320, alignment: .leading)
    }

    private func detail(_ title: LocalizedStringKey, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
        }
    }
}
#endif

private struct AutoFillCredentialThumbnail: View {
    let record: AutoFillCredentialRecord
    let kind: AutoFillCredentialListKind
    let size: CGFloat
    private let request: AutoFillIconRequest?
    @State private var icon: AutoFillDecodedIcon?

    init(
        record: AutoFillCredentialRecord,
        kind: AutoFillCredentialListKind,
        showsWebsiteIcon: Bool,
        serverURL: URL?,
        size: CGFloat
    ) {
        self.record = record
        self.kind = kind
        self.size = size
        var request: AutoFillIconRequest?
        if showsWebsiteIcon, record.isLogin, let serverURL,
           let website = record.serviceIdentifier, !website.isEmpty {
            request = AutoFillIconRequest(website: website, serverURL: serverURL)
        }
        self.request = request
        // A decoded icon draws on the first frame, so scrolling back never flashes the tile.
        _icon = State(initialValue: request.flatMap { AutoFillWebsiteIconCache.shared.cachedIcon(for: $0) })
    }

    var body: some View {
        Group {
            if let icon {
                Image(decorative: icon.cgImage, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(size * 0.12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
            } else if kind == .textInsert, let itemType = record.itemType, itemType != .login {
                Image(systemName: itemType.icon)
                    .font(.system(size: size * 0.45, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Self.color(for: itemType).gradient)
            } else {
                Text(AutoFillLetterTile.initial(for: record.name, host: AutoFillSearch.websites(for: record).first))
                    .font(.system(size: size * 0.44, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(AutoFillTilePalette.color(for: record).gradient)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .task(id: request) {
            guard let request else {
                icon = nil
                return
            }
            if let cached = AutoFillWebsiteIconCache.shared.cachedIcon(for: request) {
                icon = cached
                return
            }
            icon = await AutoFillWebsiteIconCache.shared.icon(for: request)
        }
        .accessibilityHidden(true)
    }

    private static func color(for itemType: AutoFillItemType) -> Color {
        switch itemType {
        case .secureNote: Color(red: 0.92, green: 0.48, blue: 0.15)
        case .card: Color(red: 0.12, green: 0.67, blue: 0.75)
        case .identity: Color(red: 0.12, green: 0.68, blue: 0.36)
        case .sshKey: Color(red: 0.72, green: 0.24, blue: 0.25)
        case .login: Color(red: 0.12, green: 0.36, blue: 0.88)
        }
    }
}

/// The same palette as the app's `VaultMonogram`: system hues, the light ones
/// deepened so a large white letter still reads.
private enum AutoFillTilePalette {
    static let colors: [Color] = [
        .blue,
        .indigo,
        .purple,
        .pink,
        .red,
        Color.orange.mix(with: .black, by: 0.28),
        Color.green.mix(with: .black, by: 0.3),
        Color.teal.mix(with: .black, by: 0.3)
    ]

    static func color(for record: AutoFillCredentialRecord) -> Color {
        let index = AutoFillLetterTile.paletteIndex(
            host: AutoFillSearch.websites(for: record).first,
            name: record.name,
            paletteCount: colors.count
        )
        return colors[index]
    }
}

private nonisolated struct AutoFillIconRequest: Hashable, Sendable {
    let website: String
    let serverURL: URL
}

private nonisolated struct AutoFillDecodedIcon: @unchecked Sendable {
    let cgImage: CGImage
}

private nonisolated enum AutoFillIconDecoder {
    /// 40 pt at 3x, so a row icon is never upscaled.
    static let maxPixelSize = 120

    static func decode(_ request: AutoFillIconRequest) -> AutoFillDecodedIcon? {
        guard let data = AutoFillSharedVault.cachedWebsiteIconData(
            website: request.website,
            serverURL: request.serverURL
        ),
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return AutoFillDecodedIcon(cgImage: image)
    }
}

/// Decodes each website icon once, off the main actor, and shares in-flight loads
/// between rows that show the same site.
@MainActor
private final class AutoFillWebsiteIconCache {
    static let shared = AutoFillWebsiteIconCache()

    private let capacity = 200
    private var icons: [AutoFillIconRequest: AutoFillDecodedIcon] = [:]
    private var insertionOrder: [AutoFillIconRequest] = []
    private var misses: Set<AutoFillIconRequest> = []
    private var loads: [AutoFillIconRequest: Task<AutoFillDecodedIcon?, Never>] = [:]

    func cachedIcon(for request: AutoFillIconRequest) -> AutoFillDecodedIcon? {
        icons[request]
    }

    func icon(for request: AutoFillIconRequest) async -> AutoFillDecodedIcon? {
        if let icon = icons[request] { return icon }
        if misses.contains(request) { return nil }
        if let load = loads[request] { return await load.value }
        let load = Task.detached(priority: .userInitiated) {
            AutoFillIconDecoder.decode(request)
        }
        loads[request] = load
        let icon = await load.value
        loads[request] = nil
        if let icon {
            store(icon, for: request)
        } else {
            misses.insert(request)
        }
        return icon
    }

    private func store(_ icon: AutoFillDecodedIcon, for request: AutoFillIconRequest) {
        guard icons[request] == nil else { return }
        icons[request] = icon
        insertionOrder.append(request)
        if insertionOrder.count > capacity {
            icons[insertionOrder.removeFirst()] = nil
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

    @ViewBuilder
    func autoFillNavigationSubtitle(_ subtitle: String) -> some View {
        #if os(iOS)
        if subtitle.isEmpty {
            self
        } else {
            navigationSubtitle(subtitle)
        }
        #else
        self
        #endif
    }
}
