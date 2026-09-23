import SwiftUI

#if os(macOS)
import AppKit

typealias VaultPlatformImage = NSImage
typealias VaultTextContentType = NSTextContentType

/// Software-keyboard hints have no equivalent for the Mac's hardware keyboard.
enum VaultKeyboardType {
    case `default`, URL, emailAddress, numberPad, phonePad
}

enum VaultTextInputAutocapitalization {
    case never, words, sentences, characters
}

enum VaultEditMode: Equatable {
    case inactive, active
    var isEditing: Bool { self == .active }
}
#else
import UIKit

typealias VaultPlatformImage = UIImage
typealias VaultTextContentType = UITextContentType
typealias VaultKeyboardType = UIKeyboardType
typealias VaultTextInputAutocapitalization = TextInputAutocapitalization
typealias VaultEditMode = EditMode
#endif

enum VaultTitleDisplayMode {
    case automatic, inline, inlineLarge, large
}

extension ToolbarItemPlacement {
    static var vaultLeading: ToolbarItemPlacement {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }

    static var vaultTrailing: ToolbarItemPlacement {
        #if os(macOS)
        .primaryAction
        #else
        .topBarTrailing
        #endif
    }

    static var vaultBottomBar: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .bottomBar
        #endif
    }
}

extension Image {
    init(vaultImage image: VaultPlatformImage) {
        #if os(macOS)
        self.init(nsImage: image)
        #else
        self.init(uiImage: image)
        #endif
    }
}

extension View {
    @ViewBuilder
    func vaultNavigationTitleDisplayMode(_ mode: VaultTitleDisplayMode) -> some View {
        #if os(macOS)
        self
        #else
        switch mode {
        case .automatic: navigationBarTitleDisplayMode(.automatic)
        case .inline, .inlineLarge: navigationBarTitleDisplayMode(.inline)
        case .large: navigationBarTitleDisplayMode(.large)
        }
        #endif
    }

    @ViewBuilder
    func vaultToolbarTitleDisplayMode(_ mode: VaultTitleDisplayMode) -> some View {
        #if os(macOS)
        toolbarTitleDisplayMode(.inline)
        #else
        switch mode {
        case .automatic: toolbarTitleDisplayMode(.automatic)
        case .inline: toolbarTitleDisplayMode(.inline)
        case .inlineLarge: toolbarTitleDisplayMode(.inlineLarge)
        case .large: toolbarTitleDisplayMode(.large)
        }
        #endif
    }

    @ViewBuilder
    func vaultKeyboardType(_ type: VaultKeyboardType) -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(type)
        #endif
    }

    func vaultTextContentType(_ type: VaultTextContentType?) -> some View {
        textContentType(type)
    }

    @ViewBuilder
    func vaultTextInputAutocapitalization(_ capitalization: VaultTextInputAutocapitalization?) -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(capitalization)
        #endif
    }

    @ViewBuilder
    func vaultInsetGroupedListStyle() -> some View {
        #if os(macOS)
        listStyle(.inset)
        #else
        listStyle(.insetGrouped)
        #endif
    }

    @ViewBuilder
    func vaultEditMode(_ mode: Binding<VaultEditMode>) -> some View {
        #if os(macOS)
        self
        #else
        environment(\.editMode, mode)
        #endif
    }

    /// Mac sheets size to their content, so give forms a usable initial size.
    @ViewBuilder
    func vaultSheetSize(width: CGFloat = 540, height: CGFloat = 560) -> some View {
        #if os(macOS)
        frame(minWidth: width, minHeight: height)
        #else
        self
        #endif
    }
}
