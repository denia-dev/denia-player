import SwiftUI

/// Image URL helper bound to the active client.
struct ItemImage: View {
    let item: EmbyItem
    let client: EmbyClient
    var kind: String = "Primary"

    /// Shown when the server has no usable image: a titled tile instead of
    /// an invisible hole in the grid.
    private var imagePlaceholder: some View {
        ZStack {
            Rectangle().fill(Color.primary.opacity(0.07))
            VStack(spacing: 6) {
                Image(systemName: item.type == "Movie" ? "film" : "tv")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(item.Name)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 6)
            }
        }
    }

    var body: some View {
        let sourceID = (kind == "Primary" && item.type == "Episode" && item.ImageTags?["Primary"] == nil)
            ? (item.SeriesId ?? item.Id) : item.Id
        return AsyncImage(url: client.imageURL(itemID: sourceID, kind: kind)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            case .failure: imagePlaceholder
            default: Rectangle().fill(.quaternary)
            }
        }
    }
}

/// Backdrop when the item has one, poster otherwise (wide cards).
func wideImageKind(_ item: EmbyItem) -> String {
    (item.BackdropImageTags?.isEmpty == false) ? "Backdrop" : "Primary"
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(ShellState.self) private var shell
    @Environment(\.zoomNS) private var zoomNS
    @State private var libraries: [EmbyItem] = []
    @State private var resume: [EmbyItem] = []
    @State private var latest: [EmbyItem] = []
    @State private var heroIndex = 0
    @State private var showServers = false
    @State private var errorText: String?

    private var heroItems: [EmbyItem] { latest.isEmpty ? resume : latest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote).padding(.horizontal)
                }
                if Prefs.showHomeResume, !resume.isEmpty, let client = store.client() {
                    sectionHeader("继续观看", count: resume.count) { shell.recordsRequest = 0 }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(resume) { item in
                                NavigationLink(value: Route.detail(item)) {
                                    WideCard(item: item, client: client)
                                        .frame(width: 292)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if Prefs.showHomeLibraries, !libraries.isEmpty, let client = store.client() {
                    sectionHeader("我的媒体库", count: nil)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(libraries) { library in
                                NavigationLink(value: Route.library(library)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ItemImage(item: library, client: client)
                                            .frame(width: 104, height: 156)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                        Text(library.Name).font(.caption).lineLimit(1)
                                            .frame(width: 104, alignment: .leading)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                if Prefs.showHomeLatest, !latest.isEmpty, let client = store.client() {
                    sectionHeader("最新添加", count: nil)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(latest) { item in
                                NavigationLink(value: Route.detail(item)) {
                                    PosterCell(item: item, client: client, width: 104)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .padding(.bottom, 32)
            .background { homeAmbientScrolling }
        }
        .ignoresSafeArea(edges: .top)
        .background { homeAmbientFixed }
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
        .task { await heroAutoAdvance() }
        .sheet(isPresented: $showServers) { ServersView() }
    }

    // MARK: - ambient background

    /// The current hero item's art as the page's ambient wash - the
    /// SenPlayer home treatment he pointed at on 2026-11-23: the hero
    /// melts into a page background made of the same art, not into
    /// solid white. Two copies of one layer: one attached to the
    /// scroll content (the hero's melt fades into it and it continues
    /// uninterrupted - no step, the build-58 detail lesson) and one
    /// fixed behind the ScrollView for rubber-band regions. Both
    /// crossfade when the carousel moves.
    private var currentHeroItem: EmbyItem? {
        heroItems.isEmpty ? nil : heroItems[min(heroIndex, heroItems.count - 1)]
    }

    @ViewBuilder
    private func ambientLayer(scale: CGFloat) -> some View {
        ZStack {
            if let item = currentHeroItem, let client = store.client() {
                ItemImage(item: item, client: client, kind: wideImageKind(item))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 26)
                    .scaleEffect(scale)
                    .id(item.Id)
                    .transition(.opacity)
            }
            Color(.systemBackground).opacity(0.55)
        }
        .animation(.easeInOut(duration: 0.45), value: heroIndex)
    }

    private var homeAmbientScrolling: some View {
        ambientLayer(scale: 1.15).clipped()
    }

    private var homeAmbientFixed: some View {
        ambientLayer(scale: 1.25).ignoresSafeArea()
    }

    // MARK: - hero

    private var hero: some View {
        ZStack(alignment: .bottom) {
            if let client = store.client(), !heroItems.isEmpty {
                TabView(selection: $heroIndex) {
                    ForEach(Array(heroItems.enumerated()), id: \.element.Id) { index, item in
                        NavigationLink(value: Route.detail(item)) {
                            heroCell(item, client: client)
                        }
                        .buttonStyle(.plain)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 540)

                HStack(spacing: 6) {
                    ForEach(heroItems.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == heroIndex ? 0.95 : 0.4))
                            .frame(width: 7, height: 7)
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: heroIndex)
                .padding(.bottom, 12)
            } else {
                Rectangle().fill(.quaternary).frame(height: 300)
            }

            VStack {
                HStack {
                    Button { showServers = true } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.green)
                                .frame(width: 30, height: 30)
                                .overlay(Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white))
                            Text(store.activeServer?.name ?? "")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { shell.recordsRequest = 2 } label: {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.red)
                            .frame(width: 42, height: 42)
                            .glassEffect(.regular.interactive(), in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 58)
        }
        .frame(height: 540)
    }

    private func heroCell(_ item: EmbyItem, client: EmbyClient) -> some View {
        VStack(spacing: 8) {
                if item.ImageTags?["Logo"] != nil {
                    AsyncImage(url: client.imageURL(itemID: item.Id, kind: "Logo")) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        }
                    }
                    .frame(maxWidth: 280, maxHeight: 84)
                } else {
                    Text(item.Name)
                        .font(.system(size: 27, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Ratings/year/genres sit last in the cell, directly
                // above the page dots.
                heroMetaLine(item)
            }
        .padding(.horizontal, 28)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                ItemImage(item: item, client: client, kind: wideImageKind(item))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .zoomSource(id: item.Id, ns: zoomNS)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.35),
                    .init(color: Color(.systemBackground).opacity(0.45), location: 0.62),
                    .init(color: Color(.systemBackground).opacity(0.55), location: 0.85),
                    .init(color: Color(.systemBackground).opacity(0.55), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.62),
                    .init(color: .clear, location: 0.98),
                    .init(color: .clear, location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(height: 540)
        .clipped()
    }

    /// One info line under the hero title: ratings first (star +
    /// popcorn), then year, type/genres and runtime for movies.
    private func heroMetaLine(_ item: EmbyItem) -> some View {
        HStack(spacing: 7) {
            if let rating = item.CommunityRating {
                HStack(spacing: 3) {
                    Image(systemName: "star.fill").foregroundStyle(.orange)
                    Text(String(format: "%.1f", rating)).fontWeight(.semibold).foregroundStyle(.primary)
                }
            }
            if let critic = item.CriticRating {
                HStack(spacing: 3) {
                    Image(systemName: "popcorn").foregroundStyle(.red)
                    Text("\(Int(critic.rounded()))%").fontWeight(.semibold).foregroundStyle(.primary)
                }
            }
            if let year = item.ProductionYear {
                Text(String(year))
            }
            Text(item.type == "Series" ? "剧集" : "电影")
            if let genres = item.Genres, !genres.isEmpty {
                Text(genres.prefix(2).joined(separator: " / "))
            }
            if item.type == "Movie", item.durationSeconds > 0 {
                Text(runtimeText(seconds: item.durationSeconds))
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private func runtimeText(seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return hours > 0 ? "\(hours)小时\(minutes)分" : "\(minutes)分钟"
    }

    private func sectionHeader(_ title: String, count: Int?, action: (() -> Void)? = nil) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            if let count {
                Text("\(count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
        .contentShape(Rectangle())
        .onTapGesture { action?() }
    }

    private func heroAutoAdvance() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            guard !heroItems.isEmpty else { continue }
            withAnimation { heroIndex = (heroIndex + 1) % heroItems.count }
        }
    }

    private func load() async {
        guard let client = store.client() else { return }
        errorText = nil
        do {
            libraries = try await client.libraries()
            resume = try await client.resumeItems()
            latest = await client.latestItems()
            // Start (and refresh) on a random hero so the home page
            // does not open on the same title every time.
            if latest.count > 1 { heroIndex = Int.random(in: 0..<latest.count) }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
