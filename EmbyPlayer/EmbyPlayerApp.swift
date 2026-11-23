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

/// SenPlayer-style shell: five tabs, each with its own navigation stack,
/// under one floating glass capsule bar. The capsule only shows on tab
/// roots (it hides while a detail/library page is pushed).
struct MainView: View {
    @State private var tab = 0
    @State private var path0 = NavigationPath()
    @State private var path1 = NavigationPath()
    @State private var path2 = NavigationPath()
    @State private var path3 = NavigationPath()
    @State private var path4 = NavigationPath()

    private var activeDepth: Int {
        switch tab {
        case 0: return path0.count
        case 1: return path1.count
        case 2: return path2.count
        case 3: return path3.count
        default: return path4.count
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                NavigationStack(path: $path0) { HomeView() }
                    .opacity(tab == 0 ? 1 : 0)
                    .allowsHitTesting(tab == 0)
                NavigationStack(path: $path1) { LibrariesTabView() }
                    .opacity(tab == 1 ? 1 : 0)
                    .allowsHitTesting(tab == 1)
                NavigationStack(path: $path2) { RecordsView() }
                    .opacity(tab == 2 ? 1 : 0)
                    .allowsHitTesting(tab == 2)
                NavigationStack(path: $path3) { SettingsView() }
                    .opacity(tab == 3 ? 1 : 0)
                    .allowsHitTesting(tab == 3)
                NavigationStack(path: $path4) { SearchTabView() }
                    .opacity(tab == 4 ? 1 : 0)
                    .allowsHitTesting(tab == 4)
            }

            if activeDepth == 0 {
                CapsuleTabBar(tab: $tab)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.22), value: activeDepth == 0)
    }
}

struct CapsuleTabBar: View {
    @Binding var tab: Int
    @Namespace private var glassNamespace

    private let items: [(icon: String, filled: String, label: String)] = [
        ("play.rectangle", "play.rectangle.fill", "首页"),
        ("externaldrive", "externaldrive.fill", "资源库"),
        ("person.text.rectangle", "person.text.rectangle.fill", "记录"),
        ("gearshape", "gearshape.fill", "设置"),
        ("magnifyingglass", "magnifyingglass", "搜索"),
    ]

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    let selected = tab == index
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                            tab = index
                        }
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: selected ? items[index].filled : items[index].icon)
                                .font(.system(size: 20))
                            Text(items[index].label)
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(selected ? Color.blue : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if selected {
                                Color.clear
                                    .glassEffect(.regular.tint(Color(.systemGray5).opacity(0.6)), in: Capsule())
                                    .glassEffectID("tabSelection", in: glassNamespace)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background {
                Color.clear
                    .glassEffect(.regular, in: Capsule())
            }
        }
    }
}
