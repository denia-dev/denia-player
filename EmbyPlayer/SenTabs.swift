import SwiftUI

// MARK: - shared cells

/// 16:9 card with resume time + progress, SenPlayer continue-watching style.
struct WideCard: View {
    let item: EmbyItem
    let client: EmbyClient
    @Environment(\.zoomNS) private var zoomNS

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ItemImage(item: item, client: client, kind: wideImageKind(item))
                .frame(maxWidth: .infinity)
                .aspectRatio(16 / 9, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .overlay(alignment: .bottom) {
                    if item.resumeSeconds > 0, item.durationSeconds > 0 {
                        ZStack(alignment: .bottom) {
                            LinearGradient(colors: [.clear, .black.opacity(0.5)],
                                           startPoint: .top, endPoint: .bottom)
                                .allowsHitTesting(false)
                            VStack(spacing: 4) {
                                HStack(spacing: 4) {
                                    Spacer()
                                    Image(systemName: "play.fill").font(.system(size: 9))
                                    Text("\(formatHMS(item.resumeSeconds)) / \(formatHMS(item.durationSeconds))")
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8)
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(.white.opacity(0.35)).frame(height: 3)
                                        Capsule().fill(.white)
                                            .frame(width: geo.size.width * min(item.resumeSeconds / item.durationSeconds, 1), height: 3)
                                    }
                                }
                                .frame(height: 3)
                                .padding(.horizontal, 8)
                                .padding(.bottom, 6)
                            }
                        }
                    }
                }
                .zoomSource(id: item.Id, ns: zoomNS)
            Text(cardTitle).font(.system(size: 16, weight: .semibold)).lineLimit(1)
            Text(cardSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .foregroundStyle(.primary)
    }

    private var cardTitle: String {
        item.type == "Episode" ? (item.SeriesName ?? item.Name) : item.Name
    }

    private var cardSubtitle: String {
        if item.type == "Episode" {
            let s = item.ParentIndexNumber ?? 0, e = item.IndexNumber ?? 0
            return String(format: "S%02d · E%02d · %@", s, e, item.Name)
        }
        if let year = item.ProductionYear { return String(year) }
        return item.type == "Series" ? "剧集" : ""
    }
}

struct PosterCell: View {
    let item: EmbyItem
    let client: EmbyClient
    var width: CGFloat? = nil
    @Environment(\.zoomNS) private var zoomNS

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                ItemImage(item: item, client: client)
                    .modifier(PosterFrame(width: width))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if item.type == "Series", let unplayed = item.UserData?.UnplayedItemCount, unplayed > 0 {
                    Text("\(unplayed) 集未看")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                        .padding(6)
                }
            }
            .zoomSource(id: item.Id, ns: zoomNS)
            Text(item.Name).font(.caption).lineLimit(1)
                .frame(width: width, alignment: .leading)
            if let year = item.ProductionYear {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            } else if item.type == "Series" {
                Text("剧集").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct PosterFrame: ViewModifier {
    let width: CGFloat?
    func body(content: Content) -> some View {
        if let width {
            content.frame(width: width, height: width * 1.5)
        } else {
            content.frame(maxWidth: .infinity).aspectRatio(2 / 3, contentMode: .fill)
        }
    }
}

// MARK: - 资源库 (sources + libraries)

struct LibrariesTabView: View {
    @Environment(AppStore.self) private var store
    @State private var libraries: [EmbyItem] = []
    @State private var showServers = false

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("资源库").font(.system(size: 32, weight: .bold))
                    Spacer()
                    HStack(spacing: 18) {
                        Button { showServers = true } label: {
                            Image(systemName: "plus").font(.system(size: 19, weight: .medium))
                        }
                        Menu {
                            Button { Task { await load() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                            Button { showServers = true } label: { Label("管理服务器", systemImage: "server.rack") }
                        } label: {
                            Image(systemName: "ellipsis.circle").font(.system(size: 19))
                        }
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: Capsule())
                }

                LazyVGrid(columns: columns, spacing: 14) {
                    serverCard
                    ForEach(Array(libraries.enumerated()), id: \.element.Id) { index, library in
                        NavigationLink(value: Route.library(library)) {
                            libraryCard(library, index: index)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .sheet(isPresented: $showServers) { ServersView() }
    }

    private var serverCard: some View {
        VStack(alignment: .leading) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(store.activeServer?.name ?? "服务器")
                        .font(.headline).lineLimit(2)
                    Text("Emby").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.green)
                    .frame(width: 42, height: 42)
                    .overlay(Image(systemName: "play.fill").foregroundStyle(.white))
            }
            Spacer()
            HStack {
                Text("主线路").font(.caption).foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("在线").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(height: 148)
        .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 24))
    }

    private func libraryCard(_ library: EmbyItem, index: Int) -> some View {
        let style = cardStyle(for: library)
        return VStack(alignment: .leading) {
            HStack(alignment: .top) {
                Text(library.Name).font(.headline).lineLimit(2)
                Spacer()
                Image(systemName: style.icon)
                    .font(.system(size: 30))
                    .foregroundStyle(style.color)
            }
            Spacer()
            HStack {
                Text(style.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let count = library.ChildCount {
                    Text("\(count) 项").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(height: 148)
        .background(style.color.opacity(0.13), in: RoundedRectangle(cornerRadius: 24))
    }

    private func cardStyle(for library: EmbyItem) -> (icon: String, color: Color, label: String) {
        switch library.CollectionType {
        case "movies": return ("film.fill", .blue, "电影")
        case "tvshows": return ("tv.fill", .purple, "剧集")
        case "music": return ("music.note", .pink, "音乐")
        case "photos": return ("photo.fill", .orange, "照片")
        default: return ("folder.fill", .yellow, "媒体库")
        }
    }

    private func load() async {
        guard let client = store.client() else { return }
        libraries = (try? await client.libraries()) ?? []
    }
}

// MARK: - 记录

struct RecordsView: View {
    @Environment(AppStore.self) private var store
    @Environment(ShellState.self) private var shell
    @State private var segment = 1
    @State private var resume: [EmbyItem] = []
    @State private var favorites: [EmbyItem] = []
    @State private var history: [EmbyItem] = []

    private let wideColumns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]
    private var posterColumns: [GridItem] {
        (0..<Prefs.posterColumns).map { _ in GridItem(.flexible(), spacing: 12) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 2) {
                ForEach(Array(["通用", "观看", "收藏", "下载"].enumerated()), id: \.offset) { index, label in
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { segment = index }
                    } label: {
                        Text(label)
                            .font(.subheadline.weight(segment == index ? .semibold : .regular))
                            .foregroundStyle(segment == index ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background {
                                if segment == index {
                                    Color.clear
                                        .glassEffect(.regular.tint(Color.primary.opacity(0.05)), in: Capsule())
                                }
                            }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background {
                Color.clear.glassEffect(.regular, in: Capsule())
            }
            .shadow(color: .black.opacity(0.10), radius: 12, y: 4)
            .padding(.horizontal)
            .padding(.top, 8)
            .onChange(of: shell.recordsRequest) { _, requested in
                if let requested {
                    segment = requested
                    shell.recordsRequest = nil
                }
            }

            Text(segment == 0 ? "最近播放" : (segment == 1 ? "媒体观看" : (segment == 2 ? "我的收藏" : "我的下载")))
                .font(.system(size: 30, weight: .bold))
                .padding(.horizontal)

            ScrollView {
                if segment == 3 {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("下载页标记 build70")
                            .font(.caption2).foregroundStyle(.tertiary)
                        DownloadsView()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 92)
                } else if let client = store.client() {
                    if segment == 1 {
                        VStack(alignment: .leading, spacing: 14) {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color.green)
                                    .frame(width: 24, height: 24)
                                    .overlay(Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white))
                                Text(store.activeServer?.name ?? "")
                                    .font(.headline)
                                Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                            }
                            if resume.isEmpty {
                                Text("暂无观看记录").foregroundStyle(.secondary).font(.subheadline)
                            }
                            LazyVGrid(columns: wideColumns, spacing: 18) {
                                ForEach(resume) { item in
                                    NavigationLink(value: Route.detail(item)) {
                                        WideCard(item: item, client: client)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                        .padding(.horizontal)
                    } else if segment == 2 {
                        if favorites.isEmpty {
                            Text("暂无收藏").foregroundStyle(.secondary).font(.subheadline).padding(.horizontal)
                        }
                        LazyVGrid(columns: posterColumns, spacing: 16) {
                            ForEach(favorites) { item in
                                NavigationLink(value: Route.detail(item)) {
                                    PosterCell(item: item, client: client)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    } else {
                        if history.isEmpty {
                            Text("暂无播放历史").foregroundStyle(.secondary).font(.subheadline).padding(.horizontal)
                        }
                        LazyVGrid(columns: wideColumns, spacing: 18) {
                            ForEach(history) { item in
                                NavigationLink(value: Route.detail(item)) {
                                    WideCard(item: item, client: client)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                    Spacer(minLength: 92)
                }
            }
            .id(segment)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private func load() async {
        guard let client = store.client() else { return }
        resume = (try? await client.resumeItems()) ?? []
        favorites = (try? await client.favoriteItems()) ?? []
        history = (try? await client.historyItems()) ?? []
    }
}

// MARK: - 设置

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @State private var showServers = false
    @State private var cacheNote: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("设置").font(.system(size: 32, weight: .bold))

                Button { showServers = true } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.green)
                            .frame(width: 42, height: 42)
                            .overlay(Image(systemName: "play.fill").foregroundStyle(.white))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.activeServer?.name ?? "未登录").font(.headline)
                            Text(lineLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
                }
                .buttonStyle(.plain)

                settingsGroup("通用") {
                    SettingRow(icon: "server.rack", color: .blue, title: "服务器管理") {
                        showServers = true
                    }
                    Divider().padding(.leading, 58)
                    Menu {
                        if let server = store.activeServer {
                            ForEach(server.baseURLs.indices, id: \.self) { index in
                                Button {
                                    var config = server
                                    config.activeLine = index
                                    store.update(config)
                                } label: {
                                    Label(URL(string: server.baseURLs[index])?.host ?? server.baseURLs[index],
                                          systemImage: server.activeLine == index ? "checkmark" : "")
                                }
                            }
                        }
                    } label: {
                        SettingRowContent(icon: "arrow.triangle.2.circlepath", color: .green, title: "切换线路",
                                          value: lineLabel, chevron: true)
                    }
                    Divider().padding(.leading, 58)
                    SettingRow(icon: "trash", color: .orange, title: "清除图片缓存", value: cacheNote) {
                        URLCache.shared.removeAllCachedResponses()
                        cacheNote = "已清除"
                    }
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.appPrefs) {
                        SettingRowContent(icon: "paintpalette.fill", color: .pink, title: "应用偏好",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.modulePrefs) {
                        SettingRowContent(icon: "square.grid.2x2.fill", color: .green, title: "模块配置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.listPrefs) {
                        SettingRowContent(icon: "list.bullet", color: .teal, title: "列表配置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.privacyPrefs) {
                        SettingRowContent(icon: "lock.fill", color: .gray, title: "隐私保护",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("播放") {
                    NavigationLink(value: Route.playbackPrefs) {
                        SettingRowContent(icon: "play.fill", color: .red, title: "播放设置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.interfacePrefs) {
                        SettingRowContent(icon: "display", color: .orange, title: "界面偏好",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.gesturePrefs) {
                        SettingRowContent(icon: "hand.tap.fill", color: .blue, title: "播放手势",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("音视频") {
                    NavigationLink(value: Route.videoPrefs) {
                        SettingRowContent(icon: "video.fill", color: .blue, title: "视频设置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.audioPrefs) {
                        SettingRowContent(icon: "headphones", color: .blue, title: "音频设置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.subtitlePrefs) {
                        SettingRowContent(icon: "captions.bubble.fill", color: .orange, title: "字幕设置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("数据") {
                    NavigationLink(value: Route.cachePrefs) {
                        SettingRowContent(icon: "internaldrive.fill", color: .brown, title: "缓存管理",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("关于") {
                    SettingRowContent(icon: "info.circle", color: .gray, title: "版本", value: "1.0", chevron: false)
                    Divider().padding(.leading, 58)
                    SettingRowContent(icon: "play.rectangle.on.rectangle", color: .purple, title: "播放内核", value: "mpv · VLCKit", chevron: false)
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showServers) { ServersView() }
    }

    private var lineLabel: String {
        guard let server = store.activeServer else { return "" }
        let host = URL(string: server.baseURL)?.host ?? server.baseURL
        return "线路 \(server.activeLine + 1) · \(host)"
    }

    private func settingsGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline).foregroundStyle(.secondary).padding(.leading, 6)
            VStack(spacing: 0) { content() }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
        }
    }
}

struct SettingRowContent: View {
    let icon: String
    let color: Color
    let title: String
    var value: String? = nil
    var chevron: Bool = true

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(color)
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.white))
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
    }
}

struct SettingRow: View {
    let icon: String
    let color: Color
    let title: String
    var value: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SettingRowContent(icon: icon, color: color, title: title, value: value)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 搜索

struct SearchTabView: View {
    @Environment(AppStore.self) private var store
    @State private var text = ""
    @State private var results: [EmbyItem] = []
    @State private var searched = false
    @State private var history: [String] = UserDefaults.standard.stringArray(forKey: "prefs.searchHistory") ?? []

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索电影、剧集", text: $text)
                    .submitLabel(.search)
                    .onSubmit { recordHistory() }
                if !text.isEmpty {
                    Button { text = ""; results = []; searched = false } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Color(.systemGray6), in: Capsule())
            .padding(.horizontal)
            .padding(.top, 10)

            if let client = store.client() {
                if results.isEmpty {
                    if !searched && text.isEmpty && !history.isEmpty {
                        historyList
                    } else {
                        Spacer()
                        Text(searched ? "没有找到结果" : "输入片名，聚合搜索当前服务器")
                            .foregroundStyle(.secondary).font(.subheadline)
                        Spacer()
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(results) { item in
                                NavigationLink(value: Route.detail(item)) {
                                    PosterCell(item: item, client: client)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                        .padding(.bottom, 32)
                    }
                }
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: text) {
            let term = text
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { results = []; searched = false; return }
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let client = store.client() else { return }
            let matches = (try? await client.search(term: trimmed)) ?? []
            guard !Task.isCancelled, text == term else { return }
            results = matches
            searched = true
        }
    }
}


private extension SearchTabView {
    func recordHistory() {
        let term = text.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return }
        history.removeAll { $0 == term }
        history.insert(term, at: 0)
        history = Array(history.prefix(10))
        UserDefaults.standard.set(history, forKey: "prefs.searchHistory")
    }

    var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("最近搜索")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("清空") {
                        history = []
                        UserDefaults.standard.removeObject(forKey: "prefs.searchHistory")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.bottom, 4)
                ForEach(history, id: \.self) { term in
                    Button { text = term } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                            Text(term).lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 2)
        }
    }
}
