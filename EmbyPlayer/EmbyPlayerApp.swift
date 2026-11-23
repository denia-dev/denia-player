import SwiftUI
import UIKit

/// Owns the app-wide orientation mask. The player widens it on entry
/// and restores portrait on exit. Routing the mask through the
/// delegate is what makes rotation stick even when the device's
/// portrait lock is on - a bare geometry update is refused under
/// the lock (broken since build 5, reported again on build 26).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait
    static var lastOrientationError: String?

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationMask
    }
}

@main
struct EmbyPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
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
    case interfacePrefs
    case osdPrefs
    case buttonPrefs
    case playbackPrefs
    case gesturePrefs
}

/// The five tab stacks' navigation paths, held in a reference-type
/// store so closures anywhere (including navigation destinations)
/// mutate the one live instance - a captured @State struct copy was
/// the prime suspect when detail-page pops silently did nothing.
@MainActor
@Observable
final class NavStore {
    var path0 = NavigationPath()
    var path1 = NavigationPath()
    var path2 = NavigationPath()
    var path3 = NavigationPath()
    var path4 = NavigationPath()

    func popCounted(_ keyPath: ReferenceWritableKeyPath<NavStore, NavigationPath>) -> Int {
        if !self[keyPath: keyPath].isEmpty { self[keyPath: keyPath].removeLast() }
        return self[keyPath: keyPath].count
    }

    func binding(_ keyPath: ReferenceWritableKeyPath<NavStore, NavigationPath>) -> Binding<NavigationPath> {
        Binding(get: { self[keyPath: keyPath] }, set: { self[keyPath: keyPath] = $0 })
    }
}

extension View {
    /// onPop pops the owning stack and returns its remaining depth,
    /// which the detail page's temporary diagnostics display.
    func routeDestinations(onPop: @escaping () -> Int) -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .detail(let item):
                DetailView(item: item, onBack: onPop)
            case .library(let item):
                LibraryView(library: item)
            case .interfacePrefs:
                InterfacePrefsView()
            case .osdPrefs:
                OSDPrefsView()
            case .buttonPrefs:
                ButtonPrefsView()
            case .playbackPrefs:
                PlaybackPrefsView()
            case .gesturePrefs:
                GesturePrefsView()
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
    @State private var nav = NavStore()

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack(path: nav.binding(\.path0)) {
                HomeView().routeDestinations { nav.popCounted(\.path0) }
            }
            .tabItem { Label("首页", systemImage: "play.rectangle") }
            .tag(0)

            NavigationStack(path: nav.binding(\.path1)) {
                LibrariesTabView().routeDestinations { nav.popCounted(\.path1) }
            }
            .tabItem { Label("资源库", systemImage: "externaldrive") }
            .tag(1)

            NavigationStack(path: nav.binding(\.path2)) {
                RecordsView().routeDestinations { nav.popCounted(\.path2) }
            }
            .tabItem { Label("记录", systemImage: "person.text.rectangle") }
            .tag(2)

            NavigationStack(path: nav.binding(\.path3)) {
                SettingsView().routeDestinations { nav.popCounted(\.path3) }
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(3)

            NavigationStack(path: nav.binding(\.path4)) {
                SearchTabView().routeDestinations { nav.popCounted(\.path4) }
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
