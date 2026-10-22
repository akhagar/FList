import Foundation

/// Standalone tests using intercepted HTTP responses, never a real API key,
/// SaveMyCart quota, Keychain, or iCloud.
/// Compile L10n.swift, BarcodeLookupCredentials.swift, BarcodeLookupService.swift
/// and this file together with swiftc -parse-as-library.
@main
struct BarcodeKeyValidationTests {
    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubSaveMyCartProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var checks = 0

        for key in ["valid-empty", "valid-product", "  valid-empty\n"] {
            try await BarcodeLookupService.validateSaveMyCartAPIKey(key, session: session)
            checks += 1
        }

        let failures: [(String, BarcodeKeyValidationError)] = [
            ("", .invalidKey), (" \n", .invalidKey), ("bad\nheader", .invalidKey),
            ("bad key", .invalidKey), ("מפתח", .invalidKey),
            ("unauthorized", .invalidKey), ("forbidden", .accessDenied),
            ("rate-limit", .rateLimited), ("server-error", .unavailable),
            ("offline", .unavailable), ("timeout", .unavailable),
            ("redirect", .unavailable), ("html", .unavailable),
            ("malformed-json", .unavailable), ("wrong-shape", .unavailable),
            ("error-envelope", .unavailable), ("empty-response", .unavailable),
            ("not-found", .unavailable)
        ]
        for (key, expected) in failures {
            do {
                try await BarcodeLookupService.validateSaveMyCartAPIKey(key, session: session)
                preconditionFailure("Unverified credentials must be rejected")
            } catch let error as BarcodeKeyValidationError {
                precondition(error == expected, "Validation error classification differs")
            }
            checks += 1
        }

        var saved = BarcodeLookupConfiguration(saveMyCartAPIKey: "previous-key")
        let previous = saved
        do {
            saved = try await BarcodeLookupConfiguration(saveMyCartAPIKey: "unauthorized").validated {
                try await BarcodeLookupService.validateSaveMyCartAPIKey($0, session: session)
            }
            preconditionFailure("An invalid key cannot reach persistence")
        } catch is BarcodeKeyValidationError {
            precondition(saved == previous, "Keep the original configuration on failure")
        }
        checks += 1

        var requests = 0
        saved = try await BarcodeLookupConfiguration(saveMyCartAPIKey: "  valid-empty\n").validated {
            requests += 1
            precondition($0 == "valid-empty", "Normalize before validation and persistence")
            try await BarcodeLookupService.validateSaveMyCartAPIKey($0, session: session)
        }
        precondition(saved.saveMyCartAPIKey == "valid-empty" && requests == 1)
        checks += 1

        saved = try await BarcodeLookupConfiguration(saveMyCartAPIKey: " \n").validated { _ in
            preconditionFailure("Removing a key must not require a network request")
        }
        precondition(saved == .empty)
        checks += 1

        do {
            try await BarcodeLookupService.validateSaveMyCartAPIKey("cancelled", session: session)
            preconditionFailure("Cancellation must prevent saving")
        } catch is CancellationError {
            checks += 1
        }
        print("Passed \(checks) barcode key validation checks (no network requests)")
    }
}

private final class StubSaveMyCartProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        precondition(url.scheme == "https" && components?.path == "/api/v1/product-search/", "Incorrect validation endpoint: \(url)")
        precondition(request.httpMethod == "GET")
        precondition(request.value(forHTTPHeaderField: "Accept") == "application/json")
        precondition(components?.queryItems == [URLQueryItem(name: "q", value: "חלב")])
        let key = request.value(forHTTPHeaderField: "X-API-Key") ?? ""
        let status: Int
        let body: String
        switch key {
        case "valid-empty": (status, body) = (200, #"{"data":[],"meta":{"quota_remaining":199}}"#)
        case "valid-product": (status, body) = (200, #"{"data":[{"barcode":"12345678","name":"Milk"}]}"#)
        case "unauthorized": (status, body) = (401, #"{"error":"invalid_api_key"}"#)
        case "forbidden": (status, body) = (403, #"{"error":"access_denied"}"#)
        case "rate-limit": (status, body) = (429, #"{"error":"rate_limit"}"#)
        case "server-error": (status, body) = (503, #"{"error":"unavailable"}"#)
        case "redirect": (status, body) = (302, "")
        case "html": (status, body) = (200, "<html>Sign in</html>")
        case "malformed-json": (status, body) = (200, "{")
        case "wrong-shape": (status, body) = (200, #"{"data":{}}"#)
        case "error-envelope": (status, body) = (200, #"{"data":[],"error":"invalid_key"}"#)
        case "empty-response": (status, body) = (204, "")
        case "not-found": (status, body) = (404, "")
        case "offline", "timeout", "cancelled":
            let code: URLError.Code = key == "offline" ? .notConnectedToInternet : key == "timeout" ? .timedOut : .cancelled
            client?.urlProtocol(self, didFailWithError: URLError(code))
            return
        default: preconditionFailure("Unexpected request")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
