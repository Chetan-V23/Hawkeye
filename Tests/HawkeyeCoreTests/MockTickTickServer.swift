import Foundation
@testable import HawkeyeCore

actor MockTickTickServer: HTTPTransport {
    struct Request: Sendable {
        let method: String
        let path: String
        let body: Data?
        let authorization: String?
        let query: [String: String]
    }

    private var remote: [String: TickTickTask] = [:]
    private var requests: [Request] = []
    private var failureCount = 0
    private var ambiguousCreate = false
    private var configuredProjects: [TickTickProject]?
    private var inboxProjectID = "inbox"
    private var repeatedProjectPage = false
    private var routeStatuses: [String: Int] = [:]
    private var pauseMatch: (String, String)?
    private var paused = false
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var pauseWaiters: [CheckedContinuation<Void, Never>] = []

    func seed(_ task: TickTickTask) { remote[key(task.projectId, task.id)] = task }
    func remove(projectID: String, taskID: String) { remote.removeValue(forKey: key(projectID, taskID)) }
    func allTasks() -> [TickTickTask] { Array(remote.values) }
    func capturedRequests() -> [Request] { requests }
    func failNext(_ count: Int) { failureCount = count }
    func timeOutAfterNextCreate() { ambiguousCreate = true }
    func setProjects(_ projects: [TickTickProject]) { configuredProjects = projects }
    func setInboxProjectID(_ id: String) { inboxProjectID = id }
    func repeatProjectPages() { repeatedProjectPage = true }
    func setStatus(_ status: Int?, method: String, path: String) { routeStatuses[method + " " + path] = status }

    func pauseNext(method: String, path: String) { pauseMatch = (method, path) }

    func waitUntilPaused() async {
        if paused { return }
        await withCheckedContinuation { pauseWaiters.append($0) }
    }

    func resume() {
        paused = false
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path.replacingOccurrences(of: "/open/v1", with: "")
        let method = request.httpMethod ?? "GET"
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        requests.append(Request(method: method, path: path, body: request.httpBody, authorization: request.value(forHTTPHeaderField: "Authorization"), query: query))
        if let match = pauseMatch, match.0 == method, match.1 == path {
            pauseMatch = nil
            paused = true
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                for waiter in pauseWaiters { waiter.resume() }
                pauseWaiters = []
            }
        }
        if failureCount > 0 {
            failureCount -= 1
            throw URLError(.notConnectedToInternet)
        }
        if let status = routeStatuses[method + " " + path] { return empty(request, status: status) }
        let components = path.split(separator: "/").map(String.init)
        if method == "GET", path == "/project" {
            let projects = configuredProjects ?? Set(remote.values.map(\.projectId).filter { $0 != inboxProjectID } + ["p"]).sorted()
                .map { TickTickProject(id: $0, name: "Tasks", kind: "TASK") }
            let offset = repeatedProjectPage ? 0 : (Int(query["offset"] ?? "0") ?? 0)
            let limit = Int(query["limit"] ?? "200") ?? 200
            return try response(Array(projects.dropFirst(offset).prefix(limit)), request: request)
        }
        if method == "GET", components.count == 3, components[0] == "project", components[2] == "data" {
            return try response(TickTickProjectData(tasks: remote.values.filter { $0.projectId == components[1] && $0.status != 2 }), request: request)
        }
        if method == "GET", components.count == 4, components[0] == "project", components[2] == "task" {
            guard let task = remote[key(components[1], components[3])] else { return empty(request, status: 404) }
            return try response(task, request: request)
        }
        if method == "POST", path == "/task" {
            let task = try JSONDecoder().decode(TickTickTask.self, from: request.httpBody!)
            guard remote[key(task.projectId, task.id)] == nil else { return empty(request, status: 409) }
            remote[key(task.projectId, task.id)] = task
            if ambiguousCreate {
                ambiguousCreate = false
                throw URLError(.timedOut)
            }
            return try response(task, request: request)
        }
        if method == "POST", path == "/task/filter" {
            let filter = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            guard filter["projectIds"] == .array([.string("inbox")]), filter["status"] == .array([.integer(0)]) else {
                return empty(request, status: 400)
            }
            return try response(Array(remote.values.filter { $0.projectId == inboxProjectID && $0.status == 0 }.sorted { $0.id < $1.id }.prefix(200)), request: request)
        }
        if method == "POST", path == "/task/completed" {
            let filter = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody!)
            guard let start = filter["startDate"]?.string.flatMap(TickTickDate.date),
                  let end = filter["endDate"]?.string.flatMap(TickTickDate.date),
                  filter["projectIds"] == nil else { return empty(request, status: 400) }
            let tasks = remote.values.filter {
                guard $0.status == 2, let date = $0.completedTime else { return false }
                return date >= start && date <= end
            }.sorted { $0.id < $1.id }
            return try response(Array(tasks.prefix(200)), request: request)
        }
        if method == "POST", components.count == 2, components[0] == "task" {
            let task = try JSONDecoder().decode(TickTickTask.self, from: request.httpBody!)
            remote[key(task.projectId, task.id)] = task
            return try response(task, request: request)
        }
        if method == "POST", components.count == 5, components[4] == "complete" {
            guard let task = remote[key(components[1], components[3])], task.status != 2 else { return empty(request, status: 404) }
            remote[key(task.projectId, task.id)] = TickTickTask(
                id: task.id, projectId: task.projectId, title: task.title, content: task.content,
                startDate: task.startDate, dueDate: task.dueDate, completedTime: Date(), status: 2,
                rawFields: task.rawFields
            )
            return empty(request)
        }
        return empty(request, status: 404)
    }

    private func key(_ project: String, _ task: String) -> String { project + "/" + task }

    private func response<T: Encodable>(_ value: T, request: URLRequest) throws -> (Data, HTTPURLResponse) {
        (try JSONEncoder().encode(value), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func empty(_ request: URLRequest, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
