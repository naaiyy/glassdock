import Vapor

struct AppleContainerNotSupported {
    static func respond(_ feature: String) -> Response {
        let json = "{\"message\": \"\(feature) is not supported by the Glass Dock runtime\"}"
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: .notImplemented, headers: headers, body: .init(string: json))
    }
}

struct NotImplemented {
    static func respond(_ endpoint: String, _ method: String) -> Response {
        let json = "{\"message\": \"Method \(method) to \(endpoint) is not implemented by Glass Dock\"}"
        var headers = HTTPHeaders()
        headers.replaceOrAdd(name: .contentType, value: "application/json")
        return Response(status: .notImplemented, headers: headers, body: .init(string: json))
    }
}
