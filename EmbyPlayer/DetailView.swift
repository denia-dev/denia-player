import SwiftUI

struct PlayRequest: Identifiable {
    let item: EmbyItem
    let startSeconds: Double
    var id: String { item.Id }
}

struct DetailView: View {
    @Environment(AppStore.self) private var store
    let item: EmbyItem
    @State private var detail: EmbyItem?
    @State private var seasons: [EmbyItem] = []
    @State private var selectedSeasonID: String?
    @State private var episodes: [EmbyItem] = []
    @State private var playRequest: PlayRequest?
    @State private var errorText: String?

    private var current: EmbyItem { detail ?? item }
    private var isSeries: Bool { current.type == "Series" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote)
                }
                if current.isPlayable {
                    playButton(for: current)
                }
                if let overview = current.Overview, !overview.isEmpty {
                    Text(overview).font(.body).foregroundStyle(.secondary)
                }
                if isSeries { seriesSection }
            }
            .padding()
        }
        .navigationTitle(current.Name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: selectedSeasonID) { _, seasonID in
            Task { if let seasonID { await loadEpisodes(seasonID) } }
        }
        .fullScreenCover(item: $playRequest) { request in
            PlayerView(item: request.item, startSeconds: request.startSeconds)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            if let client = store.client() {
                ItemImage(item: current, client: client)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(current.Name).font(.title3.bold())
                HStack(spacing: 8) {
                    if let year = current.ProductionYear { Text(String(year)) }
                    if current.durationSeconds > 0 {
                        Text(formatDuration(current.durationSeconds))
                    }
                    if let label = current.episodeLabel { Text(label) }
                }
                .font(.subheadline).foregroundStyle(.secondary)
                if let series = current.SeriesName {
                    Text(series).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }

    private func playButton(for target: EmbyItem) -> some View {
        Button {
            playRequest = PlayRequest(item: target, startSeconds: target.resumeSeconds)
        } label: {
            HStack {
                Image(systemName: "play.fill")
                Text(target.resumeSeconds > 60 ? "继续播放" : "开始播放")
                if target.resumeSeconds > 60 {
                    Text(formatDuration(target.resumeSeconds)).foregroundStyle(.white.opacity(0.8))
                }
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(Color.blue, in: RoundedRectangle(cornerRadius: 12))
            .foregroundStyle(.white)
        }
    }

    private var seriesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            if seasons.count > 1 {
                Picker("季", selection: $selectedSeasonID) {
                    ForEach(seasons) { season in
                        Text(season.Name).tag(Optional(season.Id))
                    }
                }
                .pickerStyle(.menu)
            }
            LazyVStack(spacing: 10) {
                ForEach(episodes) { episode in
                    Button {
                        playRequest = PlayRequest(item: episode, startSeconds: episode.resumeSeconds)
                    } label: {
                        HStack(spacing: 12) {
                            if let client = store.client() {
                                ItemImage(item: episode, client: client)
                                    .frame(width: 112, height: 63)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                if let label = episode.episodeLabel {
                                    Text(label).font(.caption).foregroundStyle(.blue)
                                }
                                Text(episode.Name).font(.subheadline).lineLimit(2)
                                if episode.resumeSeconds > 60 {
                                    Text("看到 \(formatDuration(episode.resumeSeconds))")
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Image(systemName: "play.circle").foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func load() async {
        guard let client = store.client() else { return }
        detail = try? await client.item(id: item.Id)
        if current.type == "Series" {
            seasons = (try? await client.seasons(seriesID: current.Id)) ?? []
            selectedSeasonID = seasons.first?.Id
            if let first = seasons.first { await loadEpisodes(first.Id) }
        }
    }

    private func loadEpisodes(_ seasonID: String) async {
        guard let client = store.client() else { return }
        episodes = (try? await client.episodes(seriesID: current.Id, seasonID: seasonID)) ?? []
    }
}

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}
