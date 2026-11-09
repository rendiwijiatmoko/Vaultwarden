import SwiftUI

/// A sidebar row on the Mac and iPad: the section's glyph in its color, then its name.
/// (This file once held the Mac's category tiles, which gave way to a native source list.)
struct VaultSidebarLabel: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
        } icon: {
            Image(systemName: icon)
                .foregroundStyle(color)
        }
    }
}

/// A smart-section tile on the iPhone home screen, in the manner of Reminders and
/// Passwords: the glyph in a colored circle, the count, and the name.
struct VaultCategoryTile: View {
    let title: String
    let icon: String
    let color: Color
    let count: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Image(systemName: icon)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(color.gradient, in: .circle)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                Text(count, format: .number)
                    .font(.title2.bold())
                    .fontDesign(.rounded)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText(value: Double(count)))
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.vaultCard, in: .rect(cornerRadius: 16))
        .contentShape(.rect(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(Text(count, format: .number))
    }
}
