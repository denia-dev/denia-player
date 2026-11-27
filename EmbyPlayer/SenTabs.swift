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
                if let rating = item.CommunityRating, rating > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "star.fill").font(.system(size: 8))
                            .foregroundStyle(.yellow)
                        Text(String(format: "%.1f", rating))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
                }
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

/// Session-resident catalog data for the libraries tab. Sections
/// used to fetch for themselves inside a LazyVStack: scrolled-off
/// sections were destroyed, their state reset, and coming back
/// re-ran the whole fetch chain (list + count + a per-item meta
/// call each), so the page rebuilt itself frame by frame on every
/// visit. The data now lives here, keyed by server: views render
/// whatever is cached instantly, stale entries revalidate in the
/// background WITHOUT clearing what is on screen, and a gentle
/// sequential prefetch warms every section after the library list
/// lands.
@MainActor
@Observable
final class CatalogCache {
    static let shared = CatalogCache()

    typealias ItemMeta = (year: Int?, community: Double?, critic: Double?, runTimeTicks: Int64?, imdbID: String?, tmdbID: String?)

    struct SectionData {
        var items: [EmbyItem] = []
        var count: Int?
        var meta: [String: ItemMeta] = [:]
    }

    private(set) var serverKey: String?
    private(set) var libraries: [EmbyItem] = []
    private(set) var sections: [String: SectionData] = [:]

    private var librariesLoadedAt: Date?
    private var sectionLoadedAt: [String: Date] = [:]
    private var loadingLibraries = false
    private var loadingSections: Set<String> = []
    private var prefetchTask: Task<Void, Never>?

    private let staleInterval: TimeInterval = 600

    private func isFresh(_ date: Date?) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < staleInterval
    }

    /// Point the cache at a server; switching servers drops the old
    /// server's data.
    func syncKey(_ key: String?) {
        guard serverKey != key else { return }
        serverKey = key
        libraries = []
        sections = [:]
        librariesLoadedAt = nil
        sectionLoadedAt = [:]
        prefetchTask?.cancel()
        prefetchTask = nil
    }

    func ensureLibraries(client: EmbyClient, force: Bool = false) async {
        if loadingLibraries { return }
        if !force, librariesLoadedAt != nil, isFresh(librariesLoadedAt) { return }
        loadingLibraries = true
        defer { loadingLibraries = false }
        if let fetched = try? await client.libraries() {
            libraries = fetched
            librariesLoadedAt = Date()
        }
        guard librariesLoadedAt != nil else { return }
        // Warm the sections one at a time in the background; a
        // section already on screen reads the cache the moment its
        // data lands.
        prefetchTask?.cancel()
        let libs = libraries
        prefetchTask = Task { [weak self] in
            for lib in libs {
                if Task.isCancelled { return }
                await self?.ensureSection(libraryID: lib.Id, client: client, force: force)
            }
        }
    }

    func ensureSection(libraryID: String, client: EmbyClient, force: Bool = false) async {
        if loadingSections.contains(libraryID) { return }
        if !force, sections[libraryID] != nil, isFresh(sectionLoadedAt[libraryID]) { return }
        loadingSections.insert(libraryID)
        defer { loadingSections.remove(libraryID) }
        async let fetchedCount = client.libraryItemCount(parentID: libraryID)
        guard let fetched = try? await client.latestInLibrary(parentID: libraryID) else { return }
        var data = sections[libraryID] ?? SectionData()
        data.items = fetched
        if let count = await fetchedCount { data.count = count }
        sections[libraryID] = data
        sectionLoadedAt[libraryID] = Date()
        // Hydrate year/rating for items the list payload omitted;
        // results persist in the cache, so this runs once per item
        // per session instead of on every visit.
        let missing = fetched.filter {
            ($0.ProductionYear == nil || $0.CommunityRating == nil) && data.meta[$0.Id] == nil
        }
        guard !missing.isEmpty else { return }
        await withTaskGroup(of: (String, ItemMeta?).self) { group in
            for item in missing {
                group.addTask { (item.Id, await client.itemMeta(id: item.Id)) }
            }
            for await (id, fetchedMeta) in group {
                if let fetchedMeta { data.meta[id] = fetchedMeta }
            }
        }
        sections[libraryID] = data
    }
}

struct LibrariesTabView: View {
    @Environment(AppStore.self) private var store
    @State private var catalog = CatalogCache.shared
    @State private var showServers = false

    private var libraries: [EmbyItem] { catalog.libraries }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header
                ForEach(Array(libraries.enumerated()), id: \.offset) { _, library in
                    LibraryRailSection(library: library)
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

    /// SenPlayer-style header: a server pill (tap to manage/switch
    /// servers) instead of a big title.
    private var header: some View {
        HStack(spacing: 10) {
            Button { showServers = true } label: {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.green)
                        .frame(width: 30, height: 30)
                        .overlay(Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white))
                    Text(store.activeServer?.name ?? "服务器")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: Capsule())
            }
            .buttonStyle(.plain)
            Spacer()
            Menu {
                Button { Task { await load(force: true) } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                Button { showServers = true } label: { Label("管理服务器", systemImage: "server.rack") }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 22))
                    .foregroundStyle(.primary)
            }
        }
    }

    private func load(force: Bool = false) async {
        catalog.syncKey(store.activeServer?.id)
        guard let client = store.client() else { return }
        await catalog.ensureLibraries(client: client, force: force)
    }
}

/// One library as a SenPlayer-style section: a header row (name,
/// total count, chevron into the full grid) over a horizontal rail
/// of its latest additions. Poster cells always render their title
/// and a titled placeholder when the server has no usable image, so
/// a missing poster never leaves a blank hole in the rail. All data
/// comes from CatalogCache, so a section recreated by the lazy stack
/// renders its content immediately instead of refetching.
private struct LibraryRailSection: View {
    @Environment(AppStore.self) private var store
    @State private var catalog = CatalogCache.shared
    let library: EmbyItem

    private var data: CatalogCache.SectionData? { catalog.sections[library.Id] }
    private var items: [EmbyItem] { data?.items ?? [] }
    private var count: Int? { data?.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NavigationLink(value: Route.library(library)) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(library.Name).font(.system(size: 21, weight: .bold))
                    Spacer()
                    if let count {
                        Text("\(count)").foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .buttonStyle(.plain)
            if !items.isEmpty, let client = store.client() {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            NavigationLink(value: Route.detail(item)) {
                                railCell(item, client: client)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .task {
            if let client = store.client() {
                await catalog.ensureSection(libraryID: library.Id, client: client)
            }
        }
    }

    private func railCell(_ item: EmbyItem, client: EmbyClient) -> some View {
        let rating = item.CommunityRating ?? data?.meta[item.Id]?.community ?? nil
        let year = item.ProductionYear ?? data?.meta[item.Id]?.year ?? nil
        return VStack(alignment: .leading, spacing: 6) {
            ItemImage(item: item, client: client)
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    if let rating {
                        Text(String(format: "%.1f", rating))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                            .padding(6)
                    }
                }
            Text(item.Name)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
            if let year {
                Text(String(year))
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 110)
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

            if segment == 3 {
                // Downloads live in their OWN scroll view: as a conditional
                // branch inside the shared one, this content never appeared
                // on device (builds 68-70) while sibling branches rendered.
                ScrollView {
                    DownloadsView()
                        .padding(.horizontal)
                        .padding(.bottom, 92)
                }
            } else {
            ScrollView {
                if let client = store.client() {
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

                serverCard

                settingsGroup("通用") {
                    SettingRow(icon: "trash", color: .orange, title: "清除图片缓存", value: cacheNote) {
                        ImageMemoryCache.shared.clearAll()
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
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.aiTranslatePrefs) {
                        SettingRowContent(icon: "globe", color: .teal, title: "AI 字幕翻译",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("数据") {
                    NavigationLink(value: Route.downloadPrefs) {
                        SettingRowContent(icon: "arrow.down.circle.fill", color: .blue, title: "下载设置",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                    Divider().padding(.leading, 58)
                    NavigationLink(value: Route.cachePrefs) {
                        SettingRowContent(icon: "internaldrive.fill", color: .brown, title: "缓存管理",
                                          value: nil, chevron: true)
                    }
                    .buttonStyle(.plain)
                }

                settingsGroup("关于") {
                    SettingRowContent(icon: "info.circle", color: .gray, title: "版本", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))", chevron: false)
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

    private static let brandPink = Color(red: 1.0, green: 0.18, blue: 0.53)
    private static let brandBlue = Color(red: 0.0, green: 0.57, blue: 1.0)

    /// 当前服务器卡片：点卡片进服务器管理，多线路直接在卡片里点选切换
    /// （原「服务器管理」「切换线路」两行已并入此卡片）。
    private var serverCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { showServers = true } label: {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(LinearGradient(colors: [Self.brandPink, Self.brandBlue],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 46, height: 46)
                        .overlay(Image(systemName: "play.fill").foregroundStyle(.white))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(store.activeServer?.name ?? "未登录").font(.headline)
                        HStack(spacing: 5) {
                            Circle()
                                .fill(store.activeServer?.isLoggedIn == true ? Color.green : Color.orange)
                                .frame(width: 6, height: 6)
                            Text(lineLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    Text("管理").font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let server = store.activeServer, server.baseURLs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(server.baseURLs.indices, id: \.self) { index in
                            Button {
                                var config = server
                                config.activeLine = index
                                store.update(config)
                            } label: {
                                Text("线路 \(index + 1)")
                                    .font(.caption.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .foregroundStyle(server.activeLine == index ? .white : .primary)
                                    .background(server.activeLine == index ? Self.brandPink : Color(.tertiarySystemGroupedBackground),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.secondarySystemGroupedBackground))
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(colors: [Self.brandPink.opacity(0.12), Self.brandBlue.opacity(0.09)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
            }
        }
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
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [color, color.opacity(0.68)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: color.opacity(0.28), radius: 3, x: 0, y: 1.5)
            Text(title).foregroundStyle(.primary)
            Spacer()
            if let value {
                Text(value).foregroundStyle(.secondary).lineLimit(1)
            }
            if chevron {
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
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
