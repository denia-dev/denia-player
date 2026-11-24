import SwiftUI

/// Image view bound to the active client, backed by the shared
/// decoded-image cache: one download and decode per URL across the
/// whole app, instant paint on revisit (AsyncImage re-fetched and
/// re-decoded per instance, which taxed every rail and grid).
struct ItemImage: View {
    let item: EmbyItem
    let client: EmbyClient
    var kind: String = "Primary"

    @State private var uiImage: UIImage?
    @State private var failed = false

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

    private var url: URL? {
        let sourceID = (kind == "Primary" && item.type == "Episode" && item.ImageTags?["Primary"] == nil)
            ? (item.SeriesId ?? item.Id) : item.Id
        return client.imageURL(itemID: sourceID, kind: kind)
    }

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else if failed {
                imagePlaceholder
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: url) {
            guard let url else { failed = true; return }
            if let hit = ImageMemoryCache.shared.cached(url) {
                uiImage = hit
                return
            }
            guard uiImage == nil else { return }
            failed = false
            if let loaded = await ImageMemoryCache.shared.image(for: url) {
                uiImage = loaded
            } else {
                failed = true
            }
        }
    }
}

/// Backdrop when the item has one, poster otherwise (wide cards).
func wideImageKind(_ item: EmbyItem) -> String {
    (item.BackdropImageTags?.isEmpty == false) ? "Backdrop" : "Primary"
}

/// Hero artwork with blank rejection: when the image download fails
/// or the returned image is a blank placeholder, the item reports
/// itself through onBlank and the carousel drops it. One retry first,
/// so a network hiccup does not cost a good hero its slot.
private struct HeroArtwork: View {
    let item: EmbyItem
    let client: EmbyClient
    let onBlank: (String) -> Void

    @State private var uiImage: UIImage?

    var body: some View {
        ZStack {
            if let uiImage {
                Image(uiImage: uiImage).resizable().scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .task(id: item.Id) {
            guard let url = client.imageURL(itemID: item.Id, kind: wideImageKind(item)) else {
                onBlank(item.Id)
                return
            }
            if let loaded = await ImageMemoryCache.shared.heroImage(for: url) {
                uiImage = loaded
                return
            }
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            if let loaded = await ImageMemoryCache.shared.heroImage(for: url) {
                uiImage = loaded
            } else if !Task.isCancelled {
                onBlank(item.Id)
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(ShellState.self) private var shell
    @Environment(\.zoomNS) private var zoomNS
    @State private var libraries: [EmbyItem] = []
    @State private var resume: [EmbyItem] = []
    @State private var latest: [EmbyItem] = []
    @State private var heroIndex = 0
    /// Year/ratings/runtime hydrated per hero item from the
    /// single-item endpoint (list responses omit them on goemby).
    @State private var heroMeta: [String: (year: Int?, community: Double?, critic: Double?, runTimeTicks: Int64?, imdbID: String?, tmdbID: String?)] = [:]
    @State private var ratingsStore = RatingsStore.shared
    @State private var showServers = false
    @State private var errorText: String?
    /// Hero items dropped at runtime because their artwork came back
    /// missing or blank (session-scoped; a relaunch retries them).
    @State private var heroExcluded: Set<String> = []

    /// The wide top-rated candidate pool, fetched once per load;
    /// prepareHeroes reshuffles a fresh batch out of it every time.
    @State private var heroCandidates: [EmbyItem] = []

    /// Verified heroes only: an item enters the carousel AFTER its
    /// artwork has loaded and passed the blank check AND its rating
    /// count is conclusively >= 3 (prepareHeroes). Nothing appears
    /// provisionally and vanishes again (his 2026-11-24 report).
    @State private var heroReady: [EmbyItem] = []

    private var heroItems: [EmbyItem] {
        heroReady.filter { !heroExcluded.contains($0.Id) }
    }

    /// His 2026-11-24 rule: 没有三个评分的都不要出现在轮播 - a hero
    /// needs at least three rating sources, counted from the
    /// external lookup plus the server's own two.
    private func heroRatingsVerdict(_ item: EmbyItem) -> Bool {
        let external = ratingsStore.byItemID[item.Id]
        let meta = heroMeta[item.Id]
        var count = 0
        if item.CommunityRating != nil || meta?.community != nil || external?.tmdb != nil { count += 1 }
        if external?.imdb != nil { count += 1 }
        if item.CriticRating != nil || meta?.critic != nil || external?.rtCritics != nil { count += 1 }
        if external?.rtAudience != nil { count += 1 }
        if external?.letterboxd != nil { count += 1 }
        if external?.metacritic != nil { count += 1 }
        if external?.trakt != nil { count += 1 }
        return count >= 3
    }

    /// Builds the carousel batch: reshuffle the top-rated pool,
    /// verify artwork (loads it into the memory cache, so heroes
    /// paint instantly and blank art never shows), wait for the
    /// rating lookups to settle, then admit only items with a
    /// conclusive >= 3 rating count.
    private func prepareHeroes(client: EmbyClient) async {
        if heroCandidates.isEmpty {
            heroCandidates = await client.topRatedCandidates()
        }
        let eligible = heroCandidates.filter {
            $0.BackdropImageTags?.isEmpty == false && ($0.CommunityRating ?? 0) >= 6.8
        }
        let picks = Array(eligible.shuffled().prefix(14))
        for item in picks {
            ratingsStore.ensure(itemID: item.Id,
                                imdbID: item.ProviderIds?["Imdb"],
                                tmdbID: item.ProviderIds?["Tmdb"],
                                type: item.type)
        }
        var artOK = Set<String>()
        await withTaskGroup(of: String?.self) { group in
            for item in picks {
                group.addTask {
                    guard let url = client.backdropURL(itemID: item.Id, index: 0, maxHeight: 1080) else { return nil }
                    return await ImageMemoryCache.shared.heroImage(for: url) != nil ? item.Id : nil
                }
            }
            for await id in group { if let id { artOK.insert(id) } }
        }
        // Bounded wait for the rating checks of art-verified picks.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let pending = picks.contains {
                artOK.contains($0.Id)
                    && ($0.ProviderIds?["Imdb"] != nil || $0.ProviderIds?["Tmdb"] != nil)
                    && !ratingsStore.checked.contains($0.Id)
            }
            if !pending { break }
            try? await Task.sleep(for: .milliseconds(120))
        }
        var ready = picks.filter { artOK.contains($0.Id) && heroRatingsVerdict($0) }
        if ready.count < 4 {
            // Starved gate: admit checked high scorers rather than
            // leaving the home page without a carousel.
            let extra = picks.filter { item in
                artOK.contains(item.Id)
                    && !ready.contains(where: { $0.Id == item.Id })
                    && ($0.CommunityRating ?? 0) >= 7.5
                    && ratingsStore.checked.contains(item.Id)
            }
            ready += extra
        }
        if ready.isEmpty {
            // Safety net for servers with no rated catalog at all.
            ready = latest.filter { $0.BackdropImageTags?.isEmpty == false }
        }
        heroReady = Array(ready.prefix(10))
        if heroReady.count > 1 { heroIndex = Int.random(in: 0..<heroReady.count) }
        await loadHeroMeta(client: client)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
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
                AmbientImageView(url: client.imageURL(itemID: item.Id, kind: wideImageKind(item)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .scaleEffect(scale)
                    .id(item.Id)
                    .transition(.opacity)
            }
            Color(.systemBackground).opacity(0.55)
        }
        .animation(.easeInOut(duration: 0.45), value: currentHeroItem?.Id)
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
                // Paging ScrollView instead of a page-style TabView:
                // the TabView's settle animation held hit-testing on
                // the incoming page (taps landed dead for a beat after
                // every swipe/auto-advance), while the scroll view
                // takes touches the moment the finger lands.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(heroItems.enumerated()), id: \.element.Id) { index, item in
                            NavigationLink(value: Route.detail(item)) {
                                heroCell(item, client: client)
                            }
                            .buttonStyle(.plain)
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding<Int?>(
                    get: { heroIndex },
                    set: { if let newValue = $0 { heroIndex = newValue } }
                ))
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
        VStack(spacing: 10) {
                if item.ImageTags?["Logo"] != nil {
                    SharedImage(url: client.imageURL(itemID: item.Id, kind: "Logo"), fill: false)
                        .frame(maxWidth: 280, maxHeight: 84)
                } else {
                    Text(item.Name)
                        .font(.system(size: 27, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                // SenPlayer hero layout: title, meta line, overview,
                // then the ratings on their own row above the dots.
                heroMetaLine(item)
                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                heroRatingsRow(item)
            }
        .padding(.horizontal, 28)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                HeroArtwork(item: item, client: client) { id in
                    heroExcluded.insert(id)
                }
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

    /// The hero meta line (SenPlayer layout): year · type · genres.
    /// Ratings live on their own row (heroRatingsRow).
    private func heroMetaLine(_ item: EmbyItem) -> some View {
        let productionYear = item.ProductionYear ?? heroMeta[item.Id]?.year ?? nil
        return HStack(spacing: 7) {
            if let year = productionYear {
                Text(String(year))
            }
            Text(item.type == "Series" ? "剧集" : "电影")
            if let genres = item.Genres, !genres.isEmpty {
                Text(genres.prefix(2).joined(separator: " / "))
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    /// Ratings on their own row, SenPlayer style: a source badge +
    /// score per source. The server gives us two scores: the
    /// community rating (TMDB's in Emby metadata) and the critic
    /// rating (Rotten Tomatoes %). There is no separate IMDb score
    /// field in the item data, so no IMDb chip.
    @ViewBuilder
    private func heroRatingsRow(_ item: EmbyItem) -> some View {
        let meta = heroMeta[item.Id]
        let community = item.CommunityRating ?? meta?.community ?? nil
        let critic = item.CriticRating ?? meta?.critic ?? nil
        let ticks = item.RunTimeTicks ?? meta?.runTimeTicks ?? nil
        let external = ratingsStore.byItemID[item.Id]
        if external != nil || community != nil || critic != nil || (item.type == "Movie" && ticks != nil) {
            HStack(spacing: 18) {
                RatingsStrip(external: external, fallbackCommunity: community, fallbackCritic: critic, large: true)
                if item.type == "Movie", let ticks, ticks > 0 {
                    Text(runtimeText(seconds: Double(ticks) / 10_000_000))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 2)
        }
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
            await prepareHeroes(client: client)
        } catch {
            errorText = error.localizedDescription
        }
    }

    /// Fills heroMeta for the current hero items (best-effort,
    /// concurrent; failures just leave the line without that field).
    private func loadHeroMeta(client: EmbyClient) async {
        let items = heroItems
        await withTaskGroup(of: (String, (year: Int?, community: Double?, critic: Double?, runTimeTicks: Int64?, imdbID: String?, tmdbID: String?)?).self) { group in
            for item in items where item.ProductionYear == nil || item.CommunityRating == nil {
                group.addTask { (item.Id, await client.itemMeta(id: item.Id)) }
            }
            for await (id, meta) in group {
                if let meta { heroMeta[id] = meta }
            }
        }
        // Kick off multi-source rating lookups for the heroes; the
        // strip fills in as MDBList answers land.
        for item in items {
            let meta = heroMeta[item.Id]
            ratingsStore.ensure(itemID: item.Id,
                                imdbID: item.ProviderIds?["Imdb"] ?? meta?.imdbID ?? nil,
                                tmdbID: item.ProviderIds?["Tmdb"] ?? meta?.tmdbID ?? nil,
                                type: item.type)
        }
    }
}
