import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

extension Color {
    static let vaultBlue = Color(red: 0.12, green: 0.36, blue: 0.88)
    static let vaultGreen = Color(red: 0.12, green: 0.68, blue: 0.36)
    static let vaultYellow = Color(red: 0.95, green: 0.66, blue: 0.08)
    static let vaultCyan = Color(red: 0.12, green: 0.62, blue: 0.78)
    static let vaultRed = Color(red: 0.92, green: 0.22, blue: 0.24)
    static let vaultOrange = Color(red: 0.95, green: 0.48, blue: 0.08)
    #if os(macOS)
    static let vaultBackground = Color(nsColor: .windowBackgroundColor)
    static let vaultCard = Color(nsColor: .controlBackgroundColor)
    #else
    static let vaultBackground = Color(uiColor: .systemGroupedBackground)
    static let vaultCard = Color(uiColor: .secondarySystemGroupedBackground)
    #endif
}

/// Named animations, so the whole app moves the same way. All finish in under 0.35 s.
enum VaultMotion {
    /// A value or control changing in place from the person's own action.
    static let snappy = Animation.snappy(duration: 0.28)
    /// Content replacing a placeholder, or a label swapping its words.
    static let fade = Animation.easeOut(duration: 0.2)
    /// A panel or section opening and closing.
    static let panel = Animation.smooth(duration: 0.32)

    /// Movement is dropped under Reduce Motion; the change still happens.
    static func movement(_ animation: Animation = snappy, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }
}

private struct VaultHapticsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Mirrors Settings > Haptic Feedback for views that have no store.
    var vaultHapticsEnabled: Bool {
        get { self[VaultHapticsEnabledKey.self] }
        set { self[VaultHapticsEnabledKey.self] = newValue }
    }
}

private struct VaultHapticModifier<Trigger: Equatable>: ViewModifier {
    let feedback: SensoryFeedback
    let trigger: Trigger
    @Environment(\.vaultHapticsEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.sensoryFeedback(feedback, trigger: trigger) { _, _ in isEnabled && Clipboard.playsHaptics }
    }
}

extension View {
    /// Plays `feedback` when `trigger` changes. Drive it from a counter the person's
    /// own action increments, never from synced model state.
    func vaultHaptic<Trigger: Equatable>(_ feedback: SensoryFeedback, trigger: Trigger) -> some View {
        modifier(VaultHapticModifier(feedback: feedback, trigger: trigger))
    }
}

struct VaultIcon: View {
    let systemName: String
    let color: Color
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: Circle())
            .accessibilityHidden(true)
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)?

    var body: some View {
        HStack {
            Text(L10n.string(title))
                .font(.title3.bold())
            Spacer()
            if let action {
                Button("See All", action: action)
                    .font(.subheadline.weight(.semibold))
            }
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        ContentUnavailableView(
            L10n.string(title),
            systemImage: icon,
            description: message.isEmpty ? nil : Text(L10n.string(message))
        )
    }
}

enum Clipboard {
    /// Settings > Clear Clipboard. Set by `AppStore` from the person's settings.
    static var clearsAutomatically = true
    /// Settings > Haptic Feedback. `Clipboard` plays nothing itself: the view that
    /// copies plays the confirmation (`vaultHaptic`), which reads this and the
    /// `vaultHapticsEnabled` environment value.
    static var playsHaptics = true

    /// Copies `value`, removed after 30 seconds unless clearing is turned off.
    static func copy(_ value: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Ask clipboard managers to avoid retaining a copied secret.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pasteboard.changeCount
        #else
        let pasteboard = UIPasteboard.general
        var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
        if clearsAutomatically { options[.expirationDate] = Date().addingTimeInterval(30) }
        pasteboard.setItems([["public.utf8-plain-text": value]], options: options)
        let changeCount = pasteboard.changeCount
        #endif
        guard clearsAutomatically else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            // Never erase content copied afterwards, including the same text.
            guard pasteboard.changeCount == changeCount else { return }
            #if os(macOS)
            pasteboard.clearContents()
            #else
            pasteboard.items = []
            #endif
        }
    }
}

struct AnimatedCopyButton: View {
    let value: String
    var title: String?
    var accessibilityName = "value"
    var onCopy: (() -> Void)?
    var fillsWidth = false
    var color: Color = .vaultBlue
    var copiedColor: Color = .vaultGreen
    @State private var copied = false
    @State private var copySequence = 0

    var body: some View {
        Button(action: copy) {
            Group {
                if let title {
                    Label(
                        copied ? L10n.string("Copied") : L10n.string(title),
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                        .contentTransition(.symbolEffect(.replace))
                } else {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied ? copiedColor : color)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .accessibilityLabel(
            copied
                ? L10n.format("%@ copied", L10n.string(accessibilityName))
                : L10n.format("Copy %@", L10n.string(accessibilityName))
        )
        .vaultHaptic(.success, trigger: copySequence)
    }

    private func copy() {
        Clipboard.copy(value)
        onCopy?()
        copySequence += 1
        let currentSequence = copySequence
        withAnimation(VaultMotion.fade) { copied = true }

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard copySequence == currentSequence else { return }
            withAnimation(VaultMotion.fade) { copied = false }
        }
    }
}
