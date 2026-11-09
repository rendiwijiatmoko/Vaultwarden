import SwiftUI

enum TOTPTimeline {
    /// Codes change on whole seconds counted from 1970, so the timeline ticks on them.
    static let start = Date(timeIntervalSince1970: 0)
}

/// The ring beside a code that empties as it nears its change.
struct TOTPCountdownRing: View {
    let date: Date
    let period: Int
    var diameter: CGFloat = 18

    var body: some View {
        let remaining = TOTPDisplay.secondsRemaining(at: date, period: period)
        let safePeriod = Double(max(period, 1))
        // The ring aims at where it will be at the next tick and glides there, so it
        // moves continuously while the view only updates once a second.
        let target = Double(remaining - 1) / safePeriod
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0, target))
                .stroke(remaining <= 5 ? Color.red : Color.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        // A new code springs the ring full again; between codes it glides down.
        .animation(remaining == max(period, 1) ? .spring(duration: 0.5, bounce: 0.2) : .linear(duration: 1), value: remaining)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.format("Code changes in %lld seconds", remaining))
    }
}

/// The Verification Code field on an item's page: the live code, its ring,
/// and tap to copy.
struct VaultCodeField: View {
    let secret: String
    @EnvironmentObject private var store: AppStore
    @State private var copyCount = 0
    @State private var showsCopied = false

    var body: some View {
        TimelineView(.periodic(from: TOTPTimeline.start, by: 1)) { context in
            let code = TOTPGenerator.code(secret: secret, date: context.date)
            Button {
                if let code { copy(code) }
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showsCopied ? L10n.string("Copied") : L10n.string("Verification Code"))
                            .font(.subheadline)
                            .foregroundStyle(showsCopied ? Color.accentColor : Color.secondary)
                        Text(code.map(TOTPDisplay.grouped) ?? L10n.string("Invalid Setup Key"))
                            .font(code == nil ? .body : .title2.monospacedDigit())
                            .foregroundStyle(code == nil ? Color.secondary : Color.primary)
                            .totpCodeTransition(code)
                    }
                    Spacer(minLength: 8)
                    if code != nil {
                        TOTPCountdownRing(date: context.date, period: TOTPGenerator.period(secret: secret), diameter: 22)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .disabled(code == nil)
            .accessibilityLabel(code.map { L10n.format("Verification code %@", $0) } ?? L10n.string("Invalid Setup Key"))
            .accessibilityHint(L10n.string("Copies the code"))
            .contextMenu {
                if let code {
                    Button("Copy Code", systemImage: "doc.on.doc") { copy(code) }
                }
            }
        }
        .vaultHaptic(.success, trigger: copyCount)
    }

    private func copy(_ code: String) {
        Task {
            guard await VaultSensitiveAccess.authorize(store) else { return }
            Clipboard.copy(code)
            copyCount += 1
            let current = copyCount
            withAnimation(VaultMotion.fade) { showsCopied = true }
            try? await Task.sleep(for: .seconds(1.5))
            guard current == copyCount else { return }
            withAnimation(VaultMotion.fade) { showsCopied = false }
        }
    }
}

extension View {
    /// Rolls each digit over to the next code when it changes.
    func totpCodeTransition(_ code: String?) -> some View {
        modifier(TOTPCodeTransition(code: code))
    }
}

private struct TOTPCodeTransition: ViewModifier {
    let code: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .contentTransition(reduceMotion ? .opacity : .numericText())
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.45), value: code)
    }
}
