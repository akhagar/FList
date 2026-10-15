import SwiftUI
import UIKit
import VisionKit

struct BarcodeScanSheet: View {
    @Bindable var store: FListStore
    @Environment(\.dismiss) private var dismiss

    @State private var barcode = ""
    @State private var isLookingUp = false
    @State private var result: BarcodeLookupResult?
    @State private var selected: BarcodeHit?
    @State private var name = ""
    @State private var quantity = 1
    @State private var selectedStoreIDs: Set<UUID> = []
    @State private var photoData: Data?
    @State private var lookupError: String?
    @State private var showManual = !ProductBarcodeScanning.isAvailable

    var body: some View {
        NavigationStack {
            Group {
                if let selected {
                    foundView(selected)
                } else if isLookingUp {
                    lookingUpView
                } else if let result, result.hits.isEmpty {
                    notFoundView
                } else if showManual || !ProductBarcodeScanning.isAvailable {
                    manualView
                } else {
                    scannerView
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if selected == nil, !isLookingUp, result == nil, ProductBarcodeScanning.isAvailable {
                    ToolbarItem(placement: .primaryAction) {
                        Button(showManual ? "Scan" : "Enter barcode") {
                            showManual.toggle()
                        }
                    }
                }
            }
        }
    }

    private var navigationTitle: LocalizedStringKey {
        if selected != nil { return "Found item" }
        if isLookingUp { return "Looking up barcode" }
        if result?.hits.isEmpty == true { return "No match" }
        return "Scan barcode"
    }

    private var scannerView: some View {
        ProductBarcodeScanner { value in
            Task { await lookup(value) }
        }
        .ignoresSafeArea()
    }

    private var lookingUpView: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(String(format: L10n.string("Looking up %@…"), barcode))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(String(format: L10n.string("Checking %@."), BarcodeLookupService.searchedCatalogsSummary))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var notFoundView: some View {
        Form {
            Section {
                TextField("What are you out of?", text: $name)
                    .textInputAutocapitalization(.sentences)
                Stepper(value: $quantity, in: 1...99) {
                    Text("Quantity: \(quantity)")
                }
            } header: {
                Text("No catalog match")
            } footer: {
                Text(String(format: L10n.string("Nothing turned up for %@. Checked %@. You can still add it by name."), barcode, BarcodeLookupService.searchedCatalogsSummary))
            }

            if !store.shops.isEmpty {
                ShopPickerSection(shops: store.shops, selected: $selectedStoreIDs)
            }

            Section {
                Button("Add to list") {
                    Task { await addNamedItem() }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Scan again") { resetToScan() }
                Button("Enter a different barcode") {
                    result = nil
                    showManual = true
                }
            }
        }
    }

    private var manualView: some View {
        Form {
            Section {
                TextField("Barcode", text: $barcode)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                Text("Point the camera at an EAN or UPC, or type the numbers from the package.")
            }
            if let lookupError {
                Section {
                    Text(lookupError)
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Button("Look up") {
                    Task { await lookup(barcode) }
                }
                .disabled(BarcodeLookupService.normalizedBarcode(barcode).count < 8)
            }
        }
    }

    private func foundView(_ hit: BarcodeHit) -> some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    foundPhoto
                    VStack(alignment: .leading, spacing: 4) {
                        if !hit.brand.isEmpty {
                            Text(hit.brand)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Text(hit.barcode)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        Text(String(format: L10n.string("Found in %@"), sourceSummary))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                TextField("What are you out of?", text: $name)
                    .textInputAutocapitalization(.sentences)
                if let result, result.hits.count > 1 {
                    Picker("Catalog match", selection: hitSelection) {
                        ForEach(result.hits) { hit in
                            Text(hit.displayName).tag(hit.id)
                        }
                    }
                }
                Stepper(value: $quantity, in: 1...99) {
                    Text("Quantity: \(quantity)")
                }
                if let status = store.listedStatus(forName: name) {
                    Text(status == .needed
                         ? "Already on Needed. Adding again increases the quantity."
                         : "This is on Back in stock. Adding marks it as needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if !store.shops.isEmpty {
                ShopPickerSection(shops: store.shops, selected: $selectedStoreIDs)
            }

            Section {
                Button("Add to list") {
                    Task { await addNamedItem() }
                }
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Scan again") { resetToScan() }
            }
        }
    }

    private var foundPhoto: some View {
        Group {
            if let photoData, let image = UIImage(data: photoData) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "barcode.viewfinder")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.12))
            }
        }
        .frame(width: 72, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var sourceSummary: String {
        let names = (result?.hits ?? []).map(\.sourceName)
        return ListFormatter.localizedString(byJoining: names)
    }

    private var hitSelection: Binding<String> {
        Binding(
            get: { selected?.id ?? "" },
            set: { id in
                guard let hit = result?.hits.first(where: { $0.id == id }) else { return }
                selected = hit
                name = hit.displayName
                photoData = nil
                Task {
                    if let data = await BarcodeLookupService.imageData(from: hit.imageURL) {
                        photoData = ProfileImage.jpegData(from: data, maxDimension: 960)
                    }
                }
            }
        )
    }

    private func lookup(_ raw: String) async {
        let code = BarcodeLookupService.normalizedBarcode(raw)
        guard code.count >= 8 else {
            lookupError = L10n.string("That barcode is too short.")
            showManual = true
            return
        }
        barcode = code
        isLookingUp = true
        lookupError = nil
        selected = nil
        result = nil
        photoData = nil
        let lookedUp = await BarcodeLookupService.lookup(barcode: code)
        result = lookedUp
        isLookingUp = false
        if let hit = lookedUp.best {
            selected = hit
            name = hit.displayName
            if let data = await BarcodeLookupService.imageData(from: hit.imageURL) {
                photoData = ProfileImage.jpegData(from: data, maxDimension: 960)
            }
        } else {
            name = ""
            showManual = true
        }
    }

    private func addNamedItem() async {
        await store.addItem(
            name: name,
            quantity: quantity,
            note: "",
            photoData: photoData,
            storeIDs: Array(selectedStoreIDs)
        )
        dismiss()
    }

    private func resetToScan() {
        barcode = ""
        result = nil
        selected = nil
        name = ""
        quantity = 1
        photoData = nil
        lookupError = nil
        isLookingUp = false
        showManual = !ProductBarcodeScanning.isAvailable
    }
}

struct ProductBarcodeScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.ean8, .ean13, .upce, .itf14, .code128])],
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
enum ProductBarcodeScanning {
    static var isAvailable: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }
}
