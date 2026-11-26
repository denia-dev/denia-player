import SwiftUI

/// Manual danmaku picker: search the self-hosted service by name,
/// pick the anime, pick the episode. Needed whenever the service
/// knows the show under a different translated title than the media
/// server does — auto-match cannot bridge that gap on its own.
struct DanmakuSearchView: View {
    let currentEpisode: Int
    let onPick: (String, Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [DanmakuAnimeOption] = []
    @State private var searching = false
    @State private var searched = false

    init(defaultQuery: String, currentEpisode: Int, onPick: @escaping (String, Int) -> Void) {
        self.currentEpisode = currentEpisode
        self.onPick = onPick
        _query = State(initialValue: defaultQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                HStack(spacing: 10) {
                    TextField("输入番名搜索", text: $query)
                        .autocorrectionDisabled()
                        .submitLabel(.search)
                        .onSubmit { Task { await runSearch() } }
                    Button("搜索") { Task { await runSearch() } }
                }
                if searching {
                    HStack(spacing: 10) { ProgressView(); Text("搜索中…") }
                } else if searched && results.isEmpty {
                    Text("没搜到。换个译名、简繁体或日文原名再试试。")
                        .foregroundStyle(.secondary)
                }
                ForEach(results, id: \.animeId) { anime in
                    NavigationLink {
                        episodeList(anime)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(anime.title)
                            Text("\(anime.sourceName) · 共 \(anime.episodes.count) 集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("搜索弹幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await runSearch() }
        }
    }

    private func episodeList(_ anime: DanmakuAnimeOption) -> some View {
        List {
            ForEach(anime.episodes, id: \.episodeId) { episode in
                Button {
                    onPick(anime.title, episode.number)
                    dismiss()
                } label: {
                    HStack {
                        Text(episode.title)
                            .foregroundStyle(.primary)
                        if episode.number == currentEpisode {
                            Spacer()
                            Text("当前在看")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(anime.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func runSearch() async {
        let keyword = query.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        searching = true
        defer { searching = false }
        results = await DanmakuService.search(keyword: keyword)
        searched = true
    }
}
