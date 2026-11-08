import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AddEditCredentialField: Hashable {
    /// All non-generator inputs participate in the same focus state. This is
    /// important when the keyboard moves directly between fields: without it,
    /// SwiftUI can keep the old credential focus value and fail to rebuild the
    /// keyboard suggestion when Username or Password becomes active again.
    case nonCredential(UUID)
    case loginUsername
    case loginPassword
    case identityUsername

    var suggestionTitle: String {
        switch self {
        case .nonCredential:
            ""
        case .loginPassword:
            "Strong Password Suggestion"
        case .loginUsername, .identityUsername:
            "Username Suggestion"
        }
    }

    var supportsGeneratorSuggestion: Bool {
        switch self {
        case .nonCredential:
            false
        case .loginUsername, .loginPassword, .identityUsername:
            true
        }
    }
}

private struct AddEditFocusBindingKey: EnvironmentKey {
    static let defaultValue: FocusState<AddEditCredentialField?>.Binding? = nil
}

extension EnvironmentValues {
    var addEditFocusBinding: FocusState<AddEditCredentialField?>.Binding? {
        get { self[AddEditFocusBindingKey.self] }
        set { self[AddEditFocusBindingKey.self] = newValue }
    }
}

/// Installs a non-blocking tap recognizer on the editor's window. Taps on an
/// actual text input are ignored so field-to-field focus keeps working; every
/// other tap ends editing while still reaching the tapped control.
#if os(iOS)
struct KeyboardDismissTapInstaller: UIViewRepresentable {
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onDismiss: onDismiss)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onDismiss = onDismiss
        context.coordinator.attachWhenReady(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onDismiss: () -> Void
        private weak var attachedWindow: UIWindow?
        private lazy var recognizer: UITapGestureRecognizer = {
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.delegate = self
            return recognizer
        }()

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func attachWhenReady(from view: UIView) {
            DispatchQueue.main.async { [weak self, weak view] in
                guard let self, let window = view?.window else { return }
                guard attachedWindow !== window else { return }
                detach()
                window.addGestureRecognizer(recognizer)
                attachedWindow = window
            }
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(recognizer)
            attachedWindow = nil
        }

        @objc private func handleTap() {
            attachedWindow?.endEditing(true)
            onDismiss()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            var touchedView: UIView? = touch.view
            while let currentView = touchedView {
                if currentView is UITextField
                    || currentView is UITextView
                    || currentView is UIControl
                    || currentView.accessibilityIdentifier == "credentialSuggestionPanel" {
                    return false
                }
                touchedView = currentView.superview
            }
            return true
        }
    }
}

#endif

struct CredentialKeyboardSuggestion: View {
    let title: String
    let value: String
    let onUse: () -> Void
    let onCustomize: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onUse) {
                VStack(spacing: 1) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.callout.monospaced().weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.format("Use %@", L10n.string(title).lowercased()))
            .accessibilityValue(value)

            Divider()
                .frame(height: 34)

            Button(action: onCustomize) {
                Image(systemName: "wand.and.sparkles")
                    .frame(width: 32, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.vaultBlue)
            .accessibilityLabel("Open generator")
        }
        .frame(maxWidth: .infinity)
    }
}

struct LabeledFormField: View {
    @Environment(\.addEditFocusBinding) private var inheritedFocusBinding
    @State private var focusID = UUID()
    let title: String
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    let showsRevealButton: Bool
    let focusBinding: FocusState<AddEditCredentialField?>.Binding?
    let focusValue: AddEditCredentialField?
    let keyboardType: VaultKeyboardType
    let textContentType: VaultTextContentType?
    let capitalization: VaultTextInputAutocapitalization?
    let autocorrectionDisabled: Bool
    @State private var isRevealed = false

    init(
        _ title: String,
        text: Binding<String>,
        placeholder: String = "",
        isSecure: Bool = false,
        showsRevealButton: Bool = false,
        focusBinding: FocusState<AddEditCredentialField?>.Binding? = nil,
        focusValue: AddEditCredentialField? = nil,
        keyboardType: VaultKeyboardType = .default,
        textContentType: VaultTextContentType? = nil,
        capitalization: VaultTextInputAutocapitalization? = nil,
        autocorrectionDisabled: Bool = false
    ) {
        self.title = title
        _text = text
        self.placeholder = placeholder
        self.isSecure = isSecure
        self.showsRevealButton = showsRevealButton
        self.focusBinding = focusBinding
        self.focusValue = focusValue
        self.keyboardType = keyboardType
        self.textContentType = textContentType
        self.capitalization = capitalization
        self.autocorrectionDisabled = autocorrectionDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                focusedInput
                .font(.body)
                .vaultKeyboardType(keyboardType)
                .vaultTextContentType(textContentType)
                .vaultTextInputAutocapitalization(capitalization)
                .autocorrectionDisabled(autocorrectionDisabled)

                if isSecure && showsRevealButton {
                    Button {
                        isRevealed.toggle()
                    } label: {
                        Image(systemName: isRevealed ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(
                        L10n.format(
                            isRevealed ? "Hide %@" : "Show %@",
                            L10n.string(title)
                        )
                    )
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var focusedInput: some View {
        if let binding = focusBinding ?? inheritedFocusBinding {
            input.focused(binding, equals: focusValue ?? .nonCredential(focusID))
        } else {
            input
        }
    }

    @ViewBuilder
    private var input: some View {
        if isSecure && !isRevealed {
            SecureField(L10n.string(placeholder), text: $text)
        } else {
            TextField(L10n.string(placeholder), text: $text)
        }
    }
}

nonisolated struct StagedVaultAttachment: Identifiable, Sendable {
    let id: UUID
    let url: URL
    let fileName: String
    let size: Int64

    var formattedSize: String { ByteCountFormatter.string(fromByteCount: size, countStyle: .file) }
}

nonisolated enum VaultAttachmentStageError: LocalizedError {
    case unavailable
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .unavailable: "This file is unavailable."
        case .tooLarge: "Attachments must be 100 MB or smaller."
        }
    }
}

nonisolated enum VaultAttachmentStager {
    private static let maximumSize = 100 * 1_024 * 1_024

    static func stage(fileAt source: URL) throws -> StagedVaultAttachment {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        guard size.isDirectory != true else { throw VaultAttachmentStageError.unavailable }
        guard let byteCount = size.fileSize, byteCount <= maximumSize else {
            throw VaultAttachmentStageError.tooLarge
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedVaultAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let name = source.lastPathComponent
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
            return StagedVaultAttachment(id: UUID(), url: destination, fileName: name, size: Int64(byteCount))
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    static func stage(data: Data, fileName: String) throws -> StagedVaultAttachment {
        guard data.count <= maximumSize else { throw VaultAttachmentStageError.tooLarge }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("StagedVaultAttachments", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        try data.write(to: destination, options: .atomic)
        return StagedVaultAttachment(id: UUID(), url: destination, fileName: fileName, size: Int64(data.count))
    }
}
