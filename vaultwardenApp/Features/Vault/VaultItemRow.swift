import SwiftUI

enum VaultRowMetrics {
    #if os(macOS)
    static let iconSize: CGFloat = 32
    static let verticalPadding: CGFloat = 3
    #else
    static let iconSize: CGFloat = 40
    static let verticalPadding: CGFloat = 4
    #endif
}

/// A list row as Passwords draws it: the tile, the name, and who it's for.
struct VaultItemRow: View {
    let item: VaultItem
    var isSelected = false

    var body: some View {
        HStack(spacing: 12) {
            VaultItemThumbnail(item: item, size: VaultRowMetrics.iconSize)
            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(item.name)
                        .font(.headline)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Color.white : Color.yellow)
                            .accessibilityLabel("Favorite")
                    }
                }
                Text(VaultItemPresentation.subtitle(for: item))
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            // Separators start under the text, past the tile, on every row.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            Spacer(minLength: 0)
            VaultRowBadges(item: item, isSelected: isSelected)
        }
        .padding(.vertical, VaultRowMetrics.verticalPadding)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

/// Quiet trailing marks for what an item holds beyond a password.
private struct VaultRowBadges: View {
    let item: VaultItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 5) {
            if !item.risks.isEmpty, !item.isDeleted {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(isSelected ? Color.white : Color.orange)
                    .accessibilityLabel("Security Recommendation")
            }
            if item.attachments?.isEmpty == false {
                Image(systemName: "paperclip")
                    .accessibilityLabel("Has Attachments")
            }
            if item.passkeyCount > 0 {
                Image(systemName: "person.badge.key.fill")
                    .accessibilityLabel("Passkey")
            }
            if item.organization != nil {
                Image(systemName: "person.2.fill")
                    .accessibilityLabel("Shared")
            }
        }
        .font(.caption)
        .imageScale(.small)
        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
    }
}

/// A row for the Codes list: the live code beside the account, with Copy.
struct TOTPItemRow: View {
    let item: VaultItem
    let secret: String
    var isSelected = false
    var canCopy = true
    var onSelect: (() -> Void)?

    var body: some View {
        TimelineView(.periodic(from: TOTPTimeline.start, by: 1)) { context in
            let code = TOTPGenerator.code(secret: secret, date: context.date) ?? "------"

            HStack(spacing: 12) {
                #if os(macOS)
                rowContent(code: code, date: context.date)
                #else
                if let onSelect {
                    Button(action: onSelect) {
                        rowContent(code: code, date: context.date)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: item.id) {
                        rowContent(code: code, date: context.date)
                    }
                    .buttonStyle(.plain)
                }
                #endif

                if canCopy {
                    AnimatedCopyButton(
                        value: code,
                        accessibilityName: "verification code",
                        color: isSelected ? .white : .accentColor,
                        copiedColor: isSelected ? .white : .green
                    )
                    .font(.body.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func rowContent(code: String, date: Date) -> some View {
        HStack(spacing: 12) {
            VaultItemThumbnail(item: item, size: VaultRowMetrics.iconSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .font(.headline)
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                Text(VaultItemPresentation.subtitle(for: item))
                    .font(.subheadline)
                    .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }

            Spacer(minLength: 4)

            Text(canCopy ? TOTPDisplay.grouped(code) : "••• •••")
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .totpCodeTransition(canCopy ? code : nil)
                .accessibilityLabel(canCopy ? L10n.format("Code %@", code) : L10n.string("Code hidden"))
            TOTPCountdownRing(date: date, period: TOTPGenerator.period(secret: secret))
        }
    }
}
