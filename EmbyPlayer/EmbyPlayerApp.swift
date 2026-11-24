import SwiftUI
import UIKit
import LocalAuthentication

/// Owns the app-wide orientation mask. The player widens it on entry
/// and restores portrait on exit. Routing the mask through the
/// delegate is what makes rotation stick even when the device's
/// portrait lock is on - a bare geometry update is refused under
/// the lock (broken since build 5, reported again on build 26).
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationMask: UIInterfaceOrientationMask = .portrait
    static var lastOrientationError: String?
    private var backgroundSessionCompletion: ((String, () -> Void))?

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == "com.denia.embyplayer.media-downloads" else { completionHandler(); return }
        backgroundSessionCompletion = (identifier, completionHandler)
        DownloadsManager.shared.handleBackgroundEvents { [weak self] in
            self?.backgroundSessionCompletion?.1()
            self?.backgroundSessionCompletion = nil
        }
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationMask
    }
}

@main
struct EmbyPlayerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = AppStore()
    @AppStorage("prefs.appearance") private var appearance = "system"

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        }
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.scenePhase) private var scenePhase
    @State private var locked = Prefs.appLock
    @State private var authentication: LAContext?
    @State private var lockMessage: String?

    var body: some View {
        ZStack {
            Group {
                if store.activeServer?.isLoggedIn == true {
                    MainView()
                } else {
                    ServersView()
                }
            }
            .allowsHitTesting(!locked)
            .accessibilityHidden(locked)
            if locked {
                lockScreen
            }
        }
        .onAppear {
            if Prefs.appLock { locked = true; authenticate() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, Prefs.appLock {
                locked = true
                authentication?.invalidate()
                authentication = nil
                lockMessage = nil
            }
            if phase == .active, locked, lockMessage == nil { authenticate() }
        }
    }

    private var lockScreen: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.accentColor)
                    .frame(width: 72, height: 72)
                    .overlay(Image(systemName: "play.fill").font(.title).foregroundStyle(.white))
                Text("EmbyPlayer 已锁定").font(.headline)
                if let lockMessage { Text(lockMessage).font(.footnote).multilineTextAlignment(.center) }
                Button("解锁") { authenticate() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func authenticate() {
        guard scenePhase == .active, authentication == nil else { return }
        lockMessage = nil
        let context = LAContext()
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            lockMessage = authError?.localizedDescription ?? "设备认证不可用，请检查系统密码设置后重试。"
            return
        }
        authentication = context
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "解锁 EmbyPlayer") { success, error in
            Task { @MainActor in
                guard authentication === context else { return }
                authentication = nil
                if success { locked = false }
                else { lockMessage = error?.localizedDescription ?? "未能解锁，请重试。" }
            }
        }
    }
}

/// Cross-tab signals (the detail page's search capsule asks the shell
/// to switch to the search tab).
@MainActor
@Observable
final class ShellState {
    var searchRequested = false
    /// Home asks the shell to open the records tab on a segment
    /// (0 = recent, 2 = favorites); RecordsView consumes and clears it.
    var recordsRequest: Int?
}

/// Value-based navigation routes. Every tab stack registers the same
/// destinations; the pop closure belongs to the owning stack, so a
/// detail page's back button removes exactly its own stack's last
/// entry - no reliance on the dismiss environment, which did not pop
/// inside the old hand-rolled shell.
enum Route: Hashable {
    case detail(EmbyItem)
    case library(EmbyItem)
    case person(id: String, name: String)
    case interfacePrefs
    case osdPrefs
    case buttonPrefs
    case playbackPrefs
    case gesturePrefs
    case videoPrefs
    case audioPrefs
    case subtitlePrefs
    case appPrefs
    case modulePrefs
    case privacyPrefs
    case cachePrefs
    case listPrefs
    case downloadPrefs
    case aiTranslatePrefs
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
            case .person(let id, let name):
                PersonItemsView(personID: id, name: name)
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
            case .videoPrefs:
                VideoPrefsView()
            case .audioPrefs:
                AudioPrefsView()
            case .subtitlePrefs:
                SubtitlePrefsView()
            case .appPrefs:
                AppPrefsView()
            case .modulePrefs:
                ModulePrefsView()
            case .privacyPrefs:
                PrivacyPrefsView()
            case .cachePrefs:
                CachePrefsView()
            case .listPrefs:
                ListPrefsView()
            case .downloadPrefs:
                DownloadsPrefsView()
            case .aiTranslatePrefs:
                AITranslatePrefsView()
            }
        }
    }
}

// MARK: - zoom transition plumbing

/// Shared namespace for the iOS zoom navigation transition (the
/// reference-app animation he sent on 2026-11-23: tap a poster and the
/// detail page grows out of it, the list behind recedes). One namespace
/// lives in MainView and reaches every stack through the environment.
private struct ZoomNSKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var zoomNS: Namespace.ID? {
        get { self[ZoomNSKey.self] }
        set { self[ZoomNSKey.self] = newValue }
    }
}

private struct ZoomSourceModifier: ViewModifier {
    let id: String
    let ns: Namespace.ID?
    func body(content: Content) -> some View {
        if let ns {
            content.matchedTransitionSource(id: id, in: ns)
        } else {
            content
        }
    }
}

private struct ZoomDestinationModifier: ViewModifier {
    let id: String
    let ns: Namespace.ID?
    func body(content: Content) -> some View {
        if let ns {
            content.navigationTransition(.zoom(sourceID: id, in: ns))
        } else {
            content
        }
    }
}

extension View {
    func zoomSource(id: String, ns: Namespace.ID?) -> some View {
        modifier(ZoomSourceModifier(id: id, ns: ns))
    }
    func zoomDestination(id: String, ns: Namespace.ID?) -> some View {
        modifier(ZoomDestinationModifier(id: id, ns: ns))
    }
}

/// The shell is a plain TabView - the same approach as JM Reader. On
/// iOS 26 the system tab bar IS the floating liquid-glass bar with the
/// sliding selection indicator, and it stays reliable where the
/// hand-rolled glass bar did not. Pushed pages hide it with
/// .toolbar(.hidden, for: .tabBar).
struct MainView: View {
    @Environment(AppStore.self) private var store
    @State private var tab: Int

    init() {
        let start = Prefs.startTab
        _tab = State(initialValue: start >= 0 ? start : UserDefaults.standard.integer(forKey: "app.lastTab"))
    }
    @State private var shell = ShellState()
    @State private var nav = NavStore()
    @Namespace private var zoomNS

    var body: some View {
        TabView(selection: $tab) {
            // Tab bar visibility is a pure function of stack depth,
            // declared once here at each root. The previous setup let
            // every pushed page declare .hidden for itself; with the
            // zoom transition and the player's full-screen cover in
            // the cycle, those declarations could desync on pop and
            // the bar never came back (his 2026-11-25 report: repeat
            // enter/exit a movie, bar gone until relaunch). Derived
            // from the path, a dropped transition update self-heals
            // on the next render because the path itself is the truth.
            NavigationStack(path: nav.binding(\.path0)) {
                HomeView().routeDestinations { nav.popCounted(\.path0) }
                    .toolbar(nav.path0.isEmpty ? .visible : .hidden, for: .tabBar)
            }
            .tabItem { Label("首页", systemImage: "play.rectangle") }
            .tag(0)

            NavigationStack(path: nav.binding(\.path1)) {
                LibrariesTabView().routeDestinations { nav.popCounted(\.path1) }
                    .toolbar(nav.path1.isEmpty ? .visible : .hidden, for: .tabBar)
            }
            .tabItem { Label("资源库", systemImage: "externaldrive") }
            .tag(1)

            NavigationStack(path: nav.binding(\.path2)) {
                RecordsView().routeDestinations { nav.popCounted(\.path2) }
                    .toolbar(nav.path2.isEmpty ? .visible : .hidden, for: .tabBar)
            }
            .tabItem { Label("记录", systemImage: "person.text.rectangle") }
            .tag(2)

            NavigationStack(path: nav.binding(\.path3)) {
                SettingsView().routeDestinations { nav.popCounted(\.path3) }
                    .toolbar(nav.path3.isEmpty ? .visible : .hidden, for: .tabBar)
            }
            .tabItem { Label("设置", systemImage: "gearshape") }
            .tag(3)

            NavigationStack(path: nav.binding(\.path4)) {
                SearchTabView().routeDestinations { nav.popCounted(\.path4) }
                    .toolbar(nav.path4.isEmpty ? .visible : .hidden, for: .tabBar)
            }
            .tabItem { Label("搜索", systemImage: "magnifyingglass") }
            .tag(4)
        }
        .tint(.blue)
        .task {
            // Warm the libraries catalog in the background so the
            // 资源库 tab opens already populated instead of loading
            // section by section.
            let catalog = CatalogCache.shared
            catalog.syncKey(store.activeServer?.id)
            if let client = store.client() {
                await catalog.ensureLibraries(client: client)
            }
        }
        .environment(shell)
        .environment(\.zoomNS, zoomNS)
        .onChange(of: tab) { _, newValue in
            UserDefaults.standard.set(newValue, forKey: "app.lastTab")
        }
        .onChange(of: shell.searchRequested) { _, requested in
            if requested {
                shell.searchRequested = false
                tab = 4
            }
        }
        .onChange(of: shell.recordsRequest) { _, requested in
            if requested != nil { tab = 2 }
        }
    }
}
