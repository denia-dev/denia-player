import SwiftUI

struct PlayRequest: Identifiable {
    let item: EmbyItem
    let startSeconds: Double
    var id: String { item.Id }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(ShellState.self) private var shell
    let item: EmbyItem
    let onBack: () -> Int
    @State private var detail: EmbyItem?
    @State private var seasons: [EmbyItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [EmbyItem] = []
    @State private var episodeRange = 0
    @State private var playRequest: PlayRequest?
    @State private var errorText: String?
    @State private var favOverride: Bool?
    @State private var playedOverride: Bool?
    @State private var overviewExpanded = false

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
                    if let rating = current.CommunityRating {
                        HStack {
                            Spacer()
                            HStack(spacing: 6) {
                                Image(systemName: "star.fill").foregroundStyle(.orange).font(.footnote)
                                Text(String(format: "%.1f", rating)).font(.subheadline.weight(.semibold))
                                Text("评分").foregroundStyle(.secondary).font(.subheadline)
                            }
                            Spacer()
                        }
                    }
                    castSection
                    if seriesID != nil { seriesSection }
                    mediaInfoSection
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .containerRelativeFrame(.horizontal)
        }
        .ignoresSafeArea(edges: .top)
        .background { ambientBackground }
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
        .onChange(of: selectedSeasonID) { _, seasonID in
            episodeRange = 0
            Task { if let seasonID { await loadEpisodes(seasonID) } }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(item: request.item, startSeconds: request.startSeconds)
        }
    }

    /// The backdrop, washed out, behind the whole page (SenPlayer's
    /// ambient tint) instead of a hard white background.
    private var ambientBackground: some View {
        ZStack {
            if let client = store.client() {
                ItemImage(item: current, client: client, kind: "Backdrop")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 50)
                    .scaleEffect(1.25)
            }
            Color(.systemBackground).opacity(0.86)
        }
        .ignoresSafeArea()
    }

    /// Fixed SenPlayer-style top chrome: a glass back circle on the left,
    /// a glass capsule with search + more on the right. It lives outside
    /// the ScrollView so it can never scroll away.

    // MARK: - hero

    private var hero: some View {
        VStack(spacing: 10) {
                if current.ImageTags?["Logo"] != nil, let client = store.client() {
                    AsyncImage(url: client.imageURL(itemID: current.Id, kind: "Logo")) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit() }
                    }
                    .frame(maxWidth: 290, maxHeight: 88)
                } else {
                    Text(current.Name)
                        .font(.system(size: 24, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
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
            }
        .padding(.horizontal, 24)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                if let client = store.client() {
                    ItemImage(item: current, client: client, kind: wideImageKind(current))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                }
                LinearGradient(colors: [.black.opacity(0.25), .clear, Color(.systemBackground).opacity(0.45), Color(.systemBackground).opacity(0.8)],
                               startPoint: .top, endPoint: .bottom)
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
                            .foregroundStyle(.secondary)
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - actions / cast

    private var actionsRow: some View {
        HStack {
            if let target = playTarget {
                actionButton(icon: "arrow.counterclockwise", active: false) {
                    playRequest = PlayRequest(item: target, startSeconds: 0)
                }
                Spacer()
            }
            actionButton(icon: isPlayed ? "checkmark.circle.fill" : "checkmark.circle", active: isPlayed) {
                togglePlayed()
            }
            Spacer()
            actionButton(icon: isFavorite ? "heart.fill" : "heart", active: isFavorite) {
                toggleFavorite()
            }
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 2)
    }

    private func actionButton(icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 25))
                .foregroundStyle(active ? Color.purple : Color(red: 0.52, green: 0.50, blue: 0.62))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var castSection: some View {
        if let people = current.People?.filter({ $0.type == "Actor" }), !people.isEmpty, let client = store.client() {
            VStack(alignment: .leading, spacing: 10) {
                Text("演职人员").font(.title3.bold())
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(people.prefix(15)) { person in
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
            }
            if episodeRanges.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(episodeRanges.enumerated()), id: \.offset) { index, range in
                            Button { episodeRange = index } label: {
                                Text("\(range.lowerBound + 1)-\(range.upperBound)")
                                    .font(.subheadline.weight(episodeRange == index ? .semibold : .regular))
                                    .foregroundStyle(episodeRange == index ? Color.primary : Color.secondary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(Color(.systemBackground).opacity(0.55), in: Capsule())
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
                                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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

    private func load() async {
        guard let client = store.client() else { return }
        detail = try? await client.item(id: item.Id)
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
