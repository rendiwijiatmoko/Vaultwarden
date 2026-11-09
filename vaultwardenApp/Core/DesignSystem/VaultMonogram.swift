import SwiftUI

/// The letter tile shown for a website without an icon, as Passwords does.
nonisolated enum VaultMonogram {
    /// System colors deep enough that a large white letter reads on them in light
    /// and dark appearance. Light hues are deepened toward black to get there.
    static let palette: [Color] = [
        .blue,
        .indigo,
        .purple,
        .pink,
        .red,
        Color.orange.mix(with: .black, by: 0.28),
        Color.green.mix(with: .black, by: 0.3),
        Color.teal.mix(with: .black, by: 0.3)
    ]

    /// The first letter or digit of the name, else of the host. Nil when neither has one.
    static func letter(name: String, host: String?) -> String? {
        for source in [name, host ?? ""] {
            if let character = source.first(where: { $0.isLetter || $0.isNumber }) {
                return String(String(character).uppercased().prefix(1))
            }
        }
        return nil
    }

    /// A tile's tint, chosen by the host when there is one so every item for a
    /// site shares it, otherwise by the name.
    static func tintSeed(name: String, host: String?) -> String {
        let seed = host ?? name
        return seed.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// A stable index into `palette`. FNV-1a, because `Hasher` is seeded per
    /// launch and a tile must keep its color across launches.
    static func tintIndex(for seed: String, paletteSize: Int = VaultMonogram.palette.count) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Int(hash % UInt64(max(paletteSize, 1)))
    }

    static func tint(for seed: String) -> Color {
        palette[tintIndex(for: seed)]
    }
}
