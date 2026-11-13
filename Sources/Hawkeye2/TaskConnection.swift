import Foundation
import HawkeyeCore

typealias ProjectOption = TaskDestination

struct TaskConnection: Codable, Equatable {
    static let preferenceKey = "tasks.connection"
    let provider: TaskProviderID
    let destinationID: String
    let destinationName: String
    let notionMapping: NotionTaskMapping?

    static func load(from preferences: UserDefaults) -> TaskConnection? {
        if let data = preferences.data(forKey: preferenceKey) {
            return try? JSONDecoder().decode(Self.self, from: data)
        }
        guard let id = preferences.string(forKey: "ticktick.projectID"), !id.isEmpty else { return nil }
        let connection = Self(provider: .ticktick, destinationID: id,
                              destinationName: preferences.string(forKey: "ticktick.projectName") ?? "your selected list",
                              notionMapping: nil)
        connection.save(to: preferences)
        return connection
    }

    func save(to preferences: UserDefaults) {
        preferences.set(try? JSONEncoder().encode(self), forKey: Self.preferenceKey)
        preferences.removeObject(forKey: "ticktick.projectID")
        preferences.removeObject(forKey: "ticktick.projectName")
    }
}

struct ConnectionCatalog {
    var destinations: [TaskDestination]
    var notionDataSources: [NotionDataSource] = []
}
