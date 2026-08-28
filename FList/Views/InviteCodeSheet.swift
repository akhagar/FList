import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit
import VisionKit

struct InviteCodeSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss
    @State private var shareURL: URL?
    @State private var loadError: String?
    @State private var copiedMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't share", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(loadError)
                    }
                } else if let shareURL {
                    inviteContent(for: shareURL)
                } else {
                    ProgressView("Checking iCloud…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Invite code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .task { await loadShare() }
            .alert(
                copiedMessage ?? "",
                isPresented: Binding(
                    get: { copiedMessage != nil },
                    set: { if !$0 { copiedMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { copiedMessage = nil }
            } message: {
                Text("Send the code in a message. The other person pastes it in WeStock, or scans this QR in the app.")
            }
        }
    }

    private func inviteContent(for url: URL) -> some View {
        let code = ShareInvite.displayCode(from: url)
        let compact = ShareInvite.token(from: url) ?? url.absoluteString
        return List {
            Section {
                VStack(spacing: 20) {
                    qrImage(for: url)
                    Text(code)
                        .font(.system(.title3, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity)
                }
                .listRowBackground(Color.clear)
                .padding(.vertical, 8)
            } footer: {
                Text("They paste the code in WeStock, or scan this QR code in the app.")
            }

            Section {
                Button {
                    UIPasteboard.general.string = compact
                    copiedMessage = L10n.string("Invite code copied")
                } label: {
                    Label("Copy code", systemImage: "doc.on.doc")
                }
                Button {
                    UIPasteboard.general.url = url
                    copiedMessage = L10n.string("Invite link copied")
                } label: {
                    Label("Copy link", systemImage: "link")
                }
            }
        }
    }

    private func qrImage(for url: URL) -> some View {
        Group {
            if let image = QRCodeImage.make(from: url.absoluteString) {
                Image(uiImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 220, height: 220)
                    .padding(16)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .accessibilityLabel("Invite QR code")
            }
        }
    }

    private func loadShare() async {
        do {
            let share = try await store.prepareShare()
            guard let url = share.url else {
                loadError = L10n.string("The invite link could not be created. Try again.")
                return
            }
            shareURL = url
        } catch {
            loadError = error.flistDisplayMessage
        }
    }
}

enum QRCodeImage {
    static func make(from string: String, dimension: CGFloat = 220) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = max(1, dimension / output.extent.width)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

struct InviteQRScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            InviteQRScanner { value in
                onCode(value)
                dismiss()
            }
            .ignoresSafeArea()
            .navigationTitle("Scan QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

struct InviteQRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning {
            try? scanner.startScanning()
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        if scanner.isScanning {
            scanner.stopScanning()
        }
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void
        private var didHandle = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            handle(addedItems, scanner: dataScanner)
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            handle([item], scanner: dataScanner)
        }

        private func handle(_ items: [RecognizedItem], scanner: DataScannerViewController) {
            guard !didHandle else { return }
            for item in items {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    didHandle = true
                    scanner.stopScanning()
                    onCode(value)
                    return
                }
            }
        }
    }
}

@MainActor
enum InviteQRScanning {
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}
