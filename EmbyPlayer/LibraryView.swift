import SwiftUI

struct LibraryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.zoomNS) private var zoomNS
    let library: EmbyItem
    @State private var items: [EmbyItem] = []
    @State private var searchText = ""
    @State private var searchResults: [EmbyItem] = []
    @State private var errorText: String?
    @State private var totalCount: Int?
    @State private var loadingMore = false
    @State private var pageError: String?
    @State private var inFlightPageStart: Int?
    @State private var loadGeneration = UUID()

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
                } else if let pageError {
                    VStack(spacing: 8) {
                        Text(pageError).foregroundStyle(.red).font(.footnote)
                        Button("重试加载") { loadNextPage() }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .padding()
        }
        .navigationTitle(library.Name)
        .searchable(text: $searchText, prompt: "搜索影片/剧集")
        .task(id: searchText) {
            await runSearch(searchText)
        }
        .task(id: library.Id + "|" + library.Name) { await load() }
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
                    .zoomSource(id: item.Id, ns: zoomNS)
            }
            Text(item.Name).font(.caption).lineLimit(1)
            if let year = item.ProductionYear {
                Text(String(year)).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        let generation = UUID()
        loadGeneration = generation
        items = []
        totalCount = nil
        searchResults = []
        errorText = nil
        pageError = nil
        loadingMore = false
        inFlightPageStart = nil
        let parentID = library.Id
        guard let client = store.client() else { return }
        do {
            let page = try await client.childrenPage(parentID: parentID, startIndex: 0, limit: pageSize)
            guard !Task.isCancelled, library.Id == parentID, loadGeneration == generation else { return }
            items = page.Items
            totalCount = page.TotalRecordCount
        } catch {
            guard !Task.isCancelled, library.Id == parentID, loadGeneration == generation else { return }
            errorText = error.localizedDescription
        }
    }

    /// Fetch the next page when the scroll nears the end of what we have.
    private func maybeLoadMore(after item: EmbyItem) {
        guard searchText.isEmpty,
              let index = items.firstIndex(where: { $0.Id == item.Id }),
              index >= items.count - 9 else { return }
        loadNextPage()
    }

    private func loadNextPage() {
        guard searchText.isEmpty, !loadingMore, inFlightPageStart == nil,
              let total = totalCount, items.count < total else { return }
        let parentID = library.Id
        let generation = loadGeneration
        let startIndex = items.count
        inFlightPageStart = startIndex
        loadingMore = true
        pageError = nil
        Task {
            defer {
                if library.Id == parentID, loadGeneration == generation,
                   inFlightPageStart == startIndex {
                    inFlightPageStart = nil
                    loadingMore = false
                }
            }
            guard let client = store.client() else {
                guard library.Id == parentID, loadGeneration == generation else { return }
                pageError = "无法连接媒体服务器，请重试。"
                return
            }
            do {
                let page = try await client.childrenPage(parentID: parentID,
                                                         startIndex: startIndex,
                                                         limit: pageSize)
                guard !Task.isCancelled, searchText.isEmpty, library.Id == parentID,
                      loadGeneration == generation, items.count == startIndex else { return }
                let known = Set(items.map(\.Id))
                items.append(contentsOf: page.Items.filter { !known.contains($0.Id) })
                if let newTotal = page.TotalRecordCount { totalCount = newTotal }
            } catch {
                guard !Task.isCancelled, searchText.isEmpty, library.Id == parentID,
                      loadGeneration == generation, items.count == startIndex else { return }
                pageError = "加载失败：\(error.localizedDescription)"
            }
        }
    }

    private func runSearch(_ term: String) async {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let client = store.client(), !query.isEmpty else { searchResults = []; return }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        let matches = (try? await client.search(term: query)) ?? []
        guard !Task.isCancelled, searchText == term else { return }
        searchResults = matches
    }
}
