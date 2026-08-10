import Foundation

/// Recomputes risks that depend on the complete decrypted vault.
/// Password values never leave memory and are not written to logs or analytics.
nonisolated enum VaultSecurityAnalyzer {
    static func analyze(_ items: [VaultItem]) -> [VaultItem] {
        let activeLoginPasswordCounts = items.reduce(into: [String: Int]()) { counts, item in
            guard item.type == .login,
                  !item.isDeleted,
                  !item.isArchived,
                  !item.password.isEmpty else { return }
            counts[item.password, default: 0] += 1
        }

        return items.map { item in
            var analyzed = item

            // These risks are derived from the current vault state and must not
            // remain stale after an edit, archive, restore, or deletion.
            analyzed.risks.remove(.reused)
            analyzed.risks.remove(.unsecured)

            guard item.type == .login, !item.isDeleted, !item.isArchived else {
                return analyzed
            }

            if !item.password.isEmpty,
               activeLoginPasswordCounts[item.password, default: 0] > 1 {
                analyzed.risks.insert(.reused)
            }

            if item.uri.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .hasPrefix("http://") {
                analyzed.risks.insert(.unsecured)
            }

            return analyzed
        }
    }
}
