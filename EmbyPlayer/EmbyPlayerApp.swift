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

/// Cross-tab signals (the detail page's search capsule asks the shell
/// to switch to the search tab).
@MainActor
@Observable
final class ShellState {
    var searchRequested = false
}

/// Value-based navigation routes. Every tab stack registers the same
/// destinations; the pop closure belongs to the owning stack, so a
/// detail page's back button removes exactly its own stack's last
/// entry - no reliance on the dismiss environment, which did not pop
/// inside the old hand-rolled shell.
enum Route: Hashable {
    case detail(EmbyItem)
    case library(EmbyItem)
}

extension View {
    func routeDestinations(onPop: @escaping () -> Void) -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .detail(let item):
                DetailView(item: item, onBack: onPop)
            case .library(let item):
                LibraryView(library: item)
            }
        }
    }
}

/// The shell is a plain TabView - the same approach as JM Reader. On
/// iOS 26 the system tab bar IS the floating liquid-glass bar with the
/// sliding selection indicator, and it stays reliable where the
/// hand-rolled glass bar did not. Pushed pages hide it with
/// .toolbar(.hidden, for: .tabBar).
struct MainView: View {
    @State private var tab = 0
    @State private var shell = ShellState()
    @State private var path0 = NavigationPath()
    @State private var path1 = NavigationPath()
    @State private var path2 = NavigationPath()
    @State private var path3 = NavigationPath()
    @State private var path4 = NavigationPath()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: $path0) {
                HomeView().routeDestinations { if !path0.isEmpty { path0.removeLast() } }
            }
            .tabItem { Label("首页", systemImage: "play.rectangle") }
            .tag(0)

            NavigationStack(path: $path1) {
                LibrariesTabView().routeDestinations { if !path1.isEmpty { path1.removeLast() } }
            }
            .tabItem { Label("资源库", systemImage: "externaldrive") }
            .tag(1)

            NavigationStack(path: $path2) {
                RecordsView().routeDestinations { if !path2.isEmpty { path2.removeLast() } }
            }
            .tabItem { Label("记录", systemImage: "person.text.rectangle") }
            .tag(2)

            NavigationStack(path: $path3) {
                SettingsView().routeDestinations { if !path3.isEmpty { path3.removeLast() } }
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(3)

            NavigationStack(path: $path4) {
                SearchTabView().routeDestinations { if !path4.isEmpty { path4.removeLast() } }
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(4)
        }
        .tint(.blue)
        .environment(shell)
        .onChange(of: shell.searchRequested) { _, requested in
            if requested {
                shell.searchRequested = false
                tab = 4
            }
        }
    }
}
