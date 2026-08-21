import Foundation

/// Centralizes localization for user-facing strings that SwiftUI cannot infer
/// automatically, such as model titles, status messages, and UIKit labels.
nonisolated enum L10n {
    static func string(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        String(
            format: string(key),
            locale: Locale.current,
            arguments: arguments
        )
    }
}
