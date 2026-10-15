import Foundation

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
        (hit.imageURL == nil ? 0 : 4)
            + (hit.brand.isEmpty ? 0 : 2)
            + min(hit.name.count, 40) / 10
    }
}

enum BarcodeLookupService {
    private static let userAgent = "OurStock/1.6.3 (https://github.com/akhagar/FList)"
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 12
        config.httpAdditionalHeaders = [
            "User-Agent": userAgent,
            "Accept": "application/json"
        ]
        return URLSession(configuration: config)
    }()

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

    static func lookup(barcode raw: String) async -> BarcodeLookupResult {
        let barcode = normalizedBarcode(raw)
        guard barcode.count >= 8 else {
            return BarcodeLookupResult(barcode: barcode, hits: [])
        }

        async let facts = openFacts(barcode: barcode)
        async let upc = upcItemDB(barcode: barcode)
        async let gs1 = gs1Resolver(barcode: barcode)
        async let lookup = barcodeLookup(barcode: barcode)

        let (factsHit, upcHit, gs1Hit, lookupHit) = await (facts, upc, gs1, lookup)
        let hits = [factsHit, upcHit, gs1Hit, lookupHit].compactMap { $0 }
        var unique: [BarcodeHit] = []
        var seen = Set<String>()
        for hit in hits {
            let key = hit.displayName.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if seen.insert(key).inserted {
                unique.append(hit)
            }
        }
        return BarcodeLookupResult(barcode: barcode, hits: unique)
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

    private static func openFacts(barcode: String) async -> BarcodeHit? {
        let language = Locale.current.language.languageCode?.identifier ?? "en"
        var components = URLComponents(string: "https://world.openfoodfacts.org/api/v3/product/\(barcode)")
        components?.queryItems = [
            URLQueryItem(name: "product_type", value: "all"),
            URLQueryItem(name: "lc", value: language),
            URLQueryItem(
                name: "fields",
                value: "code,product_name,product_name_\(language),product_name_en,generic_name,abbreviated_product_name,brands,image_front_small_url,image_small_url,image_url,quantity,product_type"
            )
        ]
        guard let url = components?.url,
              let json = await jsonObject(url: url)
        else { return nil }
        let status = (json["status"] as? String ?? "").lowercased()
        guard status == "success" || status == "success_with_warnings",
              let product = json["product"] as? [String: Any]
        else { return nil }
        let name = firstNonEmpty([
            product["product_name_\(language)"] as? String,
            product["product_name"] as? String,
            product["product_name_en"] as? String,
            product["generic_name"] as? String,
            product["abbreviated_product_name"] as? String
        ])
        guard !name.isEmpty else { return nil }
        let image = firstNonEmpty([
            product["image_front_small_url"] as? String,
            product["image_small_url"] as? String,
            product["image_url"] as? String
        ])
        let (sourceName, sourceKey) = openFactsSource(product["product_type"] as? String)
        return BarcodeHit(
            name: name,
            brand: firstNonEmpty([product["brands"] as? String]).components(separatedBy: ",").first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            barcode: barcode,
            imageURL: URL(string: image),
            sourceName: sourceName,
            sourceKey: sourceKey
        )
    }

    private static func openFactsSource(_ productType: String?) -> (String, String) {
        switch (productType ?? "food").lowercased() {
        case "beauty": return ("Open Beauty Facts", "obf")
        case "petfood": return ("Open Pet Food Facts", "opff")
        case "product": return ("Open Products Facts", "opf")
        default: return ("Open Food Facts", "off")
        }
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

    private static func barcodeLookup(barcode: String) async -> BarcodeHit? {
        let key = (Bundle.main.object(forInfoDictionaryKey: "BarcodeLookupAPIKey") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty else { return nil }
        var components = URLComponents(string: "https://api.barcodelookup.com/v3/products")
        components?.queryItems = [
            URLQueryItem(name: "barcode", value: barcode),
            URLQueryItem(name: "formatted", value: "y"),
            URLQueryItem(name: "key", value: key)
        ]
        guard let url = components?.url,
              let json = await jsonObject(url: url),
              let products = json["products"] as? [[String: Any]],
              let product = products.first
        else { return nil }
        let name = firstNonEmpty([
            product["product_name"] as? String,
            product["title"] as? String
        ])
        guard !name.isEmpty else { return nil }
        let images = product["images"] as? [String]
        return BarcodeHit(
            name: name,
            brand: firstNonEmpty([product["brand"] as? String, product["manufacturer"] as? String]),
            barcode: barcode,
            imageURL: images?.first.flatMap(URL.init(string:)),
            sourceName: "Barcode Lookup",
            sourceKey: "barcodelookup"
        )
    }

    private static func gs1Resolver(barcode: String) async -> BarcodeHit? {
        let candidates = Array(Set([barcode, gtin14(barcode)].compactMap { $0 }))
        for code in candidates {
            guard let url = URL(string: "https://id.gs1.org/01/\(code)") else { continue }
            var request = URLRequest(url: url)
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
                barcode: barcode,
                imageURL: URL(string: image),
                sourceName: "GS1",
                sourceKey: "gs1"
            )
        }
        return nil
    }

    private static func gtin14(_ barcode: String) -> String? {
        guard (8...14).contains(barcode.count) else { return nil }
        return String(repeating: "0", count: 14 - barcode.count) + barcode
    }

    private static func jsonObject(url: URL, accept: String? = nil) async -> [String: Any]? {
        var request = URLRequest(url: url)
        if let accept {
            request.setValue(accept, forHTTPHeaderField: "Accept")
        }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return await jsonObject(request: request)
    }

    private static func jsonObject(request: URLRequest) async -> [String: Any]? {
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<400).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
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
