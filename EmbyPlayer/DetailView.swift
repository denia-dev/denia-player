import SwiftUI

struct PlayRequest: Identifiable {
    let item: EmbyItem
    let startSeconds: Double
    var id: String { item.Id }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let item: EmbyItem
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
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .lineLimit(overviewExpanded ? nil : 3)
                            .onTapGesture { overviewExpanded.toggle() }
                    }
                    if let rating = current.CommunityRating {
                        HStack(spacing: 6) {
                            Image(systemName: "star.fill").foregroundStyle(.orange)
                            Text(String(format: "%.1f", rating)).font(.headline)
                            Text("评分").foregroundStyle(.secondary).font(.subheadline)
                        }
                    }
                    castSection
                    if seriesID != nil { seriesSection }
                    mediaInfoSection
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
        }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .onChange(of: selectedSeasonID) { _, seasonID in
            episodeRange = 0
            Task { if let seasonID { await loadEpisodes(seasonID) } }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(item: request.item, startSeconds: request.startSeconds)
        }
    }

    // MARK: - hero

    private var hero: some View {
        ZStack(alignment: .bottom) {
            if let client = store.client() {
                ItemImage(item: current, client: client, kind: wideImageKind(current))
                    .frame(maxWidth: .infinity)
                    .frame(height: 478)
                    .clipped()
            }
            LinearGradient(colors: [.black.opacity(0.25), .clear, Color(.systemBackground).opacity(0.72), Color(.systemBackground)],
                           startPoint: .top, endPoint: .bottom)

            VStack(spacing: 10) {
                if current.ImageTags?["Logo"] != nil, let client = store.client() {
                    AsyncImage(url: client.imageURL(itemID: current.Id, kind: "Logo")) { phase in
                        if case .success(let image) = phase { image.resizable().scaledToFit() }
                    }
                    .frame(maxWidth: 290, maxHeight: 88)
                } else {
                    Text(current.Name)
                        .font(.system(size: 26, weight: .bold))
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

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button { toggleFavorite() } label: {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(isFavorite ? .red : .primary)
                            .frame(width: 38, height: 38)
                            .background(.ultraThinMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 56)
        }
        .frame(height: 478)
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
                        if target.resumeSeconds > 60 {
                            Text(formatDuration(target.resumeSeconds)).foregroundStyle(.secondary)
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - actions / cast

    private var actionsRow: some View {
        HStack(spacing: 0) {
            if let target = playTarget {
                actionButton(icon: "arrow.counterclockwise", label: "从头播") {
                    playRequest = PlayRequest(item: target, startSeconds: 0)
                }
            }
            actionButton(icon: isPlayed ? "checkmark.circle.fill" : "checkmark.circle", label: "已看") {
                togglePlayed()
            }
            actionButton(icon: isFavorite ? "heart.fill" : "heart", label: "收藏", active: isFavorite) {
                toggleFavorite()
            }
            Spacer()
        }
    }

    private func actionButton(icon: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 21))
                    .foregroundStyle(active ? .red : .primary)
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 64)
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
                                .frame(width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                Text(person.Name).font(.caption.weight(.medium)).lineLimit(2)
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
                Text(current.type == "Episode" ? (current.SeriesName ?? "选集") : current.Name)
                    .font(.title3.bold())
                if seasons.count > 1 {
                    Menu {
                        ForEach(seasons) { season in
                            Button(season.Name) { selectedSeasonID = season.Id }
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Text(seasons.first(where: { $0.Id == selectedSeasonID })?.Name ?? "")
                                .font(.subheadline)
                            Image(systemName: "chevron.down").font(.caption2.bold())
                        }
                        .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if episodeRanges.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(episodeRanges.enumerated()), id: \.offset) { index, range in
                            Button { episodeRange = index } label: {
                                Text("\(range.lowerBound + 1)-\(range.upperBound)")
                                    .font(.subheadline.weight(episodeRange == index ? .semibold : .regular))
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 7)
                                    .background(episodeRange == index ? Color(.systemGray4) : Color(.systemGray6), in: Capsule())
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
                            Button {
                                playRequest = PlayRequest(item: episode, startSeconds: episode.resumeSeconds)
                            } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    ItemImage(item: episode, client: client)
                                        .frame(width: 236, height: 133)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
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
                                    Text(episodeTitle(episode))
                                        .font(.subheadline.weight(.medium)).lineLimit(1)
                                    if let overview = episode.Overview {
                                        Text(overview).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                }
                                .frame(width: 236)
                            }
                            .buttonStyle(.plain)
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
        .padding(14)
        .frame(width: 262, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
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

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
