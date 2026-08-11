import SwiftUI

struct ContentView: View {
    @ObservedObject var store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var queuedCodeSetup: OTPAuthSetupRequest?
    @State private var presentedCodeSetup: OTPAuthSetupRequest?

    var body: some View {
        Group {
            if hasCompletedOnboarding {
                if store.isAuthenticated {
                    ZStack {
                        RootSplitView()
                            .environmentObject(store)
                            .blur(radius: store.isLocked ? 12 : 0)
                            .allowsHitTesting(!store.isLocked)

                        if store.isLocked {
                            LockView()
                                .environmentObject(store)
                                .transition(.opacity.combined(with: .scale(scale: 1.02)))
                        }
                    }
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
            guard hasCompletedOnboarding else { return }
            if phase == .background {
                if store.settings.backgroundRefresh { BackgroundSyncManager.schedule() }
                store.appDidEnterBackground()
            } else if phase == .active {
                Task { await store.refreshAfterBecomingActive() }
            }
        }
        .onChange(of: store.isLocked) { _, _ in presentQueuedCodeSetupIfPossible() }
        .onChange(of: store.isAuthenticated) { _, _ in presentQueuedCodeSetupIfPossible() }
    }

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
