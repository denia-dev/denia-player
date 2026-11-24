import SwiftUI

struct PlayRequest: Identifiable {
    let item: EmbyItem
    let startSeconds: Double
    var id: String { item.Id }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(ShellState.self) private var shell
    @Environment(\.zoomNS) private var zoomNS
    let item: EmbyItem
    let onBack: () -> Int
    @State private var detail: EmbyItem?
    @State private var seasons: [EmbyItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [EmbyItem] = []
    @State private var similar: [EmbyItem] = []
    @State private var episodeRange = 0
    @State private var playRequest: PlayRequest?
    @State private var errorText: String?
    @State private var favOverride: Bool?
    @State private var playedOverride: Bool?
    @State private var overviewExpanded = false
    @State private var showAllEpisodes = false
    /// Nil until load()'s series fetch lands - artworkSource reads the
    /// difference (see its comment).
    @State private var seriesBackdropTags: [String]? = nil
    @State private var ratingsStore = RatingsStore.shared
    /// The artwork's dominant colour, deepened - the whole page is
    /// rendered in it (his 2026-11-24 reference screenshot). Nil
    /// until the artwork lands; the blurred ambient stands in.
    @State private var tint: Color? = nil

    /// What the hero melts into: the page tint once known, the
    /// system background before that.
    private var meltColor: Color { tint ?? Color(.systemBackground) }

    private var current: EmbyItem { detail ?? item }
    private var isSeries: Bool { current.type == "Series" }
    private var seriesID: String? {
        if isSeries { return current.Id }
        if current.type == "Episode" { return current.SeriesId }
        return nil
    }
    private var isFavorite: Bool { favOverride ?? (current.UserData?.IsFavorite ?? false) }
    private var isPlayed: Bool { playedOverride ?? (current.UserData?.Played ?? false) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                VStack(alignment: .leading, spacing: 18) {
                    if let errorText {
                        Text(errorText).foregroundStyle(.red).font(.footnote)
                    }
                    actionsRow
                    if let overview = current.Overview, !overview.isEmpty {
                        Text(overview)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(overviewExpanded ? nil : 3)
                            .onTapGesture { overviewExpanded.toggle() }
                    }
                    ratingsRow
                    if seriesID != nil { seriesSection }
                    castSection
                    mediaInfoSection
                    artworkSection
                    similarSection
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .containerRelativeFrame(.horizontal)
        }
        .ignoresSafeArea(edges: .top)
        .background {
            // An opaque base from the very first frame: without it
            // the page is translucent until the ambient art lands,
            // and the page behind bleeds through the whole push/zoom
            // transition (the ghosted double-exposure in his
            // 2026-11-24 screen recording).
            ZStack {
                Color(.systemBackground)
                ambientBackground
            }
            .ignoresSafeArea()
        }
        .environment(\.colorScheme, .dark)
        .zoomDestination(id: item.Id, ns: zoomNS)
        .toolbar(.hidden, for: .tabBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    shell.searchRequested = true
                    _ = onBack()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                Menu {
                    Button { togglePlayed() } label: {
                        Label(isPlayed ? "取消已看" : "标记已看", systemImage: "checkmark.circle")
                    }
                    Button { toggleFavorite() } label: {
                        Label(isFavorite ? "取消收藏" : "收藏", systemImage: "heart")
                    }
                    if let target = playTarget {
                        Button {
                            playRequest = PlayRequest(item: target, startSeconds: 0)
                        } label: {
                            Label("从头播", systemImage: "arrow.counterclockwise")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
            }
        }
        .task { await load() }
        .task { await loadTint() }
        .onChange(of: selectedSeasonID) { _, seasonID in
            episodeRange = 0
            Task { if let seasonID { await loadEpisodes(seasonID) } }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(item: request.item, startSeconds: request.startSeconds) { next in
                playRequest = PlayRequest(item: next, startSeconds: 0)
            }
        }
        .sheet(isPresented: $showAllEpisodes) { allEpisodesSheet }
    }

    /// The page background: the artwork's dominant colour as one
    /// flat field (his 2026-11-24 reference: the whole page rendered
    /// in the art's 主色调， white text over it, the sharp hero
    /// melting into the colour). Until the tint is extracted - or
    /// for items without artwork - a heavy-blur wash of the art
    /// stands in, so the page is never a bare slab while loading.
    private var ambientBackground: some View {
        ZStack {
            if let tint {
                tint
                LinearGradient(
                    colors: [Color.white.opacity(0.05), Color.black.opacity(0.16)],
                    startPoint: .top, endPoint: .bottom)
            } else if let client = store.client() {
                AmbientVariantImage(url: washURL(client: client), heavy: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                AmbientVariantImage(url: client.backdropURL(itemID: artworkItemID, index: 0, maxHeight: 1080), heavy: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(
                    colors: [Color(.systemBackground).opacity(0.10),
                             Color(.systemBackground).opacity(0.50)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: tint != nil)
        .ignoresSafeArea()
    }

    private func loadTint() async {
        guard let client = store.client(),
              let url = client.backdropURL(itemID: artworkItemID, index: 0, maxHeight: 1080) else { return }
        if let cached = ImageMemoryCache.shared.dominantTintCached(url) {
            tint = cached
            return
        }
        tint = await ImageMemoryCache.shared.dominantTint(for: url)
    }

    /// The wash's image URL with ItemImage's episode rule: an
    /// episode without its own Primary image borrows the series one.
    private func washURL(client: EmbyClient) -> URL? {
        let kind = wideImageKind(item)
        let sourceID = (kind == "Primary" && item.type == "Episode" && item.ImageTags?["Primary"] == nil)
            ? (item.SeriesId ?? item.Id) : item.Id
        return client.imageURL(itemID: sourceID, kind: kind)
    }

    /// Fixed SenPlayer-style top chrome: a glass back circle on the left,
    /// a glass capsule with search + more on the right. It lives outside
    /// the ScrollView so it can never scroll away.

    // MARK: - hero

    /// Episodes carry no logo of their own: borrow the series logo and
    /// show the series name when even that is missing (SenPlayer does
    /// the same - the hero brands the show, the meta describes the
    /// episode).
    private var heroLogoItemID: String {
        current.type == "Episode" ? (current.SeriesId ?? current.Id) : current.Id
    }

    private var heroTitleText: some View {
        Text(current.type == "Episode" ? (current.SeriesName ?? current.Name) : current.Name)
            .font(.system(size: 24, weight: .bold))
            .multilineTextAlignment(.center)
            .lineLimit(2)
    }

    @ViewBuilder
    private var heroLogo: some View {
        if let client = store.client(),
           current.type == "Episode" || current.ImageTags?["Logo"] != nil {
            AsyncImage(url: client.imageURL(itemID: heroLogoItemID, kind: "Logo")) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                case .failure:
                    heroTitleText
                default:
                    Color.clear.frame(height: 44)
                }
            }
            .frame(maxWidth: 290, maxHeight: 88)
        } else {
            heroTitleText
        }
    }

    /// The item's artwork （艺术图 = its backdrop set), resolved once for
    /// both the hero and the artwork section. On an EPISODE page SenPlayer
    /// brands the page with the SERIES artwork, so the series set wins
    /// whenever it exists (fetched in load()); the episode's own set -
    /// often just a video still on goemby - is only the fallback. Movies
    /// and series use their own set. Nil when no artwork exists at all.
    private var artworkSource: (id: String, tags: [String])? {
        if current.type == "Episode", let seriesID = current.SeriesId {
            // Until the series fetch lands, report NO artwork: the hero
            // then stays on its placeholder (this episode's own still)
            // instead of flashing the episode's own backdrop set for a
            // beat and swapping images when the series set arrives -
            // one of the two swaps in his build-88 screen recording.
            guard let seriesTags = seriesBackdropTags else { return nil }
            if !seriesTags.isEmpty { return (seriesID, seriesTags) }
        }
        if let tags = current.BackdropImageTags, !tags.isEmpty {
            return (current.Id, tags)
        }
        return nil
    }

    /// What the hero shows until the artwork lands: the item's own wide
    /// image, requested with the SAME kind the list cells use
    /// (wideImageKind), so the URL matches the tapped cell's exactly
    /// and the image is already cached - it paints instantly. Build 89
    /// forced "Primary" for episodes while the cells load "Backdrop":
    /// a different URL, a cold fetch, and the transparent window (with
    /// the previous page showing through) stayed. Without any underlay
    /// the hero starts transparent and the PREVIOUS page's backdrop
    /// flashes through during the push (his build-88 screen recording).
    @ViewBuilder
    private func heroPlaceholder(client: EmbyClient) -> some View {
        // Frozen on the ENTRY item (never `current`): when load()'s
        // detail lands, `current` changes identity and a placeholder
        // bound to it re-requests its image - the detail DTO's tags
        // can even flip wideImageKind - swapping the hero's underlay
        // mid-entry. The entry item is what the tapped cell showed,
        // so this layer must never change after the push.
        ItemImage(item: item, client: client, kind: wideImageKind(item))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
    }

    /// Hero art is rendered from the artwork set (its first backdrop),
    /// ENLARGED to fill the tall hero frame (scaledToFill, center
    /// crop) - SenPlayer's presentation, which he asked for explicitly
    /// on build 87's screenshot. Build 84's fit-width rendering was the
    /// overcorrection: his build-83 complaint was never the zoom itself
    /// but the SOURCE (an episode still instead of the series artwork);
    /// with the source fixed, the small banner-like hero read as wrong
    /// next to Sen's big filled one. The hero's gradient + mask melt
    /// fades the enlarged art into the ambient below.
    /// The item whose backdrop brands this page: the series for an
    /// episode, the item itself otherwise. Derived from the ENTRY
    /// item, so it is known in the very first frame - the hero and the
    /// ambient request the artwork immediately instead of waiting for
    /// load()'s two round trips (detail, then series) to resolve
    /// artworkSource. Builds 88-90 gated the artwork on that late
    /// state, so the page always swapped images mid-entry; 90's fade
    /// only made the swap slower, as he put it.
    private var artworkItemID: String {
        if item.type == "Episode", let seriesID = item.SeriesId {
            return seriesID
        }
        return item.Id
    }

    @ViewBuilder
    private var heroBackdrop: some View {
        if let client = store.client() {
            ZStack {
                heroPlaceholder(client: client)
                // Ungated on purpose: when the item has no backdrop
                // this request 404s, SharedImage stays empty, and the
                // placeholder below simply remains the hero.
                SharedImage(url: client.backdropURL(itemID: artworkItemID, index: 0, maxHeight: 1080), fadeIn: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        } else {
            EmptyView()
        }
    }

    private var hero: some View {
        VStack(spacing: 10) {
                heroLogo
                if !metaParts.isEmpty {
                    Text(metaParts.joined(separator: "  "))
                        .font(.subheadline.weight(.medium))
                        .multilineTextAlignment(.center)
                }
                if let genres = current.Genres, !genres.isEmpty {
                    Text(genres.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                playCapsule
                    .padding(.horizontal, 13)
            }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                heroBackdrop
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.25), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: meltColor.opacity(0.45), location: 0.58),
                    .init(color: meltColor.opacity(0.55), location: 0.85),
                    .init(color: meltColor.opacity(0.55), location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
            // Melt, don't cut: the background's alpha fades to zero over
            // the bottom stretch, so at the hero's lower edge the visible
            // pixels ARE the page's ambient layer itself. Matching veil
            // strengths (build 54) still left a line because the art
            // under the veil differs (sharp crop vs blurred average);
            // a crossfade to the very layer behind removes the edge
            // by construction.
            .mask {
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: 0.62),
                    .init(color: .clear, location: 0.98),
                    .init(color: .clear, location: 1.0),
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(height: 478)
        .clipped()
    }

    private var metaParts: [String] {
        var parts: [String] = []
        if current.durationSeconds > 0 {
            let total = Int(current.durationSeconds) / 60
            parts.append(total >= 60 ? "\(total / 60)小时\(total % 60)分钟" : "\(total)分钟")
        }
        if let date = current.PremiereDate, date.count >= 10 {
            let bits = date.prefix(10).split(separator: "-")
            if bits.count == 3, let y = Int(bits[0]), let m = Int(bits[1]), let d = Int(bits[2]) {
                parts.append("\(y)年\(m)月\(d)日")
            }
        } else if let year = current.ProductionYear {
            parts.append(String(year))
        }
        if let source = current.MediaSources?.first,
           let video = source.MediaStreams?.first(where: { $0.type == "Video" }) {
            if let w = video.Width {
                parts.append(w >= 3800 ? "4K" : (w >= 1900 ? "1080P" : (w >= 1200 ? "720P" : "SD")))
            }
            let title = (video.DisplayTitle ?? "").uppercased()
            if title.contains("DOLBY") || title.contains(" DV") { parts.append("Dolby Vision") }
            else if title.contains("HDR") { parts.append("HDR") }
            else { parts.append("SDR") }
            if let fps = video.AverageFrameRate ?? video.RealFrameRate, fps > 0 {
                parts.append("\(Int(fps.rounded()))FPS")
            }
            if let size = source.Size {
                parts.append(String(format: "%.2fG", Double(size) / 1_073_741_824))
            }
        }
        return parts
    }

    /// Centered multi-source ratings strip (MDBList external scores
    /// over the server's own two). Nothing is labelled with a brand
    /// the data did not come from.
    @ViewBuilder
    private var ratingsRow: some View {
        let external = ratingsStore.byItemID[item.Id]
        if external != nil || current.CommunityRating != nil || current.CriticRating != nil {
            HStack(spacing: 18) {
                Spacer()
                RatingsStrip(external: external,
                             fallbackCommunity: current.CommunityRating,
                             fallbackCritic: current.CriticRating)
                Spacer()
            }
        }
    }

    private var playTarget: EmbyItem? {
        if current.isPlayable { return current }
        if isSeries {
            return episodes.first(where: { $0.resumeSeconds > 0 }) ?? episodes.first
        }
        return nil
    }

    private var playCapsule: some View {
        Group {
            if let target = playTarget {
                Button {
                    playRequest = PlayRequest(item: target, startSeconds: target.resumeSeconds)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        Text("播放")
                        Text(formatHMS(target.resumeSeconds > 5 ? target.resumeSeconds : target.durationSeconds))
                    }
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.white, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - actions / cast

    // SenPlayer's action row: a tight centered cluster of small muted
    // glyphs directly under the play capsule — no edge-to-edge spacers,
    // no filled discs (build 72, from his Sen screenshot).
    private var actionsRow: some View {
        HStack(spacing: 20) {
            if let target = playTarget {
                actionButton(icon: "arrow.counterclockwise", active: false) {
                    playRequest = PlayRequest(item: target, startSeconds: 0)
                }
            }
            actionButton(icon: isPlayed ? "checkmark.circle.fill" : "checkmark.circle", active: isPlayed) {
                togglePlayed()
            }
            actionButton(icon: isFavorite ? "heart.fill" : "heart", active: isFavorite) {
                toggleFavorite()
            }
            if item.isPlayable {
                DownloadButton(item: item, plain: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, -8)
    }

    private func actionButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(active ? Color.purple : Color(red: 0.52, green: 0.50, blue: 0.62))
                .frame(width: 34, height: 34)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var castSection: some View {
        // No Type filtering: goemby's People carry no "Actor" type at all
        // (build-81 diagnostic: 27 people, zero "Actor" strings in the raw
        // payload), so the old type == "Actor" filter emptied the section.
        // The section is 演职人员 (cast AND crew) anyway - show everyone,
        // the role line under each name says who did what.
        if let people = current.People, !people.isEmpty, let client = store.client() {
            VStack(alignment: .leading, spacing: 10) {
                Text("演职人员").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(people.prefix(15)) { person in
                            NavigationLink(value: Route.person(id: person.Id, name: person.Name)) {
                            VStack(alignment: .leading, spacing: 4) {
                                AsyncImage(url: client.imageURL(itemID: person.Id, kind: "Primary", maxHeight: 220)) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFill()
                                    } else {
                                        Rectangle().fill(.quaternary)
                                            .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                                    }
                                }
                                .frame(width: 92, height: 115)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text(person.Name).font(.subheadline.weight(.medium)).lineLimit(2)
                                if let role = person.Role {
                                    Text(role).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            .frame(width: 92)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - similar

    @ViewBuilder
    private var similarSection: some View {
        if !similar.isEmpty, let client = store.client() {
            VStack(alignment: .leading, spacing: 10) {
                Text("相似推荐").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(similar) { other in
                            NavigationLink(value: Route.detail(other)) {
                                PosterCell(item: other, client: client, width: 104)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - series

    private var episodeRanges: [Range<Int>] {
        guard episodes.count > 5 else { return [0..<episodes.count] }
        var ranges: [Range<Int>] = []
        var start = 0
        while start < episodes.count {
            ranges.append(start..<min(start + 5, episodes.count))
            start += 5
        }
        return ranges
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Menu {
                    ForEach(seasons) { season in
                        Button(season.Name) { selectedSeasonID = season.Id }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(current.type == "Episode" ? (current.SeriesName ?? "选集") : current.Name)
                            .font(.title3.bold())
                            .lineLimit(1)
                        if seasons.count > 1 {
                            Image(systemName: "chevron.down").font(.system(size: 12, weight: .bold))
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .tint(.primary)
                Spacer()
                if episodeRanges.count > 1 {
                    Button { episodeRange = max(0, episodeRange - 1) } label: {
                        Image(systemName: "backward.end")
                            .font(.system(size: 16))
                            .foregroundStyle(episodeRange == 0 ? Color.secondary.opacity(0.4) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(episodeRange == 0)
                    Button { episodeRange = min(episodeRanges.count - 1, episodeRange + 1) } label: {
                        Image(systemName: "forward.end")
                            .font(.system(size: 16))
                            .foregroundStyle(episodeRange == episodeRanges.count - 1 ? Color.secondary.opacity(0.4) : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(episodeRange == episodeRanges.count - 1)
                }
                Button { showAllEpisodes = true } label: {
                    Text("更多").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            if episodeRanges.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(episodeRanges.enumerated()), id: \.offset) { index, range in
                            Button { episodeRange = index } label: {
                                Text("\(range.lowerBound + 1)-\(range.upperBound)")
                                    .font(.subheadline.weight(episodeRange == index ? .semibold : .regular))
                                    .foregroundStyle(episodeRange == index ? Color.black : Color.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(episodeRange == index ? Color.white : Color(.systemBackground).opacity(0.55), in: Capsule())
                                    .shadow(color: .black.opacity(episodeRange == index ? 0.12 : 0), radius: 6, y: 2)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            if let client = store.client() {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(displayedEpisodes) { episode in
                            VStack(alignment: .leading, spacing: 6) {
                                ItemImage(item: episode, client: client)
                                    .frame(width: 212, height: 119)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                        .overlay(alignment: .bottom) {
                                            if episode.durationSeconds > 0, episode.resumeSeconds > 0 {
                                                GeometryReader { geo in
                                                    ZStack(alignment: .leading) {
                                                        Capsule().fill(.white.opacity(0.35)).frame(height: 3)
                                                        Capsule().fill(.white)
                                                            .frame(width: geo.size.width * min(episode.resumeSeconds / episode.durationSeconds, 1), height: 3)
                                                    }
                                                }
                                                .frame(height: 3)
                                                .padding(.horizontal, 8)
                                                .padding(.bottom, 6)
                                            }
                                        }
                                        .overlay(alignment: .topTrailing) {
                                            DownloadButton(item: episode, mini: true)
                                                .padding(6)
                                        }
                                        .overlay(alignment: .bottomTrailing) {
                                            if let rating = episode.CommunityRating {
                                                Text(String(format: "%.1f", rating))
                                                    .font(.caption2.weight(.semibold))
                                                    .foregroundStyle(.white)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(.black.opacity(0.55), in: Capsule())
                                                    .padding(6)
                                            }
                                        }
                                    Text(episodeTitle(episode))
                                        .font(.subheadline.weight(.medium)).lineLimit(1)
                                    if let overview = episode.Overview {
                                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                }
                            .frame(width: 212)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                playRequest = PlayRequest(item: episode, startSeconds: episode.resumeSeconds)
                            }
                        }
                    }
                }
            }
        }
    }

    private var displayedEpisodes: [EmbyItem] {
        guard episodeRanges.indices.contains(episodeRange) else { return episodes }
        return Array(episodes[episodeRanges[episodeRange]])
    }

    private func episodeTitle(_ episode: EmbyItem) -> String {
        if let number = episode.IndexNumber {
            return String(format: "E%02d · %@", number, episode.Name)
        }
        return episode.Name
    }

    // MARK: - media info

    @ViewBuilder
    private var mediaInfoSection: some View {
        if let source = current.MediaSources?.first, let streams = source.MediaStreams, !streams.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("媒体信息").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        if let video = streams.first(where: { $0.type == "Video" }) {
                            streamCard(icon: "video", title: "视频", rows: [
                                ("编码", video.Codec ?? "-"),
                                ("分辨率", (video.Width != nil && video.Height != nil) ? "\(video.Width!)x\(video.Height!)" : "-"),
                                ("标题", video.DisplayTitle ?? "-"),
                                ("比特率", video.BitRate.map { String(format: "%.1f Mbps", Double($0) / 1_000_000) } ?? "-"),
                            ])
                        }
                        if let audio = streams.first(where: { $0.type == "Audio" }) {
                            streamCard(icon: "speaker.wave.2", title: "音频", rows: [
                                ("编码", audio.Codec ?? "-"),
                                ("语言", audio.Language ?? "-"),
                                ("声道", audio.Channels.map(String.init) ?? "-"),
                                ("标题", audio.DisplayTitle ?? "-"),
                            ])
                        }
                        let subCount = streams.filter { $0.type == "Subtitle" }.count
                        if subCount > 0 {
                            streamCard(icon: "captions.bubble", title: "字幕", rows: [
                                ("轨道数", "\(subCount)"),
                                ("语言", Set(streams.filter { $0.type == "Subtitle" }.compactMap { $0.Language }).joined(separator: " · ")),
                            ])
                        }
                    }
                }
                HStack {
                    Spacer()
                    Text(sourceSummary(source))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color(.systemGray6), in: Capsule())
            }
        }
    }

    private func streamCard(icon: String, title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title).font(.headline)
            }
            ForEach(rows, id: \.0) { row in
                HStack(alignment: .top, spacing: 10) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                    Text(row.1).lineLimit(2)
                    Spacer()
                }
                .font(.subheadline)
            }
        }
        .padding(16)
        .frame(width: 262, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22))
    }

    private func sourceSummary(_ source: EmbyMediaSource) -> String {
        var parts: [String] = []
        if let container = source.Container { parts.append(container.uppercased()) }
        if let size = source.Size { parts.append(String(format: "%.2f GB", Double(size) / 1_073_741_824)) }
        if let bitrate = source.Bitrate { parts.append(String(format: "%.1f Mbps", Double(bitrate) / 1_000_000)) }
        return parts.joined(separator: " · ")
    }

    // MARK: - actions & loading

    /// "更多": every episode of the selected season in one list.
    private var allEpisodesSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 14) {
                    if let client = store.client() {
                        ForEach(episodes) { episode in
                            HStack(alignment: .top, spacing: 12) {
                                ItemImage(item: episode, client: client)
                                    .frame(width: 132, height: 74)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(episodeTitle(episode))
                                        .font(.subheadline.weight(episode.Id == current.Id ? .bold : .medium))
                                        .lineLimit(1)
                                    if let overview = episode.Overview {
                                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                                    }
                                    if episode.durationSeconds > 0, episode.resumeSeconds > 0 {
                                        ProgressView(value: min(episode.resumeSeconds / episode.durationSeconds, 1))
                                            .tint(Color.accentColor)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture {
                                showAllEpisodes = false
                                playRequest = PlayRequest(item: episode, startSeconds: episode.resumeSeconds)
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle(current.type == "Episode" ? (current.SeriesName ?? "全部集数") : current.Name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { showAllEpisodes = false }
                }
            }
        }
    }

    private func toggleFavorite() {
        let next = !isFavorite
        favOverride = next
        Task { await store.client()?.setFavorite(itemID: current.Id, next) }
    }

    private func togglePlayed() {
        let next = !isPlayed
        playedOverride = next
        Task { await store.client()?.setPlayed(itemID: current.Id, next) }
    }

    /// The item's full backdrop set （艺术图）, as a horizontal strip -
    /// SenPlayer shows the same section. Renders from artworkSource, so
    /// episodes display their series' artwork when they have none.
    @ViewBuilder
    private var artworkSection: some View {
        if let art = artworkSource, art.tags.count > 0, let client = store.client() {
            VStack(alignment: .leading, spacing: 10) {
                Text("艺术图").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Array(art.tags.enumerated()), id: \.offset) { index, _ in
                            AsyncImage(url: client.backdropURL(itemID: art.id, index: index)) { phase in
                                if case .success(let image) = phase {
                                    image.resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(.quaternary)
                                }
                            }
                            .frame(width: 252, height: 142)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        guard let client = store.client() else { return }
        detail = try? await client.item(id: item.Id)
        // Multi-source ratings: movies/series look up their own
        // provider IDs; episodes use the series' (fetched below).
        if current.type != "Episode" {
            ratingsStore.ensure(itemID: item.Id,
                                imdbID: current.ProviderIds?["Imdb"],
                                tmdbID: current.ProviderIds?["Tmdb"],
                                type: current.type)
        }
        // Episode pages brand with the SERIES artwork (SenPlayer's
        // choice), so fetch the series item's backdrop set for every
        // episode, whether or not the episode carries its own tags.
        if current.type == "Episode", let seriesID = current.SeriesId {
            let seriesItem = try? await client.item(id: seriesID)
            seriesBackdropTags = seriesItem?.BackdropImageTags ?? []
            ratingsStore.ensure(itemID: item.Id,
                                imdbID: seriesItem?.ProviderIds?["Imdb"],
                                tmdbID: seriesItem?.ProviderIds?["Tmdb"],
                                type: "Series")
        }
        if item.type == "Movie" || item.type == "Series" {
            similar = (try? await client.similarItems(itemID: item.Id)) ?? []
        }
        if let seriesID {
            seasons = (try? await client.seasons(seriesID: seriesID)) ?? []
            let preferred = seasons.first(where: { $0.Id == current.SeasonId }) ?? seasons.first
            selectedSeasonID = preferred?.Id
            if let preferred { await loadEpisodes(preferred.Id) }
        }
    }

    private func loadEpisodes(_ seasonID: String) async {
        guard let client = store.client(), let seriesID else { return }
        episodes = (try? await client.episodes(seriesID: seriesID, seasonID: seasonID)) ?? []
        // Land on the range holding the episode being viewed (episode
        // details) or the one with resume progress (series details),
        // instead of always opening on 1-5.
        let targetID = current.type == "Episode" ? current.Id
            : episodes.first(where: { $0.resumeSeconds > 0 })?.Id
        if let targetID, let index = episodes.firstIndex(where: { $0.Id == targetID }) {
            episodeRange = index / 5
        }
    }
}

func formatHMS(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
