import SwiftUI
#if os(macOS)
import AppKit
#endif

// MARK: - Tokens

enum SettingsSpacing {
    /// Between a glyph and its text, a title and its detail.
    static let tight: CGFloat = 4
    /// Inside a row.
    static let standard: CGFloat = 8
    /// Between a tile and its text.
    static let row: CGFloat = 12
    /// Around a setup screen's blocks.
    static let section: CGFloat = 24
}

/// Named for what moves. Every one is under 0.35 s.
enum SettingsMotion {
    /// A value changing in place: a status, a step's badge, a button's label.
    static let flip: Animation = .snappy(duration: 0.22, extraBounce: 0)
    /// Rows and sections arriving or leaving.
    static let row: Animation = .smooth(duration: 0.28)
    /// Opacity only, for Reduce Motion.
    static let contentFade: Animation = .easeOut(duration: 0.22)

    static func row(reduceMotion: Bool) -> Animation {
        reduceMotion ? contentFade : row
    }
}

// MARK: - Icon tile

/// The filled, rounded tile Settings puts before a row. Scales with Dynamic Type.
struct SettingsIconTile: View {
    var systemImage: String
    var color: Color = .accentColor
    /// Side at the default text size: 28 in rows, 64 (iPhone) or 40 (Mac) in a hero.
    var baseSide: CGFloat = 28

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var side: CGFloat { baseSide * scale }

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: side * 0.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(color.gradient, in: .rect(cornerRadius: side * 0.24, style: .continuous))
            // The row's words carry the meaning; the tile is decoration.
            .accessibilityHidden(true)
    }
}

/// The account's initials in a circle, as Settings shows an Apple Account.
struct AccountAvatar: View {
    var email: String
    var baseSide: CGFloat = 56

    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    private var side: CGFloat { baseSide * scale }

    var body: some View {
        let initials = SettingsWords.initials(for: email)
        ZStack {
            Circle().fill(Color.gray.gradient)
            if initials.isEmpty {
                Image(systemName: "person.fill")
                    .font(.system(size: side * 0.46))
            } else {
                Text(initials)
                    .font(.system(size: side * 0.4, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}

// MARK: - Legible colored text

/// A tint made readable as text: 4.5:1, or 7:1 with Increase Contrast. System orange
/// and green mostly fail as text on a grouped background without this.
nonisolated struct LegibleInk: ShapeStyle {
    var tint: Color

    func resolve(in environment: EnvironmentValues) -> Color {
        let isDark = environment.colorScheme == .dark
        let target: Float = environment.colorSchemeContrast == .increased ? 7 : 4.5
        // The hardest common background: grouped gray in light, the cell in dark.
        let surface = isDark
            ? Color.Resolved(red: 0.110, green: 0.110, blue: 0.118)
            : Color.Resolved(red: 0.949, green: 0.949, blue: 0.969)
        let destination = isDark
            ? Color.Resolved(red: 1, green: 1, blue: 1)
            : Color.Resolved(red: 0, green: 0, blue: 0)
        var candidate = tint.resolve(in: environment)
        let start = candidate
        var amount: Float = 0
        while candidate.settingsContrast(against: surface) < target && amount < 1 {
            amount = min(1, amount + 0.03)
            candidate = start.settingsMixed(with: destination, by: amount)
        }
        return Color(candidate)
    }
}

extension ShapeStyle where Self == LegibleInk {
    static func ink(_ tint: Color) -> LegibleInk { LegibleInk(tint: tint) }
}

nonisolated extension Color.Resolved {
    func settingsMixed(with other: Color.Resolved, by amount: Float) -> Color.Resolved {
        Color.Resolved(
            red: red + (other.red - red) * amount,
            green: green + (other.green - green) * amount,
            blue: blue + (other.blue - blue) * amount,
            opacity: opacity
        )
    }

    var settingsLuminance: Float {
        0.2126 * linearRed + 0.7152 * linearGreen + 0.0722 * linearBlue
    }

    func settingsContrast(against other: Color.Resolved) -> Float {
        let a = settingsLuminance, b = other.settingsLuminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

extension StatusTone {
    func apply(to text: Text) -> Text {
        switch self {
        case .plain: text
        case .attention: text.foregroundStyle(.ink(.orange))
        case .failure: text.foregroundStyle(.ink(.red))
        }
    }
}

// MARK: - Hero

/// The top of a settings page: its tile, its name, and one line on how it stands.
/// iPhone centers it, as Settings opens a feature; the Mac sets it in a row with room
/// for one control, as System Settings' panes do.
struct SettingsHero<Icon: View, Accessory: View>: View {
    var title: Text
    var subtitle: Text
    var icon: Icon
    var accessory: Accessory

    static var tileSide: CGFloat {
        #if os(macOS)
        40
        #else
        64
        #endif
    }

    init(
        title: Text,
        subtitle: Text,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon()
        self.accessory = accessory()
    }

    var body: some View {
        Section {
            #if os(macOS)
            HStack(spacing: SettingsSpacing.row) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                Spacer(minLength: SettingsSpacing.standard)
                accessory
            }
            .padding(.vertical, 2)
            #else
            VStack(spacing: SettingsSpacing.row) {
                icon
                VStack(spacing: SettingsSpacing.tight) {
                    title
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    subtitle
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .contentTransition(.opacity)
                }
                accessory
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, SettingsSpacing.tight)
            .listRowBackground(Color.clear)
            #endif
        }
    }
}

extension SettingsHero where Icon == SettingsIconTile {
    init(
        _ title: Text,
        subtitle: Text,
        systemImage: String,
        tint: Color,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.init(title: title, subtitle: subtitle) {
            SettingsIconTile(systemImage: systemImage, color: tint, baseSide: Self.tileSide)
        } accessory: {
            accessory()
        }
    }
}

extension SettingsHero where Icon == SettingsIconTile, Accessory == EmptyView {
    init(_ title: Text, subtitle: Text, systemImage: String, tint: Color) {
        self.init(title, subtitle: subtitle, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

// MARK: - Rows

/// A row that leads to a page: a tile, a name, and where it stands at the trailing edge.
struct SettingsRowLabel: View {
    var title: Text
    var systemImage: String
    var tint: Color
    var value: Text?

    init(_ title: Text, systemImage: String, tint: Color, value: Text? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.tint = tint
        self.value = value
    }

    var body: some View {
        LabeledContent {
            if let value {
                value.contentTransition(.opacity)
            }
        } label: {
            Label {
                title
            } icon: {
                SettingsIconTile(systemImage: systemImage, color: tint)
            }
        }
    }
}

/// A name with one line under it, an optional tile before and a control after, all
/// centered on the middle of the text block. `Toggle` and `LabeledContent` hang a
/// two-line label from its first line, which leaves the control riding high.
struct SettingsDetailRow<Trailing: View>: View {
    var title: Text
    var detail: Text
    var systemImage: String?
    var tint: Color
    var trailing: Trailing

    init(
        title: Text,
        detail: Text,
        systemImage: String? = nil,
        tint: Color = .accentColor,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: SettingsSpacing.row) {
            if let systemImage {
                SettingsIconTile(systemImage: systemImage, color: tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                title
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Separators start under the text, as they do after a Label's icon.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            trailing
        }
        .padding(.vertical, 2)
    }
}

extension SettingsDetailRow where Trailing == EmptyView {
    init(title: Text, detail: Text, systemImage: String? = nil, tint: Color = .accentColor) {
        self.init(title: title, detail: detail, systemImage: systemImage, tint: tint) { EmptyView() }
    }
}

/// A link that leaves the app, tinted like the rows around it and marked with an arrow.
struct SettingsLinkRow: View {
    var title: Text
    var destination: URL

    var body: some View {
        Link(destination: destination) {
            LabeledContent {
                Image(systemName: "arrow.up.forward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            } label: {
                title.foregroundStyle(Color.primary)
            }
        }
    }
}

/// A status with a symbol, for a row's trailing edge: "✓ Connected", "Couldn't Connect".
struct SettingsStatusBadge: View {
    var text: Text
    var systemImage: String
    var tone: StatusTone

    var body: some View {
        HStack(spacing: SettingsSpacing.tight) {
            Image(systemName: systemImage)
                .accessibilityHidden(true)
            text
        }
        .font(.callout)
        .foregroundStyle(style)
    }

    private var style: AnyShapeStyle {
        switch tone {
        case .plain: AnyShapeStyle(.ink(.green))
        case .attention: AnyShapeStyle(.ink(.orange))
        case .failure: AnyShapeStyle(.ink(.red))
        }
    }
}

// MARK: - Setup steps

/// One numbered step of a first-time setup. Done steps check off, the step to do now
/// leads in the accent, and later ones wait in grey.
struct SetupStepRow<Content: View>: View {
    enum Progress: Equatable { case done, current, upcoming }

    var number: Int
    var title: Text
    var detail: Text
    var progress: Progress
    var content: Content

    @ScaledMetric(relativeTo: .body) private var badge: CGFloat = 26

    init(
        _ number: Int,
        title: Text,
        detail: Text,
        progress: Progress,
        @ViewBuilder content: () -> Content
    ) {
        self.number = number
        self.title = title
        self.detail = detail
        self.progress = progress
        self.content = content()
    }

    var body: some View {
        HStack(alignment: .top, spacing: SettingsSpacing.row) {
            ZStack {
                Circle().fill(badgeFill)
                if progress == .done {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Text(number.formatted())
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(progress == .current ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                }
            }
            .frame(width: badge, height: badge)
            .animation(SettingsMotion.flip, value: progress)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: SettingsSpacing.tight) {
                title
                    .font(.body.weight(.semibold))
                    .foregroundStyle(progress == .upcoming ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                content
                    .padding(.top, SettingsSpacing.tight)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, SettingsSpacing.tight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private var badgeFill: AnyShapeStyle {
        switch progress {
        case .done: AnyShapeStyle(Color.green)
        case .current: AnyShapeStyle(.tint)
        case .upcoming: AnyShapeStyle(.fill.tertiary)
        }
    }

    private var accessibilityTitle: Text {
        switch progress {
        case .done: Text("Step \(number), done")
        case .current: Text("Step \(number)")
        case .upcoming: Text("Step \(number), later")
        }
    }
}

extension SetupStepRow where Content == EmptyView {
    init(_ number: Int, title: Text, detail: Text, progress: Progress) {
        self.init(number, title: title, detail: detail, progress: progress) { EmptyView() }
    }
}

extension SetupStepRow.Progress {
    /// Done, else current once every step before it is done, else waiting.
    static func step(done: Bool, after previous: Bool) -> Self {
        done ? .done : (previous ? .current : .upcoming)
    }
}

// MARK: - Page and pane frames

#if os(iOS)
extension View {
    /// A page that opens on a `SettingsHero`: the bar takes the title only once the
    /// hero has scrolled away, so the name is never on screen twice.
    func settingsPage(_ title: Text) -> some View {
        modifier(SettingsPageTitle(title: title))
    }
}

private struct SettingsPageTitle: ViewModifier {
    var title: Text
    @State private var isHeroHidden = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(isHeroHidden ? title : Text(verbatim: ""))
            .navigationBarTitleDisplayMode(.inline)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                // Roughly the hero's height at the default text size.
                geometry.contentOffset.y + geometry.contentInsets.top > 150
            } action: { _, hidden in
                isHeroHidden = hidden
            }
    }
}
#endif

#if os(macOS)
extension View {
    /// A grouped form at the Settings window's width, as tall as its content up to
    /// what fits on screen, and scrolling past that.
    func settingsPane() -> some View {
        SettingsPaneLayout { self.formStyle(.grouped) }
    }
}

/// The height comes from the form's ideal size, never from anything measured and
/// stored, so AppKit has nothing to loop on.
struct SettingsPaneLayout: Layout {
    static let width: CGFloat = 640

    private var tallest: CGFloat {
        max(420, (NSScreen.main?.visibleFrame.height ?? 900) - 160)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let form = subviews.first else { return .zero }
        let natural = form.sizeThatFits(ProposedViewSize(width: Self.width, height: nil)).height
        return CGSize(width: Self.width, height: min(natural, tallest))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
