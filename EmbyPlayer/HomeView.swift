import SwiftUI

/// Image view bound to the active client, backed by the shared
/// decoded-image cache: one download and decode per URL across the
/// whole app, instant paint on revisit (AsyncImage re-fetched and
/// re-decoded per instance, which taxed every rail and grid).
struct ItemImage: View {
    let item: EmbyItem
    let client: EmbyClient
    var kind: String = "Primary"
    /// Player backdrops pass true: the poster must sit in the same
    /// aspect-fit framing the video itself will use, or the picture
    /// visibly jumps when the fill-cropped poster gives way to the
    /// first frame.
    var fit: Bool = false

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
                Image(uiImage: uiImage).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
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

/// Hero artwork history, compressed: through v1.65 the hero was
/// the BACKDROP fit to width over a flat dominant-colour tint -
/// his fallback call after fill-crops of the 16:9 backdrop kept
/// losing the subject (centre crop and a Vision focal point both
/// produced subject-less framings, 2026-11-25). The tint field
/// and the fit band's top edge then took nine builds of fade
/// tuning (v1.39-v1.48) and he still rated the result poor.
/// v1.68 follows his SenPlayer screenshots instead: Sen's hero
/// is the POSTER, not the backdrop - a portrait poster fills the
/// frame with only its bottom cropped (which the melt hides),
/// so the subject is always in frame. See HeroArtwork.
private struct HeroArtwork: View {
    let item: EmbyItem
    let client: EmbyClient
    /// Placeholder colour shown until the artwork lands (the pool's
    /// dominant-colour tint). Nothing else renders in this colour:
    /// v1.68 rebuilt the hero after SenPlayer's home (his three
    /// reference screenshots, 2026-11-28): the POSTER itself fills
    /// the whole hero frame - aspectFill, top-anchored so the
    /// subject (faces live in the upper half) is never cropped -
    /// and the cell's melt gradient dissolves its bottom into the
    /// page background. No fit-to-width band, no flat tint field,
    /// no top fade line. The vertical crop offset is computed from
    /// the loaded image's real aspect: scaledToFill centres its
    /// overflow, so shifting down by half the overflow re-anchors
    /// the crop to the top; landscape art has no vertical overflow
    /// and stays centred.
    let tint: Color?
    let onBlank: (String) -> Void

    @State private var uiImage: UIImage?

    /// Half the vertical overflow of the aspectFill draw, used to
    /// top-anchor the crop. The hero always spans the full screen
    /// width and is 500pt tall (heroCell's frame).
    private var topCropOffset: CGFloat {
        guard let uiImage, uiImage.size.height > 0 else { return 0 }
        let cellWidth = UIScreen.main.bounds.width
        let cellHeight: CGFloat = 500
        let aspect = uiImage.size.width / uiImage.size.height
        let drawnHeight = max(cellHeight, cellWidth / aspect)
        return max(0, (drawnHeight - cellHeight) / 2)
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle().fill(tint ?? Color(.systemBackground))
            if let uiImage {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .offset(y: topCropOffset)
                    .clipped()
            }
        }
        .task(id: item.Id) {
            let url = (item.ImageTags?["Primary"] != nil
                ? client.imageURL(itemID: item.Id, kind: "Primary", maxHeight: 1000)
                : nil) ?? client.backdropURL(itemID: item.Id, index: 0, maxHeight: 720)
            guard let url else {
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

/// The hero pool used to be re-sampled on every cold load, and
/// its random slice made every launch a different batch - so the
/// carousel's 720p backdrops were never in the disk cache and had
/// to come from the server every time, while the library posters
/// (same items every day) painted instantly (his 2026-11-27
/// report: 只有轮播图慢）. v1.64 persisted the batch's IDs for a
/// day, but the carousel still waited on the Ids round-trip
/// before its first frame (his launch recording the same night:
/// a grey hero for a beat). The store now persists the items
/// themselves (the fields the hero reads), so a launch restores
/// the whole batch locally - no network before the first paint -
/// and a new day's fresh batch is sampled in the background and
/// swapped in when it lands.
private enum HeroPoolStore {
    struct Saved: Codable { let day: String; let items: [HeroPoolItem] }

    static var today: String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func load(serverID: String) -> Saved? {
        guard let data = UserDefaults.standard.data(forKey: "heroPool.\(serverID)"),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        return saved
    }

    static func save(serverID: String, items: [EmbyItem]) {
        let saved = Saved(day: today, items: items.map(HeroPoolItem.init))
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "heroPool.\(serverID)")
        }
    }
}

/// The subset of EmbyItem the hero path reads (admission filter,
/// cell text, ratings), in a flat Codable shape - the full model
/// graph (media sources, people, chapters) is Decodable-only and
/// the hero never touches it.
private struct HeroPoolItem: Codable {
    let Id: String
    let Name: String
    let type: String
    let Overview: String?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let Genres: [String]?
    let Tags: [String]?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    let CommunityRating: Double?
    let CriticRating: Double?
    let ProviderIds: [String: String]?
    let SeriesName: String?
    let SeriesId: String?

    init(_ item: EmbyItem) {
        Id = item.Id; Name = item.Name; type = item.type
        Overview = item.Overview; ProductionYear = item.ProductionYear
        RunTimeTicks = item.RunTimeTicks; Genres = item.Genres; Tags = item.Tags
        ImageTags = item.ImageTags; BackdropImageTags = item.BackdropImageTags
        CommunityRating = item.CommunityRating; CriticRating = item.CriticRating
        ProviderIds = item.ProviderIds; SeriesName = item.SeriesName; SeriesId = item.SeriesId
    }

    var item: EmbyItem {
        EmbyItem(Id: Id, Name: Name, type: type, CollectionType: nil,
                 SeriesName: SeriesName, SeriesId: SeriesId, SeasonId: nil,
                 IndexNumber: nil, ParentIndexNumber: nil,
                 Overview: Overview, ProductionYear: ProductionYear,
                 RunTimeTicks: RunTimeTicks, ChildCount: nil,
                 Genres: Genres, Tags: Tags, ProductionLocations: nil,
                 OriginalTitle: nil, CommunityRating: CommunityRating,
                 CriticRating: CriticRating, PremiereDate: nil,
                 People: nil, Chapters: nil, ImageTags: ImageTags,
                 BackdropImageTags: BackdropImageTags, UserData: nil,
                 MediaSources: nil, ProviderIds: ProviderIds)
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
    /// Live x-offset of the hero pager (v1.71): the page ambient
    /// blends between neighbouring heroes by this offset, so the
    /// tone under the carousel tracks the swipe itself instead of
    /// crossfading after the page settles.
    @State private var heroScrollX: CGFloat = 0
    @State private var heroIsScrolling = false
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

    /// The wash the hero melts into and the page below sits on:
    /// the poster's dominant colour lightened toward the page
    /// background (v1.70, his correction — SenPlayer's posters and
    /// the area under them are ONE tone; v1.68 melted into plain
    /// system background, which read as white/grey patches pasted
    /// under the art). One helper so the cell melt and the page
    /// ambient can never drift apart again.
    private func heroMeltColor(_ tint: Color?) -> Color {
        // Strength pass (v1.72, his second "力度不够"): the area
        // average of a poster greys out, so boost its saturation
        // back, and barely lighten it (mix 0.55 -> 0.35 -> 0.15
        // across v1.70-72) — the wash must read as the poster's
        // own colour, not as tinted white.
        guard let tint else { return Color(.systemBackground) }
        let ui = UIColor(tint)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let boosted = ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
            ? Color(hue: Double(h), saturation: Double(min(s * 1.4, 1)), brightness: Double(b), opacity: Double(a))
            : tint
        return boosted.mix(with: Color(.systemBackground), by: 0.15)
    }

    /// The ambient colour right now: the melt colour of whichever
    /// hero the pager is over, blended toward the next hero by
    /// the fractional scroll progress. At rest it is exactly the
    /// settled page's melt colour (so the cell seam stays
    /// invisible); mid-swipe the page below already carries the
    /// incoming poster's tone.
    private var ambientMeltColor: Color {
        guard !heroItems.isEmpty else { return Color(.systemBackground) }
        let pageWidth = UIScreen.main.bounds.width
        guard pageWidth > 0 else { return heroMeltColor(currentHeroTint) }
        var raw = heroScrollX / pageWidth
        // If the offset feed ever disagrees with the settled page
        // while the pager is idle (v1.71 on his phone read as the
        // page tone not following the poster at all), the settled
        // index wins — a correct colour beats a stuck blend.
        if !heroIsScrolling, abs(raw - CGFloat(heroIndex)) > 0.5 {
            raw = CGFloat(heroIndex)
        }
        let progress = min(max(raw, 0), CGFloat(heroItems.count - 1))
        let lower = Int(progress.rounded(.down))
        let frac = progress - CGFloat(lower)
        let base = heroMeltColor(heroTints[heroItems[lower].Id])
        guard frac > 0.001, lower + 1 < heroItems.count else { return base }
        return base.mix(with: heroMeltColor(heroTints[heroItems[lower + 1].Id]), by: Double(frac))
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

    /// The page's ambient wash: the SAME lightened poster tone
    /// the hero cell melts into (heroMeltColor), flat — SenPlayer's
    /// home is one continuous tone from the poster's bottom edge
    /// to the last section. Through v1.69 this layer was the flat
    /// tint plus the backdrop ghosted at 0.25 under a black wash,
    /// which read as muddy grey and never matched the cell's melt;
    /// v1.70 makes both ends the identical colour. Two copies of
    /// one layer: one attached to the scroll content and one fixed
    /// behind the ScrollView for rubber-band regions. Both
    /// crossfade when the carousel moves.
    private var currentHeroItem: EmbyItem? {
        heroItems.isEmpty ? nil : heroItems[min(heroIndex, heroItems.count - 1)]
    }

    @ViewBuilder
    private func ambientLayer(scale: CGFloat) -> some View {
        // Driven by the pager's scroll offset (ambientMeltColor),
        // NOT by an on-settle crossfade: the old 0.55s animation
        // keyed to the settled index left the page below a beat
        // behind every swipe and then jumped (v1.71, his video).
        ambientMeltColor
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
                        heroIsScrolling = true
                    } else {
                        heroIsScrolling = false
                    }
                }
                .onScrollGeometryChange(for: CGFloat.self) { geometry in
                    geometry.contentOffset.x
                } action: { _, newX in
                    if abs(newX - heroScrollX) > 0.5 { heroScrollX = newX }
                }
                .frame(height: 500)

                HStack(spacing: 6) {
                    ForEach(heroItems.indices, id: \.self) { index in
                        Circle()
                            .fill(Color.white.opacity(index == heroIndex ? 0.95 : 0.4))
                            .frame(width: 7, height: 7)
                            .shadow(color: .black.opacity(0.22), radius: 2, y: 1)
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
        // SenPlayer layout (his 2026-11-28 reference screenshots):
        // everything centred, sitting on the artwork's melt into
        // the page background, in label colours - logo or title,
        // year · genres, two lines of overview, the ratings strip;
        // the page dots hang below the strip.
        VStack(alignment: .center, spacing: 10) {
                if item.ImageTags?["Logo"] != nil {
                    SharedImage(url: client.imageURL(itemID: item.Id, kind: "Logo"), fill: false)
                        .frame(maxWidth: 280, maxHeight: 84, alignment: .center)
                } else {
                    Text(item.Name)
                        .font(.system(size: 27, weight: .bold))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
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
        .padding(.horizontal, 30)
        .padding(.bottom, 48)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                HeroArtwork(item: item, client: client, tint: heroTints[item.Id]) { id in
                    heroExcluded.insert(id)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                let melt = heroMeltColor(heroTints[item.Id])
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .clear, location: 0.34),
                    .init(color: melt.opacity(0.5), location: 0.58),
                    .init(color: melt.opacity(0.85), location: 0.78),
                    .init(color: melt, location: 0.92),
                ], startPoint: .top, endPoint: .bottom)
            }
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.94),
                    .init(color: .clear, location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(height: 500)
        .clipped()
    }

    /// The hero meta line (SenPlayer layout): year · genres,
    /// centred, secondary colour. Ratings live on their own row
    /// (heroRatingsRow).
    private func heroMetaLine(_ item: EmbyItem) -> some View {
        let productionYear = item.ProductionYear ?? heroMeta[item.Id]?.year ?? nil
        return HStack(spacing: 7) {
            if let year = productionYear {
                Text(String(year))
                if let genres = item.Genres, !genres.isEmpty {
                    Text("·")
                }
            }
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
              // v1.70: the tint comes from the POSTER (the art
              // the hero actually shows), so the melt below it
              // carries the poster's own tone.
              let url = (item.ImageTags?["Primary"] != nil
                  ? client.imageURL(itemID: item.Id, kind: "Primary", maxHeight: 48)
                  : nil) ?? client.backdropURL(itemID: item.Id, index: 0, maxHeight: 48) else { return }
        guard let tint = await ImageMemoryCache.shared.dominantTint(for: url, itemID: item.Id),
              !Task.isCancelled, currentHeroItem?.Id == item.Id else { return }
        heroTints[item.Id] = tint
    }

    private func load() async {
        guard let client = store.client() else { return }
        // Instant paint: restore the persisted pool (whatever day it
        // is from) before any network work, so the carousel renders
        // with the first frames and its backdrops come straight from
        // the disk cache. A stale-day batch is refreshed in the
        // background at the end of this load.
        let serverKey = store.activeServer?.id ?? ""
        var poolIsStale = false
        if heroPool.isEmpty, let saved = HeroPoolStore.load(serverID: serverKey), !saved.items.isEmpty {
            heroPool = saved.items.map { $0.item }
            poolIsStale = saved.day != HeroPoolStore.today
            for heroItem in heroItems {
                if let tint = ImageMemoryCache.shared.dominantTintPersisted(itemID: heroItem.Id) {
                    heroTints[heroItem.Id] = tint
                }
            }
            if heroItems.count > 1 { heroIndex = Int.random(in: 0..<heroItems.count) }
        }
        let needsPool = heroPool.isEmpty
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
            async let poolFetch = fetchPoolIfNeeded(client: client, needed: needsPool)
            resume = try await resumeFetch
            latest = await latestFetch
            if let fetched = await poolFetch { heroPool = fetched }
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
            // Prefetch EVERY hero's poster tint (v1.72): tints used
            // to be computed only for the page being viewed, so a
            // first swipe toward an unviewed hero blended the page
            // toward plain background — part of why the tone below
            // "didn't follow the poster". The strips are 48px and
            // persist, so this is a one-time pass per pool.
            let tintMissing = heroItems.filter { heroTints[$0.Id] == nil }
            if !tintMissing.isEmpty {
                Task {
                    for heroItem in tintMissing {
                        let strip = (heroItem.ImageTags?["Primary"] != nil
                            ? client.imageURL(itemID: heroItem.Id, kind: "Primary", maxHeight: 48)
                            : nil) ?? client.backdropURL(itemID: heroItem.Id, index: 0, maxHeight: 48)
                        if let strip,
                           let tint = await ImageMemoryCache.shared.dominantTint(for: strip, itemID: heroItem.Id) {
                            heroTints[heroItem.Id] = tint
                        }
                    }
                }
            }
            // Warm every hero backdrop in the background, in order:
            // paging sideways should meet decoded images, not a slow
            // server (his "加载还慢了很多"). The shared cache dedupes
            // these against the cells' own requests.
            let warmItems = heroItems
            Task.detached(priority: .utility) {
                for heroItem in warmItems {
                    let url = (heroItem.ImageTags?["Primary"] != nil
                        ? client.imageURL(itemID: heroItem.Id, kind: "Primary", maxHeight: 1000)
                        : nil) ?? client.backdropURL(itemID: heroItem.Id, index: 0, maxHeight: 720)
                    if let url {
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
        // The on-screen batch is from a previous day: sample today's
        // batch in the background and swap it in when it lands, so
        // the launch itself never waits on the pool queries.
        if poolIsStale {
            Task {
                let fresh = await client.heroPool()
                guard !fresh.isEmpty, store.activeServer?.id == serverKey else { return }
                HeroPoolStore.save(serverID: serverKey, items: fresh)
                heroPool = fresh
                if heroIndex >= heroItems.count { heroIndex = 0 }
            }
        }
    }

    /// First-ever launch (or an empty restore): sample a fresh
    /// batch and persist it for instant restores from then on.
    private func fetchPoolIfNeeded(client: EmbyClient, needed: Bool) async -> [EmbyItem]? {
        guard needed else { return nil }
        let fresh = await client.heroPool()
        if !fresh.isEmpty {
            HeroPoolStore.save(serverID: store.activeServer?.id ?? "", items: fresh)
        }
        return fresh
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
