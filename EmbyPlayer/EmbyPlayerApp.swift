import SwiftUI

@main
struct EmbyPlayerApp: App {
    @State private var store = AppStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        if store.activeServer?.isLoggedIn == true {
            MainView()
        } else {
            ServersView()
        }
    }
}

struct MainView: View {
    @Environment(AppStore.self) private var store
    @State private var showServers = false

    var body: some View {
        NavigationStack {
            HomeView()
                .navigationTitle(store.activeServer?.name ?? "EmbyPlayer")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showServers = true } label: {
                            Image(systemName: "server.rack")
                        }
                    }
                }
                .sheet(isPresented: $showServers) { ServersView() }
        }
    }
}
