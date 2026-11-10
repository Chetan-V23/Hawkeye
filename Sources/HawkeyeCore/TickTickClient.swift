import Foundation

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TickTickError.invalidResponse }
        return (data, response)
    }
}

public struct TickTickProject: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let closed: Bool?
    public let kind: String?
    public let permission: String?

    public init(id: String, name: String, closed: Bool? = nil, kind: String? = nil, permission: String? = nil) {
        self.id = id
        self.name = name
        self.closed = closed
        self.kind = kind
        self.permission = permission
    }
}

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    var string: String? { if case .string(let value) = self { return value }; return nil }
    var number: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }
}

public struct TickTickTask: Codable, Equatable, Sendable {
    public let id: String
    public let projectId: String
    public let title: String
    public let content: String?
    public let desc: String?
    public let startDate: Date?
    public let dueDate: Date?
    public let createdTime: Date?
    public let completedTime: Date?
    public let status: Int
    public let rawFields: [String: JSONValue]

    public init(
        id: String,
        projectId: String,
        title: String,
        content: String? = nil,
        desc: String? = nil,
        startDate: Date? = nil,
        dueDate: Date? = nil,
        createdTime: Date? = nil,
        completedTime: Date? = nil,
        status: Int = 0,
        rawFields: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.projectId = projectId
        self.title = title
        self.content = content
        self.desc = desc
        self.startDate = startDate
        self.dueDate = dueDate
        self.createdTime = createdTime
        self.completedTime = completedTime
        self.status = status
        self.rawFields = rawFields
    }

    public init(from decoder: Decoder) throws {
        let fields = try [String: JSONValue](from: decoder)
        guard let id = fields["id"]?.string,
              let projectID = fields["projectId"]?.string,
              let title = fields["title"]?.string else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Task identity or title is missing."))
        }
        self.init(
            id: id,
            projectId: projectID,
            title: title,
            content: fields["content"]?.string,
            desc: fields["desc"]?.string,
            startDate: try Self.date(fields["startDate"], key: "startDate", path: decoder.codingPath),
            dueDate: try Self.date(fields["dueDate"], key: "dueDate", path: decoder.codingPath),
            createdTime: try Self.date(fields["createdTime"], key: "createdTime", path: decoder.codingPath),
            completedTime: try Self.date(fields["completedTime"], key: "completedTime", path: decoder.codingPath),
            status: Int(fields["status"]?.number ?? 0),
            rawFields: fields
        )
    }

    public func encode(to encoder: Encoder) throws {
        var fields = rawFields
        fields["id"] = .string(id)
        fields["projectId"] = .string(projectId)
        fields["title"] = .string(title)
        fields["content"] = content.map(JSONValue.string) ?? .null
        fields["desc"] = desc.map(JSONValue.string) ?? .null
        fields["startDate"] = startDate.map { .string(TickTickDate.string($0)) } ?? .null
        fields["dueDate"] = dueDate.map { .string(TickTickDate.string($0)) } ?? .null
        fields["createdTime"] = createdTime.map { .string(TickTickDate.string($0)) } ?? .null
        fields["completedTime"] = completedTime.map { .string(TickTickDate.string($0)) } ?? .null
        fields["status"] = .number(Double(status))
        try fields.encode(to: encoder)
    }

    public var scheduledStart: Date? { startDate ?? dueDate }
    public var scheduledDuration: TimeInterval? {
        guard let startDate, let dueDate, dueDate > startDate else { return nil }
        return dueDate.timeIntervalSince(startDate)
    }

    private static func date(_ value: JSONValue?, key: String, path: [CodingKey]) throws -> Date? {
        guard let value, value != .null else { return nil }
        guard let string = value.string, let date = TickTickDate.date(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: path, debugDescription: "Invalid task date for \(key)."))
        }
        return date
    }
}

public struct TickTickProjectData: Codable, Sendable {
    public let tasks: [TickTickTask]

    public init(tasks: [TickTickTask]) { self.tasks = tasks }

    private enum CodingKeys: String, CodingKey { case tasks }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tasks = try container.decodeIfPresent([TickTickTask].self, forKey: .tasks) ?? []
    }
}

public struct TickTickClient: Sendable {
    private let token: String
    private let transport: any HTTPTransport
    private let baseURL = URL(string: "https://api.ticktick.com/open/v1")!

    public init(token: String, session: URLSession = .shared) {
        self.init(token: token, transport: URLSessionTransport(session: session))
    }

    public init(token: String, transport: any HTTPTransport) {
        self.token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    public func projects() async throws -> [TickTickProject] {
        try await projectListing().projects
    }

    func projectListing() async throws -> (projects: [TickTickProject], warnings: [String]) {
        var projects: [TickTickProject] = []
        var seen = Set<String>()
        var offset = 0
        while true {
            let page: [TickTickProject]
            do {
                page = try decode([TickTickProject].self, data: await request(
                    method: "GET", path: ["project"],
                    query: [URLQueryItem(name: "offset", value: String(offset)), URLQueryItem(name: "limit", value: "200")]
                ))
            } catch let error as TickTickError {
                guard offset > 0, error != .httpStatus(401), error != .missingToken else { throw error }
                return (projects, ["Some TickTick projects could not be loaded. \(error.localizedDescription)"])
            }
            let unseen = page.filter { seen.insert($0.id).inserted }
            projects.append(contentsOf: unseen)
            if page.count < 200 { return (projects, []) }
            if unseen.isEmpty {
                return (projects, ["TickTick repeated a project page. Some projects may be missing from this sync."])
            }
            offset += page.count
        }
    }

    public func projectData(projectID: String) async throws -> TickTickProjectData {
        try decode(TickTickProjectData.self, data: await request(method: "GET", path: ["project", projectID, "data"]))
    }

    public func inboxTasks() async throws -> [TickTickTask] {
        try decode([TickTickTask].self, data: await request(method: "POST", path: ["task", "filter"], payload: [
            "projectIds": .array([.string("inbox")]),
            "status": .array([.integer(0)])
        ]))
    }

    public func completedTasks(startDate: Date, endDate: Date) async throws -> [TickTickTask] {
        try decode([TickTickTask].self, data: await request(method: "POST", path: ["task", "completed"], payload: [
            "startDate": .string(TickTickDate.string(startDate)),
            "endDate": .string(TickTickDate.string(endDate))
        ]))
    }

    public func task(projectID: String, taskID: String) async throws -> TickTickTask? {
        do {
            return try decode(TickTickTask.self, data: await request(method: "GET", path: ["project", projectID, "task", taskID]))
        } catch TickTickError.httpStatus(404) {
            return nil
        }
    }

    public func createTask(_ task: TodoTask, identity: RemoteTaskIdentity) async throws -> TickTickTask? {
        let data = try await request(method: "POST", path: ["task"], payload: payload(task, identity: identity, preserving: nil))
        return data.isEmpty ? nil : try decode(TickTickTask.self, data: data)
    }

    public func updateTask(_ task: TodoTask, identity: RemoteTaskIdentity, preserving remote: TickTickTask) async throws {
        _ = try await request(method: "POST", path: ["task", identity.taskID], payload: payload(task, identity: identity, preserving: remote))
    }

    public func completeTask(identity: RemoteTaskIdentity) async throws {
        _ = try await request(method: "POST", path: ["project", identity.projectID, "task", identity.taskID, "complete"])
    }

    private func payload(_ task: TodoTask, identity: RemoteTaskIdentity, preserving remote: TickTickTask?) -> [String: JSONValue] {
        var fields = remote?.rawFields ?? [:]
        fields["id"] = .string(identity.taskID)
        fields["projectId"] = .string(identity.projectID)
        fields["title"] = .string(task.title)
        fields["content"] = .string(task.taskDescription)
        if remote?.startDate != nil {
            fields["startDate"] = task.dueAt.map { .string(TickTickDate.string($0)) } ?? .null
            let end = task.dueAt.map { $0.addingTimeInterval(remote?.scheduledDuration ?? 0) }
            fields["dueDate"] = end.map { .string(TickTickDate.string($0)) } ?? .null
        } else {
            fields["dueDate"] = task.dueAt.map { .string(TickTickDate.string($0)) } ?? .null
        }
        if remote == nil || task.dueAt != remote?.scheduledStart { fields["isAllDay"] = .bool(false) }
        fields["status"] = .integer(Int64(task.completed ? (remote?.status ?? 0) : 0))
        fields["timeZone"] = fields["timeZone"] ?? .string(TimeZone.current.identifier)
        if !task.completed { fields["completedTime"] = .null }
        return fields
    }

    private func request(method: String, path: [String], query: [URLQueryItem] = [], payload: [String: JSONValue]? = nil) async throws -> Data {
        guard !token.isEmpty else { throw TickTickError.missingToken }
        var url = baseURL
        for component in path { url.appendPathComponent(component) }
        if !query.isEmpty {
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            components.queryItems = query
            url = components.url!
        }
        var request = URLRequest(url: url)
        if path == ["project"] { request.cachePolicy = .reloadIgnoringLocalCacheData }
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let payload {
            request.httpBody = try JSONEncoder().encode(payload)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TickTickError.connection
        }
        guard (200..<300).contains(response.statusCode) else { throw TickTickError.httpStatus(response.statusCode) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TickTickError.invalidResponse }
    }
}

public enum TickTickError: Error, LocalizedError, Equatable {
    case missingToken
    case connection
    case invalidResponse
    case httpStatus(Int)
    case remoteTaskMissing

    public var errorDescription: String? {
        switch self {
        case .missingToken: return "Enter a TickTick personal access token."
        case .connection: return "TickTick could not be reached. Your changes are saved for retry."
        case .invalidResponse: return "TickTick returned an unreadable response. Your changes are saved for retry."
        case .remoteTaskMissing: return "The TickTick task could not be found. Your local changes are saved."
        case .httpStatus(401), .httpStatus(403): return "TickTick rejected access. Check your personal access token and project permissions."
        case .httpStatus(429): return "TickTick is limiting requests. Your changes are saved for the next sync."
        case .httpStatus(let status): return "TickTick request failed with HTTP status \(status). Your changes are saved for retry."
        }
    }
}

enum TickTickDate {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        let legacy = DateFormatter()
        legacy.locale = Locale(identifier: "en_US_POSIX")
        legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        if let date = legacy.date(from: value) { return date }
        legacy.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return legacy.date(from: value)
    }

    static func string(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
