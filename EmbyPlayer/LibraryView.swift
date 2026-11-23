import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    let library: EmbyItem
    @State private var items: [EmbyItem] = []
    @State private var searchText = ""
    @State private var searchResults: [EmbyItem] = []
    @State private var errorText: String?
    @State private var totalCount: Int?
    @State private var loadingMore = false

    private let pageSize = 60

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
                    .onAppear { maybeLoadMore(after: item) }
                }
                if loadingMore {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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
        do {
            let page = try await client.childrenPage(parentID: library.Id, startIndex: 0, limit: pageSize)
            items = page.Items
            totalCount = page.TotalRecordCount
        } catch { errorText = error.localizedDescription }
    }

    /// Fetch the next page when the scroll nears the end of what we have.
    private func maybeLoadMore(after item: EmbyItem) {
        guard searchText.isEmpty, !loadingMore else { return }
        guard let total = totalCount, items.count < total else { return }
        guard let index = items.firstIndex(where: { $0.Id == item.Id }),
              index >= items.count - 9 else { return }
        loadingMore = true
        Task {
            defer { loadingMore = false }
            guard let client = store.client() else { return }
            guard let page = try? await client.childrenPage(parentID: library.Id,
                                                            startIndex: items.count,
                                                            limit: pageSize) else { return }
            let known = Set(items.map(\.Id))
            items.append(contentsOf: page.Items.filter { !known.contains($0.Id) })
            if let newTotal = page.TotalRecordCount { totalCount = newTotal }
        }
    }

    private func runSearch(_ term: String) async {
        guard let client = store.client(), !term.isEmpty else { searchResults = []; return }
        searchResults = (try? await client.search(term: term)) ?? []
    }
}
