import Foundation

enum BarcodeKeyValidationError: LocalizedError, Equatable {
    case invalidKey
    case accessDenied
    case rateLimited
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            L10n.string("The SaveMyCart key is invalid. Check the key and try again. Your saved key has not changed.")
        case .accessDenied:
            L10n.string("SaveMyCart rejected this key or restricted its access. Check your key and account limits. Your saved key has not changed.")
        case .rateLimited:
            L10n.string("SaveMyCart's request limit was reached. Try again later or check your quota. Your saved key has not changed.")
        case .unavailable:
            L10n.string("Couldn't verify the SaveMyCart key. Check your connection and try again. Your saved key has not changed.")
        }
    }
}

/// Never forward the API key to a redirect destination, or accept a login page as validation.
private final class SaveMyCartValidationDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct BarcodeHit: Identifiable, Hashable, Sendable {
    var id: String { sourceKey + "|" + barcode + "|" + name }
    var name: String
    var brand: String
    var barcode: String
    var imageURL: URL?
    var sourceName: String
    var sourceKey: String

    var displayName: String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let brand = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if brand.isEmpty { return name }
        if name.localizedCaseInsensitiveContains(brand) { return name }
        return "\(brand) \(name)"
    }
}

struct BarcodeLookupResult: Sendable {
    var barcode: String
    var hits: [BarcodeHit]

    var best: BarcodeHit? {
        hits.max { lhs, rhs in
            score(lhs) < score(rhs)
        }
    }

    private func score(_ hit: BarcodeHit) -> Int {
        let locale = Locale.current
        var localCatalog = 0
        if hit.sourceKey == "savemycart" {
            if locale.language.languageCode?.identifier == "he" { localCatalog += 8 }
            if locale.region?.identifier == "IL" { localCatalog += 4 }
        }
        return localCatalog
            + (hit.imageURL == nil ? 0 : 4)
            + (hit.brand.isEmpty ? 0 : 2)
            + min(hit.name.count, 40) / 10
    }
}

enum BarcodeLookupService {
    private static let userAgent = "OurStock/1.6.4 (https://github.com/akhagar/FList)"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        return URLSession(configuration: config)
    }()

    private static let openFactsCatalogs: [(host: String, sourceName: String, sourceKey: String)] = [
        ("world.openfoodfacts.org", "Open Food Facts", "off"),
        ("world.openbeautyfacts.org", "Open Beauty Facts", "obf"),
        ("world.openpetfoodfacts.org", "Open Pet Food Facts", "opff"),
        ("world.openproductsfacts.org", "Open Products Facts", "opf")
    ]

    static func normalizedBarcode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let gtin = gtinFromDigitalLink(trimmed) {
            return gtin
        }
        if trimmed.hasPrefix("01"), trimmed.dropFirst(2).allSatisfy(\.isNumber), trimmed.count >= 16 {
            return String(trimmed.dropFirst(2).prefix(14)).filter(\.isNumber)
        }
        return trimmed.filter(\.isNumber)
    }

    private static func gtinFromDigitalLink(_ raw: String) -> String? {
        let parts = raw.split(whereSeparator: { $0 == "/" || $0 == "?" || $0 == "&" }).map(String.init)
        guard let ai = parts.firstIndex(of: "01"), parts.index(after: ai) < parts.endIndex else {
            return nil
        }
        let digits = parts[parts.index(after: ai)].filter(\.isNumber)
        return (8...14).contains(digits.count) ? digits : nil
    }

    static func lookupCodes(from raw: String) -> [String] {
        let barcode = normalizedBarcode(raw)
        var codes: [String] = []
        func add(_ value: String) {
            let digits = value.filter(\.isNumber)
            guard (8...14).contains(digits.count), !codes.contains(digits) else { return }
            codes.append(digits)
        }
        add(barcode)
        if barcode.count == 8, let upcA = expandUPCE(barcode) {
            add(upcA)
            add("0" + upcA)
        }
        switch barcode.count {
        case 8:
            add(String(repeating: "0", count: 5) + barcode)
            add(String(repeating: "0", count: 6) + barcode)
        case 12:
            add("0" + barcode)
            add("00" + barcode)
        case 13:
            if barcode.hasPrefix("0") { add(String(barcode.dropFirst())) }
            add("0" + barcode)
        case 14:
            add(String(barcode.dropFirst()))
            if barcode.hasPrefix("00") { add(String(barcode.dropFirst(2))) }
        default:
            break
        }
        return codes
    }

    static func lookup(
        barcode raw: String,
        configuration: BarcodeLookupConfiguration = .empty
    ) async -> BarcodeLookupResult {
        let configuration = configuration.normalized
        let barcode = normalizedBarcode(raw)
        let codes = lookupCodes(from: barcode)
        guard let primary = codes.first else {
            return BarcodeLookupResult(barcode: barcode, hits: [])
        }

        var hits = await withTaskGroup(of: BarcodeHit?.self, returning: [BarcodeHit].self) { group in
            for catalog in openFactsCatalogs {
                group.addTask {
                    await openFacts(host: catalog.host, sourceName: catalog.sourceName, sourceKey: catalog.sourceKey, codes: codes)
                }
            }
            group.addTask { await upcItemDB(codes: codes) }
            group.addTask { await gs1Resolver(codes: codes) }
            var collected: [BarcodeHit] = []
            for await hit in group {
                if let hit { collected.append(hit) }
            }
            return collected
        }

        if hits.isEmpty, let local = await saveMyCart(codes: codes, key: configuration.saveMyCartAPIKey) {
            hits.append(local)
        }

        var unique: [BarcodeHit] = []
        var seen = Set<String>()
        for hit in hits {
            let key = hit.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted {
                unique.append(hit)
            }
        }
        return BarcodeLookupResult(barcode: primary, hits: unique)
    }

    static func searchedCatalogsSummary(configuration: BarcodeLookupConfiguration = .empty) -> String {
        let configuration = configuration.normalized
        var names = openFactsCatalogs.map(\.sourceName) + ["UPC Item DB", "GS1"]
        if !configuration.saveMyCartAPIKey.isEmpty {
            names.append("SaveMyCart")
        }
        return ListFormatter.localizedString(byJoining: names)
    }

    private static func infoPlistString(_ key: String) -> String {
        (Bundle.main.object(forInfoDictionaryKey: key) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Test an authenticated, free-tier endpoint. Empty search results still prove
    /// the key works; a missing product must not make a valid key look invalid.
    static func validateSaveMyCartAPIKey(_ rawKey: String, session validationSession: URLSession? = nil) async throws {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw BarcodeKeyValidationError.invalidKey
        }
        let configuredBase = infoPlistString("SaveMyCartAPIBaseURL")
        let base = configuredBase.isEmpty ? "https://savemycart.net" : configuredBase
        guard let baseURL = URL(string: base), baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil, baseURL.user == nil, baseURL.password == nil,
              var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/product-search/"),
                                             resolvingAgainstBaseURL: false) else {
            throw BarcodeKeyValidationError.unavailable
        }
        components.queryItems = [URLQueryItem(name: "q", value: "חלב")]
        guard let url = components.url else { throw BarcodeKeyValidationError.unavailable }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpShouldHandleCookies = false

        let data: Data
        let response: URLResponse
        do {
            try Task.checkCancellation()
            (data, response) = try await (validationSession ?? session).data(
                for: request, delegate: SaveMyCartValidationDelegate()
            )
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // Never expose a response body or request containing the secret key.
            throw BarcodeKeyValidationError.unavailable
        }
        guard let http = response as? HTTPURLResponse else { throw BarcodeKeyValidationError.unavailable }
        switch http.statusCode {
        case 401: throw BarcodeKeyValidationError.invalidKey
        case 403: throw BarcodeKeyValidationError.accessDenied
        case 429: throw BarcodeKeyValidationError.rateLimited
        case 200:
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["error"] == nil, json["errors"] == nil,
                  json["data"] is [[String: Any]] else {
                throw BarcodeKeyValidationError.unavailable
            }
        default: throw BarcodeKeyValidationError.unavailable
        }
    }

    static func imageData(from url: URL?) async -> Data? {
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              data.count > 40
        else { return nil }
        return data
    }

    private static func openFacts(
        host: String,
        sourceName: String,
        sourceKey: String,
        codes: [String]
    ) async -> BarcodeHit? {
        for code in codes {
            if let hit = await openFacts(host: host, sourceName: sourceName, sourceKey: sourceKey, barcode: code) {
                return hit
            }
        }
        return nil
    }

    private static func openFacts(
        host: String,
        sourceName: String,
        sourceKey: String,
        barcode: String
    ) async -> BarcodeHit? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var components = URLComponents(string: "https://\(host)/api/v3/product/\(barcode)")
        components?.queryItems = [
            URLQueryItem(name: "lc", value: language),
            URLQueryItem(
                name: "fields",
                value: "code,product_name,product_name_\(language),product_name_en,generic_name,abbreviated_product_name,brands,image_front_small_url,image_small_url,image_url,quantity,product_type"
            )
        ]
        guard let url = components?.url else { return nil }
        let json: [String: Any]?
        if let v3 = await jsonObject(url: url) {
            json = v3
        } else {
            json = await openFactsV2(host: host, barcode: barcode)
        }
        guard let json else { return nil }
        let statusString = (json["status"] as? String ?? "").lowercased()
        let statusOK = statusString == "success"
            || statusString == "success_with_warnings"
            || json["status"] as? Int == 1
        guard statusOK, let product = json["product"] as? [String: Any] else { return nil }
        let brand = firstNonEmpty([product["brands"] as? String]).components(separatedBy: ",").first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = firstNonEmpty([
            product["product_name_\(language)"] as? String,
            product["product_name"] as? String,
            product["product_name_en"] as? String,
            product["generic_name"] as? String,
            product["abbreviated_product_name"] as? String,
            brand
        ])
        guard !name.isEmpty else { return nil }
        let image = firstNonEmpty([
            product["image_front_small_url"] as? String,
            product["image_small_url"] as? String,
            product["image_url"] as? String
        ])
        return BarcodeHit(
            name: name,
            brand: brand,
            barcode: barcode,
            imageURL: URL(string: image),
            sourceName: sourceName,
            sourceKey: sourceKey
        )
    }

    private static func openFactsV2(host: String, barcode: String) async -> [String: Any]? {
        guard let url = URL(string: "https://\(host)/api/v2/product/\(barcode).json") else { return nil }
        return await jsonObject(url: url)
    }

    private static func upcItemDB(codes: [String]) async -> BarcodeHit? {
        for code in codes {
            if let hit = await upcItemDB(barcode: code) { return hit }
        }
        return nil
    }

    private static func upcItemDB(barcode: String) async -> BarcodeHit? {
        var components = URLComponents(string: "https://api.upcitemdb.com/prod/trial/lookup")
        components?.queryItems = [URLQueryItem(name: "upc", value: barcode)]
        guard let url = components?.url,
              let json = await jsonObject(url: url, accept: "application/json")
        else { return nil }
        let code = (json["code"] as? String ?? "").uppercased()
        guard code == "OK",
              let items = json["items"] as? [[String: Any]],
              let item = items.first
        else { return nil }
        let name = firstNonEmpty([item["title"] as? String, item["description"] as? String])
        guard !name.isEmpty else { return nil }
        let images = item["images"] as? [String]
        return BarcodeHit(
            name: name,
            brand: firstNonEmpty([item["brand"] as? String]),
            barcode: barcode,
            imageURL: images?.first.flatMap(URL.init(string:)),
            sourceName: "UPC Item DB",
            sourceKey: "upcitemdb"
        )
    }


    private static func saveMyCart(codes: [String], key: String) async -> BarcodeHit? {
        guard !key.isEmpty else { return nil }
        var base = infoPlistString("SaveMyCartAPIBaseURL")
        if base.isEmpty { base = "https://savemycart.net" }
        if base.hasSuffix("/") { base.removeLast() }
        for code in codes {
            switch await saveMyCart(base: base, barcode: code, key: key) {
            case .hit(let hit):
                return hit
            case .unauthorized, .quota:
                return nil
            case .miss:
                continue
            }
        }
        return nil
    }

    private enum SaveMyCartOutcome {
        case hit(BarcodeHit)
        case miss
        case unauthorized
        case quota
    }

    private static func saveMyCart(base: String, barcode: String, key: String) async -> SaveMyCartOutcome {
        var components = URLComponents(string: "\(base)/api/v1/prices/")
        components?.queryItems = [URLQueryItem(name: "barcode", value: barcode)]
        guard let url = components?.url else { return .miss }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(key, forHTTPHeaderField: "X-API-Key")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (status, json) = await jsonResponse(request: request)
        if status == 401 { return .unauthorized }
        if status == 403 { return .quota }
        guard (200..<300).contains(status), let json else { return .miss }
        let data = json["data"] as? [String: Any] ?? json
        let productName = cleanedProductName(
            firstNonEmpty([
                data["name"] as? String,
                data["product_name"] as? String,
                data["item_name"] as? String,
                data["title"] as? String
            ])
        )
        let supplier = cleanedProductName(
            firstNonEmpty([
                data["manufacturer"] as? String,
                data["brand"] as? String,
                data["supplier"] as? String
            ])
        )
        guard !productName.isEmpty, !isPlaceholderCatalogValue(productName) else { return .miss }
        if !supplier.isEmpty, !isPlaceholderCatalogValue(supplier),
           productName.compare(supplier, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return .miss
        }
        let chainNames = ((data["prices"] as? [[String: Any]]) ?? []).compactMap {
            cleanedProductName($0["chain_name"] as? String)
        }
        if chainNames.contains(where: {
            productName.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            return .miss
        }
        let image = firstNonEmpty([
            data["image"] as? String,
            data["image_url"] as? String,
            data["imageUrl"] as? String
        ])
        let brand = (!supplier.isEmpty
                     && !isPlaceholderCatalogValue(supplier)
                     && productName.localizedCaseInsensitiveContains(supplier))
            ? supplier : ""
        return .hit(
            BarcodeHit(
                name: productName,
                brand: brand,
                barcode: firstNonEmpty([data["barcode"] as? String, barcode]),
                imageURL: URL(string: image),
                sourceName: "SaveMyCart",
                sourceKey: "savemycart"
            )
        )
    }

    private static func cleanedProductName(_ value: String?) -> String {
        value?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isPlaceholderCatalogValue(_ value: String) -> Bool {
        let folded = value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let compact = folded.filter(\.isLetter)
        let placeholders: Set<String> = [
            "unknown", "none", "null", "n/a", "na", "unspecified",
            "manufacturer", "supplier", "brand",
            "לא ידוע", "לאידוע", "כללי", "ספק", "יצרן"
        ]
        return placeholders.contains(folded) || placeholders.contains(compact)
    }

    private static func gs1Resolver(codes: [String]) async -> BarcodeHit? {
        var candidates: [String] = []
        for code in codes {
            if !candidates.contains(code) { candidates.append(code) }
            if let gtin = gtin14(code), !candidates.contains(gtin) { candidates.append(gtin) }
        }
        for code in candidates {
            guard let url = URL(string: "https://id.gs1.org/01/\(code)") else { continue }
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue(
                "application/ld+json, application/json, application/linkset+json;q=0.8",
                forHTTPHeaderField: "Accept"
            )
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            guard let json = await jsonObject(request: request) else { continue }
            if json["code"] != nil, json["validationErrors"] != nil { continue }
            let name = gs1String(in: json, keys: [
                "gs1:productName", "productName", "schema:name", "name", "title"
            ])
            guard !name.isEmpty else { continue }
            let brand = gs1String(in: json, keys: [
                "gs1:brandName", "brandName", "schema:brand", "brand"
            ])
            let image = gs1String(in: json, keys: [
                "gs1:productImage", "schema:image", "image", "image_url"
            ])
            return BarcodeHit(
                name: name,
                brand: brand,
                barcode: code,
                imageURL: URL(string: image),
                sourceName: "GS1",
                sourceKey: "gs1"
            )
        }
        return nil
    }

    private static func expandUPCE(_ barcode: String) -> String? {
        let digits = barcode.filter(\.isNumber)
        let body: String
        switch digits.count {
        case 6: body = "0" + digits
        case 7: body = digits
        case 8: body = String(digits.dropLast())
        default: return nil
        }
        guard body.count == 7, body.hasPrefix("0") || body.hasPrefix("1") else { return nil }
        let ns = body[body.startIndex]
        let d = body.dropFirst().map { $0 }
        guard d.count == 6 else { return nil }
        let manufacturerAndProduct: String
        switch d[5] {
        case "0", "1", "2":
            manufacturerAndProduct = "\(d[0])\(d[1])\(d[5])0000\(d[2])\(d[3])\(d[4])"
        case "3":
            manufacturerAndProduct = "\(d[0])\(d[1])\(d[2])00000\(d[3])\(d[4])"
        case "4":
            manufacturerAndProduct = "\(d[0])\(d[1])\(d[2])\(d[3])00000\(d[4])"
        default:
            manufacturerAndProduct = "\(d[0])\(d[1])\(d[2])\(d[3])\(d[4])0000\(d[5])"
        }
        let withoutCheck = "\(ns)" + manufacturerAndProduct
        guard withoutCheck.count == 11 else { return nil }
        let check = gtinCheckDigit(withoutCheck)
        if digits.count == 8, digits.last?.wholeNumberValue != check { return nil }
        return withoutCheck + String(check)
    }

    private static func gtinCheckDigit(_ digits: String) -> Int {
        let numbers = digits.compactMap { $0.wholeNumberValue }
        let sum = numbers.reversed().enumerated().reduce(0) { partial, item in
            partial + item.element * (item.offset % 2 == 0 ? 3 : 1)
        }
        return (10 - (sum % 10)) % 10
    }

    private static func gtin14(_ barcode: String) -> String? {
        guard (8...14).contains(barcode.count) else { return nil }
        return String(repeating: "0", count: 14 - barcode.count) + barcode
    }

    private static func jsonObject(url: URL, accept: String? = nil) async -> [String: Any]? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue(accept ?? "application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return await jsonObject(request: request)
    }

    private static func jsonObject(request: URLRequest) async -> [String: Any]? {
        let (status, json) = await jsonResponse(request: request)
        guard (200..<300).contains(status) else { return nil }
        return json
    }

    private static func jsonResponse(request: URLRequest) async -> (Int, [String: Any]?) {
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            return (status, json)
        } catch {
            return (0, nil)
        }
    }

    private static func firstNonEmpty(_ values: [String?]) -> String {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }

    private static func gs1String(in json: Any, keys: [String]) -> String {
        let wanted = Set(keys)
        var found: [String] = []
        walk(json, preferring: wanted, into: &found)
        return found.first ?? ""
    }

    private static func walk(_ value: Any, preferring keys: Set<String>, into found: inout [String]) {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed.count < 200, !trimmed.hasPrefix("http") {
                found.append(trimmed)
            }
            return
        }
        if let list = value as? [Any] {
            for item in list { walk(item, preferring: keys, into: &found) }
            return
        }
        guard let dict = value as? [String: Any] else { return }
        if let text = dict["@value"] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { found.append(trimmed) }
        }
        for (key, nested) in dict {
            let shortKey = key.split(separator: ":").last.map(String.init) ?? key
            if keys.contains(key) || keys.contains(shortKey) {
                var preferred: [String] = []
                walk(nested, preferring: keys, into: &preferred)
                found.insert(contentsOf: preferred, at: 0)
            } else {
                walk(nested, preferring: keys, into: &found)
            }
        }
    }
}
