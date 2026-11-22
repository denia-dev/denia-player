import Foundation
import Observation

@MainActor
@Observable
final class AppStore {
    private(set) var servers: [ServerConfig] = []
    var activeServerID: String?

    private let key = "embyplayer.servers.v1"
    private let activeKey = "embyplayer.activeServer.v1"

    init() { load() }

    var activeServer: ServerConfig? {
        guard let activeServerID else { return servers.first }
        return servers.first(where: { $0.id == activeServerID }) ?? servers.first
    }

    func client() -> EmbyClient? {
        guard let server = activeServer, server.isLoggedIn else { return nil }
        return EmbyClient(server: server)
    }

    func add(_ config: ServerConfig) {
        servers.append(config)
        activeServerID = config.id
        save()
    }

    func update(_ config: ServerConfig) {
        guard let index = servers.firstIndex(where: { $0.id == config.id }) else { return }
        servers[index] = config
        save()
    }

    func remove(id: String) {
        servers.removeAll { $0.id == id }
        if activeServerID == id { activeServerID = servers.first?.id }
        save()
    }

    func setActive(id: String) {
        activeServerID = id
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(servers) {
            UserDefaults.standard.set(data, forKey: key)
        }
        UserDefaults.standard.set(activeServerID, forKey: activeKey)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = decoded
        }
        activeServerID = UserDefaults.standard.string(forKey: activeKey)
    }
}
