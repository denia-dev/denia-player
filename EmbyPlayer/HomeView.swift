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

/// Hero artwork: the full backdrop fit to width, pinned to the top
/// of the hero over the page tint. Backdrops are 16:9 and the hero
/// frame is tall, so every fill-crop shows only ~42% of the width
/// and the subject lands wherever the crop window happens to sit -
/// centre crop and the v1.29 Vision focal point both produced
/// framings with no subject at all (his 2026-11-25 screenshots: a
/// hand, half a face at the edge, a ribbon close-up). Fitting the
/// whole backdrop to width is deterministic: the complete
/// composition, subject included, is always in frame, and the area
/// below the band is the flat page tint the title block sits on.
/// Deliberately built from plain frames only - no GeometryReader,
/// no zoom source: the v1.33 build (verified to contain the
/// fit-width code, version 1.33 (134) on device) still rendered
/// pixel-identical to the old crop on his phone, so v1.34 removed
/// every layout mechanism that could be involved. The blur in
/// here lives strictly ABOVE the band (v1.41, his exact
/// geometry): the artwork's top rows smear upward into the flat
/// tint so there is no separation line, while the band itself -
/// subject included - stays fully sharp. v1.40 blurred the top
/// half OF the band and fogged the subject; v1.38 filled the
/// whole frame with a scaled copy and read as the picture
/// enlarged. Both rejected, and the v1.41/v1.42 strips above
/// the band never touched the line either. What he actually
/// asked for all along, in his words: blur THIS line - the
/// band's own top edge. v1.43 does exactly that and nothing
/// else: a crossfade dissolve over the band's top 14% - the
/// sharp band fades in over that stretch while a registered
/// blurred copy (radius 12) fades out over the same stretch,
/// so the edge itself is blurred away and the rest of the
/// artwork is untouched. v1.43 still showed the line, and
/// reading the code again found why every top fade since
/// v1.39 had been a no-op: the mask sat AFTER .padding(.top,
/// 56), so the gradient's locations were fractions of the
/// padded height (277) and the whole top fade landed inside
/// the padding - the image always started at full alpha. (The
/// bottom melt worked only because its stops happened to fall
/// inside the image.) v1.44 moves the mask before the padding
/// so the stops are fractions of the band itself, and shifts
/// the bottom stop 0.85 -> 0.81 to keep the bottom melt the
/// same length it was. v1.44 verdict: the line is gone, but
/// the dissolve reached too far down into the picture (tops
/// of heads washed out); he asked for the blur range moved
/// up a little - v1.45 shrinks the dissolve from the top 14%
/// to the top 8%. Still too much for him: v1.46 goes to 4%,
/// v1.47 to 2%, v1.48 back up a touch to 3%.
private struct HeroArtwork: View {
    let item: EmbyItem
    let client: EmbyClient
    /// The backdrop's dominant colour (CIAreaAverage, computed by
    /// the cell's owner). Everything outside the sharp band renders
    /// as this flat tone - NOT as a scaled/blurred copy of the image
    /// (his correction, v1.39: a blurred fill still reads as the
    /// picture enlarged, which is what the fit-to-width band exists
    /// to avoid).
    let tint: Color?
    let onBlank: (String) -> Void

    @State private var uiImage: UIImage?

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(tint ?? Color(.systemBackground))
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    // The mask MUST come before the padding: after
                    // .padding(.top, 56) the gradient's locations
                    // are fractions of the padded height, and the
                    // top fade landed entirely inside the padding
                    // (the bug that kept the line alive to v1.44).
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.03),
                            .init(color: .black, location: 0.81),
                            .init(color: .clear, location: 1.0),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    // Dropped 56pt from the top (his call, v1.37):
                    // top-pinned, the band ended high above the
                    // bottom-anchored title block with a washed-out
                    // gap between them; now its faded bottom edge
                    // lands just above the logo/title.
                    .padding(.top, 56)
                // The line, blurred (v1.43, range tuned in
                // v1.45-v1.48): a registered copy of the same
                // band, blurred, living only in the top 3% - full
                // strength just below the edge, gone by 3% down.
                // Together with the sharp band's fade-in over the
                // same stretch, the top edge dissolves instead of
                // ending in a line.
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity)
                    .blur(radius: 12)
                    .mask {
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.012),
                            .init(color: .black, location: 0.018),
                            .init(color: .clear, location: 0.03),
                        ], startPoint: .top, endPoint: .bottom)
                    }
                    .padding(.top, 56)
            }
        }
        .task(id: item.Id) {
            guard let url = client.backdropURL(itemID: item.Id, index: 0, maxHeight: 720) else {
                onBlank(item.Id)
                return
            }
            // Only a genuinely blank image drops the item. A failed
            // download (slow server, cold cache) retries once and
            // then simply leaves the placeholder: the item stays in
            // the carousel and a later appearance can still load it.
            for attempt in 0..<2 {
                switch await ImageMemoryCache.shared.heroImageResult(for: url) {
                case .loaded(let image):
                    uiImage = image
                    return
                case .blank:
                    onBlank(item.Id)
                    return
                case .failed:
                    if attempt == 0 {
                        try? await Task.sleep(for: .seconds(2))
                        guard !Task.isCancelled else { return }
                    }
                }
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(ShellState.self) private var shell
    @Environment(NavStore.self) private var nav
    @Environment(\.zoomNS) private var zoomNS

    @State private var resume: [EmbyItem] = []
    @State private var latest: [EmbyItem] = []
    @State private var heroIndex = 0
    /// Last time the user touched the hero carousel (drag or tap).
    /// Auto-advance stays quiet for a while after any interaction:
    /// a tap landing while the paging scroll is animating to the
    /// next page is the known "sometimes the tap does nothing" case.
    @State private var lastHeroInteraction = Date.distantPast
    /// Year/ratings/runtime hydrated per hero item from the
    /// single-item endpoint (list responses omit them on goemby).
    @State private var heroMeta: [String: (year: Int?, community: Double?, critic: Double?, runTimeTicks: Int64?, imdbID: String?, tmdbID: String?)] = [:]
    @State private var ratingsStore = RatingsStore.shared
    @State private var errorText: String?
    /// Hero items dropped at runtime because their artwork came back
    /// missing or blank (session-scoped; a relaunch retries them).
    @State private var heroExcluded: Set<String> = []

    /// The mixed rotation pool (newest + top-rated + random from
    /// EmbyClient.heroPool). Empty until its fetch lands.
    @State private var heroPool: [EmbyItem] = []
    /// Freshness stamp for load(): SwiftUI cancels and restarts the
    /// view's .task across backgrounding, so without this the whole
    /// home page refetched on every return from the background.
    @State private var loadedServerID: String?
    @State private var loadedAt: Date?
    @State private var heroTints: [String: Color] = [:]

    /// Carousel candidates: the mixed pool first (latest list, then
    /// resume, as fallbacks), minus anything with no artwork at all
    /// and anything whose art already proved blank in this session.
    private var heroItems: [EmbyItem] {
        // No ratings-count gate here: the >=3-sources rule from the old
        // mixed carousel starved the anime carousel down to 2 survivors
        // (most anime never reach 3 countable sources), so admission is
        // anime + backdrop only; ratings still display as before.
        Array(heroPool.filter {
            !heroExcluded.contains($0.Id)
                && hasHighQualityAnimeBackdrop($0)
        }.prefix(12))
    }

    /// Anime only, matched on genre/tag text. An earlier cut also demanded
    /// a Japan production location, but servers almost never populate
    /// ProductionLocations, so that requirement filtered out every
    /// candidate and left the hero empty (v1.22, confirmed on device).
    /// HeroArtwork separately rejects missing/blank backdrop art.
    private func hasHighQualityAnimeBackdrop(_ item: EmbyItem) -> Bool {
        guard item.BackdropImageTags?.isEmpty == false else { return false }
        let genres = (item.Genres ?? []).map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
        let tags = (item.Tags ?? []).map { $0.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current) }
        let explicitAnime = (genres + tags).contains { value in
            ["anime", "japanese animation", "japanese anime", "日本动画", "日本動畫", "日漫", "アニメ"].contains(value)
                || value.contains("japanese animation") || value.contains("日本动画") || value.contains("日本動畫")
        }
        let animated = genres.contains { value in
            ["animation", "animated", "动画", "動畫", "アニメーション"].contains(value)
                || value.contains("animation") || value.contains("动画") || value.contains("動畫")
        }
        return explicitAnime || animated
    }

    private var currentHeroTint: Color? {
        guard let item = currentHeroItem else { return nil }
        return heroTints[item.Id]
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
        .task(id: currentHeroItem?.Id) { await loadCurrentHeroTint() }
        .task { await heroAutoAdvance() }
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
                if let tint = currentHeroTint {
                    tint
                } else {
                    Color(.systemBackground)
                }
                AmbientImageView(url: client.backdropURL(itemID: item.Id, index: 0, maxHeight: 720))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .scaleEffect(scale)
                    .opacity(currentHeroTint == nil ? 0.85 : 0.25)
                    .id(item.Id)
                    .transition(.opacity)
                LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.24)],
                               startPoint: .top, endPoint: .bottom)
            } else {
                Color(.systemBackground)
            }
        }
        .animation(.easeInOut(duration: 0.55), value: currentHeroItem?.Id)
        .animation(.easeInOut(duration: 0.55), value: currentHeroTint != nil)
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
                            // Tap via a simultaneous gesture + programmatic
                            // push instead of a NavigationLink: a link's
                            // button drops taps that land while the paging
                            // scroll is still moving (auto-advance or a
                            // settling swipe), which read as "sometimes
                            // the tap does nothing, sometimes it works".
                            // The simultaneous tap rides with the cell and
                            // fires either way; real drags still scroll.
                            heroCell(item, client: client)
                                .containerRelativeFrame(.horizontal)
                                .id(index)
                                .contentShape(Rectangle())
                                .simultaneousGesture(TapGesture().onEnded {
                                    lastHeroInteraction = .now
                                    nav.path0.append(Route.detail(item))
                                })
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: Binding<Int?>(
                    get: { heroIndex },
                    set: { if let newValue = $0 { heroIndex = newValue } }
                ))
                .onScrollPhaseChange { _, phase in
                    if phase == .tracking || phase == .interacting || phase == .decelerating {
                        lastHeroInteraction = .now
                    }
                }
                .frame(height: 500)

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

            // No floating controls over the hero (his call, v1.36):
            // the server chip and the heart shortcut are gone; server
            // switching lives in the settings server card, favorites
            // in the records tab.
        }
        .frame(height: 500)
    }

    private func heroCell(_ item: EmbyItem, client: EmbyClient) -> some View {
        VStack(alignment: .leading, spacing: 10) {
                if item.ImageTags?["Logo"] != nil {
                    SharedImage(url: client.imageURL(itemID: item.Id, kind: "Logo"), fill: false)
                        .frame(maxWidth: 280, maxHeight: 84, alignment: .leading)
                } else {
                    Text(item.Name)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                }
                heroMetaLine(item)
                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                heroRatingsRow(item)
            }
        .padding(.horizontal, 30)
        .padding(.bottom, 34)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                HeroArtwork(item: item, client: client, tint: heroTints[item.Id]) { id in
                    heroExcluded.insert(id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                let meltTint = heroTints[item.Id] ?? Color(.systemBackground)
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.30),
                    .init(color: meltTint.opacity(0.48), location: 0.60),
                    .init(color: meltTint.opacity(0.78), location: 0.86),
                    .init(color: meltTint, location: 1.0),
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
        .frame(height: 500)
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
        .foregroundStyle(.white.opacity(0.82))
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
        let external = ratingsStore.byItemID[item.Id]
        if external != nil || community != nil || critic != nil {
            RatingsStrip(external: external, fallbackCommunity: community, fallbackCritic: critic, large: true)
                .padding(.top, 2)
        }
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
            try? await Task.sleep(for: .seconds(7))
            guard !heroItems.isEmpty else { continue }
            // Stay quiet while the user is (or just was) interacting:
            // advancing under the user's finger both startles and eats
            // the tap they were aiming at the current page.
            guard Date().timeIntervalSince(lastHeroInteraction) > 6 else { continue }
            withAnimation { heroIndex = (heroIndex + 1) % heroItems.count }
        }
    }

    private func loadCurrentHeroTint() async {
        guard let item = currentHeroItem, let client = store.client(),
              // v1.40: the tint needs only the artwork's average
              // colour, so fetch a 48px-tall strip instead of the
              // full 720px backdrop - the old wait (his "卡一下才
              // 渲染完成") was the big image downloading first.
              // The result is also persisted per item (see
              // dominantTint(for:itemID:)), so repeat entries
              // paint from disk on the first frame.
              let url = client.backdropURL(itemID: item.Id, index: 0, maxHeight: 48) else { return }
        guard let tint = await ImageMemoryCache.shared.dominantTint(for: url, itemID: item.Id),
              !Task.isCancelled, currentHeroItem?.Id == item.Id else { return }
        heroTints[item.Id] = tint
    }

    private func load() async {
        guard let client = store.client() else { return }
        // Same freshness pattern as the library catalog: same server,
        // loaded less than 10 minutes ago, data already on screen -
        // keep it instead of refetching everything (this is what made
        // returning from the background feel like a cold start).
        if loadedServerID == store.activeServer?.id, let loadedAt,
           Date().timeIntervalSince(loadedAt) < 600, !heroPool.isEmpty {
            return
        }
        errorText = nil
        do {
            async let resumeFetch = client.resumeItems()
            async let latestFetch = client.latestItems()
            async let poolFetch = client.heroPool()
            resume = try await resumeFetch
            latest = await latestFetch
            heroPool = await poolFetch
            // Prefill every hero tint we have persisted, so the
            // page opens already coloured instead of flashing
            // the flat background first (v1.40).
            for heroItem in heroItems {
                if let tint = ImageMemoryCache.shared.dominantTintPersisted(itemID: heroItem.Id) {
                    heroTints[heroItem.Id] = tint
                }
            }
            // Start (and refresh) on a random hero so the home page
            // does not open on the same title every time.
            if heroItems.count > 1 { heroIndex = Int.random(in: 0..<heroItems.count) }
            // Warm every hero backdrop in the background, in order:
            // paging sideways should meet decoded images, not a slow
            // server (his "加载还慢了很多"). The shared cache dedupes
            // these against the cells' own requests.
            let warmItems = heroItems
            Task.detached(priority: .utility) {
                for heroItem in warmItems {
                    if let url = client.backdropURL(itemID: heroItem.Id, index: 0, maxHeight: 720) {
                        _ = await ImageMemoryCache.shared.image(for: url)
                    }
                }
            }
            await loadHeroMeta(client: client)
            loadedServerID = store.activeServer?.id
            loadedAt = Date()
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
