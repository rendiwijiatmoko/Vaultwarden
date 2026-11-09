import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
import VisionKit
#endif
internal import Vision

#if os(iOS)
struct TOTPQRCodeScannerView: UIViewControllerRepresentable {
    let onScan: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onScan: onScan)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private var hasScanned = false

        init(onScan: @escaping (String) -> Void) {
            self.onScan = onScan
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !hasScanned else { return }
            for item in addedItems {
                guard case let .barcode(barcode) = item,
                      let value = barcode.payloadStringValue else { continue }
                hasScanned = true
                dataScanner.stopScanning()
                onScan(value)
                return
            }
        }
    }
}

#elseif os(macOS)
/// macOS imports a QR image through the native file picker. Vision reads it
/// locally; authenticator secrets never leave the device during recognition.
struct TOTPQRCodeScannerView: View {
    let onScan: (String) -> Void
    @State private var choosingImage = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 52))
                .foregroundStyle(Color.vaultBlue)
            Text("Import an Authenticator QR Code")
                .font(.title2.bold())
            Text("Choose an image containing your authenticator setup QR code.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Image…") { choosingImage = true }
                .buttonStyle(.borderedProminent)
            if let errorMessage {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(Color.vaultRed)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosingImage, allowedContentTypes: [.image]) { result in
            switch result {
            case let .success(url): recognizeCode(in: url)
            case let .failure(error): errorMessage = error.localizedDescription
            }
        }
    }

    private func recognizeCode(in url: URL) {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }

        do {
            let request = VNDetectBarcodesRequest()
            request.symbologies = [.qr]
            try VNImageRequestHandler(url: url).perform([request])
            guard let value = request.results?
                .compactMap(\.payloadStringValue)
                .first(where: { value in
                    guard let url = URL(string: value) else { return false }
                    return OTPAuthSetupRequest.parse(url) != nil
                }) else {
                errorMessage = L10n.string("This image does not contain a valid TOTP authenticator QR code.")
                return
            }
            onScan(value)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
#endif
