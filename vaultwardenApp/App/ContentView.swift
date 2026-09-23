import SwiftUI
#if os(macOS)
import AppKit
import AuthenticationServices
#endif

struct ContentView: View {
    @ObservedObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var queuedCodeSetup: OTPAuthSetupRequest?
    @State private var presentedCodeSetup: OTPAuthSetupRequest?
    #if os(macOS)
    @AppStorage("hasRequestedAutoFillSetup") private var hasRequestedAutoFillSetup = false
    @State private var isCheckingAutoFillSetup = false
    #endif

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                if store.isAuthenticated {
                    #if os(macOS)
                    if store.isLocked {
                        LockView()
                            .environmentObject(store)
                            .transition(.opacity)
                    } else {
                        RootSplitView()
                            .environmentObject(store)
                    }
                    #else
                    ZStack {
                        RootSplitView()
                            .environmentObject(store)
                            .blur(radius: store.isLocked ? 12 : 0)
                            .allowsHitTesting(!store.isLocked)
                            .accessibilityHidden(store.isLocked)

                        if store.isLocked {
                            LockView()
                                .environmentObject(store)
                                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                        }
                    }
                    #endif
                } else {
                    AccountSignInView()
                        .environmentObject(store)
                }
            } else {
                OnboardingView {
                    withAnimation(.smooth) {
                        hasCompletedOnboarding = true
                    }
                }
                    .environmentObject(store)
                    .transition(.opacity)
            }
        }
        .overlay {
            if store.isAuthenticated, scenePhase != .active {
                LockView(isPrivacyShield: true)
                    .environmentObject(store)
                    .transition(.opacity)
                    .zIndex(1_000)
            }
        }
        .animation(.snappy, value: store.isLocked)
        .animation(.smooth, value: hasCompletedOnboarding)
        .tint(.vaultBlue)
        .preferredColorScheme(preferredColorScheme)
        .onOpenURL(perform: receiveVerificationCodeSetup)
        .sheet(item: $presentedCodeSetup) { request in
            AddEditVaultItemView(
                prefilledName: request.name,
                prefilledUsername: request.username,
                prefilledTOTPSecret: request.sourceURL.absoluteString
            )
            .environmentObject(store)
        }
        .onAppear {
            #if os(macOS)
            MacVaultLifecycle.start(store: store)
            #endif
            // Migrate installations where the former Settings preview reset this flag.
            // A valid authenticated session must never be sent back through onboarding.
            if store.isAuthenticated && !hasCompletedOnboarding {
                hasCompletedOnboarding = true
            }
        }
        .alert("Vaultwarden", isPresented: Binding(
            get: { store.userFacingNotice != nil },
            set: { if !$0 { store.userFacingNotice = nil } }
        )) {
            Button("OK", role: .cancel) { store.userFacingNotice = nil }
        } message: {
            Text(store.userFacingNotice ?? "")
        }
        .onChange(of: scenePhase) { _, phase in
            #if os(iOS)
            guard hasCompletedOnboarding else { return }
            if phase == .background {
                if store.settings.backgroundRefresh { BackgroundSyncManager.schedule() }
                store.appDidEnterBackground()
            } else if phase == .active {
                Task { await store.refreshAfterBecomingActive() }
            }
            #endif
        }
        .onChange(of: store.isLocked) { _, isLocked in
            if isLocked { presentedCodeSetup = nil }
        }
        .onChange(of: store.isLocked) { _, _ in presentQueuedCodeSetupIfPossible() }
        .onChange(of: store.isAuthenticated) { _, _ in presentQueuedCodeSetupIfPossible() }
        #if os(macOS)
        .task(id: isReadyForAutoFillSetup) {
            await requestAutoFillSetupIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await requestAutoFillSetupIfNeeded() }
        }
        #endif
    }

    #if os(macOS)
    private var isReadyForAutoFillSetup: Bool {
        hasCompletedOnboarding && store.isAuthenticated && !store.isLocked
            && !store.isSyncing && scenePhase == .active
    }

    private func requestAutoFillSetupIfNeeded() async {
        guard isReadyForAutoFillSetup, UnlockPresentationPolicy.isAllowed,
              !hasRequestedAutoFillSetup, !isCheckingAutoFillSetup,
              !Task.isCancelled else { return }
        isCheckingAutoFillSetup = true
        defer { isCheckingAutoFillSetup = false }

        let state = await ASCredentialIdentityStore.shared.state()
        // Login, sync, or focus can change while checking the system setting.
        guard isReadyForAutoFillSetup, UnlockPresentationPolicy.isAllowed,
              !Task.isCancelled else { return }
        // Remember the offer even when declined. AutoFill is app-wide; ask once
        // on this Mac, rather than on every unlock or account sign-in.
        hasRequestedAutoFillSetup = true
        guard !state.isEnabled else { return }
        _ = await ASSettingsHelper.requestToTurnOnCredentialProviderExtension()
    }
    #endif

    private var preferredColorScheme: ColorScheme? {
        switch store.settings.theme {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    private func receiveVerificationCodeSetup(_ url: URL) {
        guard let request = OTPAuthSetupRequest.parse(url) else {
            store.userFacingNotice = "This verification-code setup link is not a valid TOTP configuration."
            return
        }
        queuedCodeSetup = request
        presentQueuedCodeSetupIfPossible()
    }

    private func presentQueuedCodeSetupIfPossible() {
        guard store.isAuthenticated,
              !store.isLocked,
              presentedCodeSetup == nil,
              let request = queuedCodeSetup else { return }
        queuedCodeSetup = nil
        presentedCodeSetup = request
    }

}
