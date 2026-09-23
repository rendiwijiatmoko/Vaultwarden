#if os(macOS)
import SwiftUI

/// The compact category cards used in the Mac vault sidebar.
struct MacVaultCategoryTile: View {
    let title: String
    let icon: String
    let color: Color
    let count: Int
    let isSelected: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSelected ? color : .white)
                    .frame(width: 32, height: 32)
                    .background(isSelected ? .white : color, in: Circle())
                Spacer()
                Text(count, format: .number)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
            }
            Text(title)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(isSelected ? .white : .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .leading)
        .background(
            isSelected ? color : Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.055),
            in: RoundedRectangle(cornerRadius: 26, style: .continuous)
        )
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .ignore)
    }
}
#endif
