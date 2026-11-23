import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    let library: EmbyItem
    @State private var items: [EmbyItem] = []
    @State private var searchText = ""
    @State private var searchResults: [EmbyItem] = []
    @State private var errorText: String?

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Prefs.posterColumns == 2 ? 150 : Prefs.posterColumns == 4 ? 88 : 110), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            if let errorText {
                Text(errorText).foregroundStyle(.red).font(.footnote).padding()
            }
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(displayed) { item in
                    NavigationLink(value: Route.detail(item)) {
                        gridCell(item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
        .navigationTitle(library.Name)
        .searchable(text: $searchText, prompt: "搜索影片/剧集")
        .onChange(of: searchText) { _, term in
            Task { await runSearch(term) }
        }
        .task { await load() }
        .toolbar(.hidden, for: .tabBar)
    }

    private var displayed: [EmbyItem] { searchText.isEmpty ? items : searchResults }

    @ViewBuilder
    private func gridCell(_ item: EmbyItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let client = store.client() {
                ItemImage(item: item, client: client)
                    .aspectRatio(2 / 3, contentMode: .fill)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text(item.Name).font(.caption).lineLimit(1)
            if let year = item.ProductionYear {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        guard let client = store.client() else { return }
        do { items = try await client.children(parentID: library.Id) }
        catch { errorText = error.localizedDescription }
    }

    private func runSearch(_ term: String) async {
        guard let client = store.client(), !term.isEmpty else { searchResults = []; return }
        searchResults = (try? await client.search(term: term)) ?? []
    }
}
