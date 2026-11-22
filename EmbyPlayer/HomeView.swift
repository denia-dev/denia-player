import SwiftUI

/// Image URL helper bound to the active client.
struct ItemImage: View {
    let item: EmbyItem
    let client: EmbyClient
    var kind: String = "Primary"

    var body: some View {
        let sourceID = (kind == "Primary" && item.Type == "Episode" && item.ImageTags?["Primary"] == nil)
            ? (item.SeriesId ?? item.Id) : item.Id
        return AsyncImage(url: client.imageURL(itemID: sourceID, kind: kind)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: Rectangle().fill(.quaternary)
            }
        }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var libraries: [EmbyItem] = []
    @State private var resume: [EmbyItem] = []
    @State private var errorText: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote).padding(.horizontal)
                }
                if !resume.isEmpty, let client = store.client() {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("继续观看").font(.title3.bold()).padding(.horizontal)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(resume) { item in
                                    NavigationLink { DetailView(item: item) } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            ItemImage(item: item, client: client)
                                                .frame(width: 150, height: 84)
                                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                                .overlay(alignment: .bottom) {
                                                    if item.durationSeconds > 0 {
                                                        ProgressView(value: item.resumeSeconds, total: item.durationSeconds)
                                                            .tint(.white)
                                                            .padding(.horizontal, 6)
                                                            .padding(.bottom, 4)
                                                    }
                                                }
                                            Text(item.Name).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                                            if let series = item.SeriesName {
                                                Text(series).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
                if let client = store.client() {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("媒体库").font(.title3.bold()).padding(.horizontal)
                        LazyVStack(spacing: 10) {
                            ForEach(libraries) { library in
                                NavigationLink { LibraryView(library: library) } label: {
                                    HStack(spacing: 14) {
                                        ItemImage(item: library, client: client)
                                            .frame(width: 64, height: 64)
                                            .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(library.Name).font(.headline)
                                        Spacer()
                                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal)
                                    .padding(.vertical, 6)
                                    .background(RoundedRectangle(cornerRadius: 16).fill(.quaternary.opacity(0.5)))
                                    .padding(.horizontal)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(.vertical)
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard let client = store.client() else { return }
        errorText = nil
        do {
            libraries = try await client.libraries()
            resume = try await client.resumeItems()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
