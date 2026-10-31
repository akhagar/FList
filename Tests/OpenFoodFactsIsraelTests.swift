import Foundation

/// Compile with L10n.swift, BarcodeLookupCredentials.swift and BarcodeLookupService.swift.
/// HTTP responses are intercepted; these checks never access a live catalog.
@main
struct OpenFoodFactsIsraelTests {
    static func main() async throws {
        let catalog = BarcodeLookupService.openFactsCatalogs.first { $0.sourceKey == "off-il" }!
        precondition(catalog.host == "il.openfoodfacts.org" && catalog.language == "he")
        precondition(BarcodeLookupService.openFactsCatalogs.contains { $0.sourceKey == "off" && $0.language == nil })
        precondition(BarcodeLookupService.searchedCatalogsSummary().contains(catalog.sourceName))

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenFactsStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func lookup(_ code: String) async -> BarcodeHit? {
            await BarcodeLookupService.openFacts(host: catalog.host, sourceName: catalog.sourceName,
                                                sourceKey: catalog.sourceKey, barcode: code,
                                                language: catalog.language, session: session)
        }
        let hebrew = await lookup("7290000000001")
        precondition(hebrew?.name == "חלב" && hebrew?.sourceKey == "off-il")
        precondition(hebrew?.imageURL?.absoluteString == "https://images.openfoodfacts.org/milk.jpg")
        let fallback = await lookup("7290000000002")
        precondition(fallback?.name == "Milk", "Use English if Hebrew and primary names are empty")
        let legacy = await lookup("7290000000003")
        precondition(legacy?.name == "חלב", "The v2 fallback must preserve Hebrew language selection")
        let missing = await lookup("7290000000004")
        precondition(missing == nil)
        let unavailable = await lookup("7290000000005")
        precondition(unavailable == nil)

        let world = await BarcodeLookupService.openFacts(host: "world.openfoodfacts.org", sourceName: "Open Food Facts",
                                                        sourceKey: "off", barcode: "7290000000001",
                                                        language: "en", session: session)
        precondition(world?.name == "Milk" && world?.sourceKey == "off")
        let russian = await BarcodeLookupService.openFacts(host: "world.openfoodfacts.org", sourceName: "Open Food Facts",
                                                          sourceKey: "off", barcode: "7290000000001",
                                                          language: "ru", session: session)
        precondition(russian?.name == "Молоко", "World catalog must still honor the requested language")
        var duplicate = hebrew!
        duplicate.sourceKey = "off"
        duplicate.sourceName = "Open Food Facts"
        precondition(BarcodeLookupService.uniqueHits([hebrew!, duplicate]).count == 1)
        precondition(BarcodeLookupService.uniqueHits([hebrew!, world!]).count == 2,
                     "Keep differently named language alternatives available")
        print("Passed 13 Open Food Facts Israel checks (no network requests)")
    }
}

private final class OpenFactsStubProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        let language = query.first { $0.name == "lc" }!.value!
        let fields = query.first { $0.name == "fields" }!.value!
        precondition(["he", "en", "ru"].contains(language))
        precondition(fields.contains("product_name_\(language)"))
        precondition(request.value(forHTTPHeaderField: "X-API-Key") == nil)
        precondition(request.value(forHTTPHeaderField: "User-Agent")?.contains("OurStock") == true)
        precondition(url.scheme == "https")
        precondition(["il.openfoodfacts.org", "world.openfoodfacts.org"].contains(url.host!))
        let code = url.lastPathComponent.replacingOccurrences(of: ".json", with: "")
        var status = 200
        let body: String
        switch code {
        case "7290000000001":
            body = #"{"status":"success","product":{"product_name":"Milk","product_name_he":"חלב","product_name_en":"Milk","product_name_ru":"Молоко","image_front_small_url":"https://images.openfoodfacts.org/milk.jpg"}}"#
        case "7290000000002":
            body = #"{"status":"success_with_warnings","product":{"product_name":" ","product_name_he":"","product_name_en":"Milk"}}"#
        case "7290000000003":
            if url.path.contains("/v3/") {
                status = 503
                body = "Unavailable"
            } else {
                precondition(url.path.contains("/v2/"))
                body = #"{"status":1,"product":{"product_name_he":"חלב","product_name_en":"Milk"}}"#
            }
        case "7290000000004":
            body = #"{"status":"failure","product":null}"#
        case "7290000000005":
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        default: preconditionFailure("Unexpected barcode")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
