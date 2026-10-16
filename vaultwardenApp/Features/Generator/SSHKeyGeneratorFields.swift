import SwiftUI

/// Shared by the standalone generator and the SSH item editor.
struct SSHKeyGeneratorFields: View {
    @EnvironmentObject private var store: AppStore
    @Binding var privateKey: String
    @Binding var publicKey: String
    @Binding var fingerprint: String
    var allowsGeneration = true
    @State private var comment = ""
    @State private var revealed = false
    @State private var generation: Task<Void, Never>?
    @State private var requestID: UUID?
    @State private var generationFailed = false
    @State private var confirmReplace = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if allowsGeneration {
                LabeledContent("Algorithm", value: "Ed25519")
                TextField("Key comment (optional)", text: $comment)
                    .autocorrectionDisabled()
                Button {
                    if privateKey.isEmpty { generate() } else { confirmReplace = true }
                } label: {
                    if requestID != nil {
                        ProgressView()
                    } else {
                        Label("Generate SSH Key", systemImage: "arrow.clockwise")
                    }
                }
                .disabled(requestID != nil || store.isLocked || store.authenticatedSession == nil)
                .confirmationDialog("Replace generated SSH key?", isPresented: $confirmReplace) {
                    Button("Generate New Key", role: .destructive) { generate() }
                } message: {
                    Text("The current unsaved key will be replaced. Saved vault items will not change until you save.")
                }
            }

            if !publicKey.isEmpty {
                keyValue("Public Key", value: publicKey)
                keyValue("Fingerprint", value: fingerprint)
                HStack {
                    Text("Private Key").font(.headline)
                    Spacer()
                    Button {
                        revealed.toggle()
                    } label: {
                        Image(systemName: revealed ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(revealed ? "Hide value" : "Show value")
                    AnimatedCopyButton(value: privateKey, accessibilityName: "Private Key")
                }
                if revealed {
                    Text(privateKey).font(.caption.monospaced()).textSelection(.enabled)
                } else {
                    Text("••••••••••••").font(.body.monospaced())
                }
            }
            if generationFailed {
                Text("Could not generate SSH key. Please try again.")
                    .foregroundStyle(.red)
            }
        }
        .onChange(of: store.isLocked) { _, locked in
            if locked { discard() }
        }
        .onChange(of: store.authenticatedSession?.tokenReference) { _, _ in discard() }
        .onDisappear {
            generation?.cancel()
            generation = nil
            requestID = nil
            revealed = false
        }
    }

    private func keyValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.string(title)).font(.headline)
                Spacer()
                AnimatedCopyButton(value: value, accessibilityName: title)
            }
            Text(value).font(.caption.monospaced()).textSelection(.enabled)
        }
    }

    private func generate() {
        guard !store.isLocked, let session = store.authenticatedSession else { return }
        let id = UUID()
        requestID = id
        generationFailed = false
        revealed = false
        // Do not allow Save to use the previous pair while replacing it.
        privateKey = ""
        publicKey = ""
        fingerprint = ""
        let comment = comment
        generation = Task {
            do {
                let key = try await Task.detached(priority: .userInitiated) {
                    try SSHKeyGenerator.generate(comment: comment)
                }.value
                guard !Task.isCancelled, requestID == id, !store.isLocked,
                      store.authenticatedSession?.tokenReference == session.tokenReference else { return }
                privateKey = key.privateKey
                publicKey = key.publicKey
                fingerprint = key.fingerprint
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                generationFailed = true
            }
            if requestID == id {
                requestID = nil
                generation = nil
            }
        }
    }

    private func discard() {
        generation?.cancel()
        generation = nil
        requestID = nil
        privateKey = ""
        publicKey = ""
        fingerprint = ""
        comment = ""
        revealed = false
        confirmReplace = false
        generationFailed = false
    }
}
