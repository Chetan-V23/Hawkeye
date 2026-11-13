import Foundation

struct ProviderHTTP: Sendable {
    let token: String
    let baseURL: URL
    let transport: any HTTPTransport
    var headers: [String: String] = [:]

    func request(_ method: String, _ path: [String], query: [URLQueryItem] = [], body: [String: JSONValue]? = nil) async throws -> [String: JSONValue] {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TaskProviderError.missingToken }
        var url = baseURL
        for component in path { url.appendPathComponent(component) }
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            url = components.url!
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport.data(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw TaskProviderError.connection }
        guard (200..<300).contains(response.statusCode) else { throw TaskProviderError.httpStatus(response.statusCode) }
        if data.isEmpty || (try? JSONDecoder().decode(JSONValue.self, from: data)) == .null { return [:] }
        guard let result = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw TaskProviderError.invalidResponse
        }
        return result
    }
}

extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let value) = self { return value }; return nil }
    var array: [JSONValue]? { if case .array(let value) = self { return value }; return nil }
    var bool: Bool? { if case .bool(let value) = self { return value }; return nil }
}

func providerDate(_ value: String?) -> Date? {
    guard let value else { return nil }
    if let date = TickTickDate.date(value) { return date }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone.current
    formatter.isLenient = false
    for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: value) { return date }
    }
    return nil
}

func providerDateString(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }

func nextPageCursor(_ page: [String: JSONValue], seen: inout Set<String>) throws -> String? {
    guard let cursor = page["next_cursor"]?.string, !cursor.isEmpty else { return nil }
    guard seen.insert(cursor).inserted else { throw TaskProviderError.invalidResponse }
    return cursor
}

func checkedProviderDate(_ value: String?) throws -> Date? {
    guard let value else { return nil }
    guard let date = providerDate(value) else { throw TaskProviderError.invalidResponse }
    return date
}
