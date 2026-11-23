import SwiftUI

/// Image URL helper bound to the active client.
struct ItemImage: View {
    let item: EmbyItem
    let client: EmbyClient
    var kind: String = "Primary"

    var body: some View {
        let sourceID = (kind == "Primary" && item.type == "Episode" && item.ImageTags?["Primary"] == nil)
            ? (item.SeriesId ?? item.Id) : item.Id
        return AsyncImage(url: client.imageURL(itemID: sourceID, kind: kind)) { phase in
            switch phase {
            case .success(let image): image.resizable().scaledToFill()
            default: Rectangle().fill(.quaternary)
            }
        }
    }
}

/// Backdrop when the item has one, poster otherwise (wide cards).
func wideImageKind(_ item: EmbyItem) -> String {
    (item.BackdropImageTags?.isEmpty == false) ? "Backdrop" : "Primary"
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @State private var libraries: [EmbyItem] = []
    @State private var resume: [EmbyItem] = []
    @State private var latest: [EmbyItem] = []
    @State private var heroIndex = 0
    @State private var showServers = false
    @State private var errorText: String?

    private var heroItems: [EmbyItem] { latest.isEmpty ? resume : latest }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.footnote).padding(.horizontal)
                }
                if Prefs.showHomeResume, !resume.isEmpty, let client = store.client() {
                    sectionHeader("继续观看", count: resume.count)
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
                if Prefs.showHomeLibraries, !libraries.isEmpty, let client = store.client() {
                    sectionHeader("我的媒体库", count: nil)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(libraries) { library in
                                NavigationLink(value: Route.library(library)) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ItemImage(item: library, client: client)
                                            .frame(width: 104, height: 156)
                                            .clipShape(RoundedRectangle(cornerRadius: 14))
                                        Text(library.Name).font(.caption).lineLimit(1)
                                            .frame(width: 104, alignment: .leading)
                                    }
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
        }
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .refreshable { await load() }
        .task { await load() }
        .task { await heroAutoAdvance() }
        .sheet(isPresented: $showServers) { ServersView() }
    }

    // MARK: - hero

    private var hero: some View {
        ZStack(alignment: .bottom) {
            if let client = store.client(), !heroItems.isEmpty {
                TabView(selection: $heroIndex) {
                    ForEach(Array(heroItems.enumerated()), id: \.element.Id) { index, item in
                        NavigationLink(value: Route.detail(item)) {
                            heroCell(item, client: client)
                        }
                        .buttonStyle(.plain)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: 496)

                HStack(spacing: 6) {
                    ForEach(heroItems.indices, id: \.self) { index in
                        Circle()
                            .fill(index == heroIndex ? Color.primary : Color.secondary.opacity(0.35))
                            .frame(width: 7, height: 7)
                    }
                }
                .padding(.bottom, 10)
            } else {
                Rectangle().fill(.quaternary).frame(height: 300)
            }

            VStack {
                HStack {
                    Button { showServers = true } label: {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.green)
                                .frame(width: 30, height: 30)
                                .overlay(Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white))
                            Text(store.activeServer?.name ?? "")
                                .font(.subheadline.bold())
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .glassEffect(.regular.interactive(), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 58)
        }
        .frame(height: 496)
    }

    private func heroCell(_ item: EmbyItem, client: EmbyClient) -> some View {
        VStack(spacing: 8) {
                if item.ImageTags?["Logo"] != nil {
                    AsyncImage(url: client.imageURL(itemID: item.Id, kind: "Logo")) { phase in
                        if case .success(let image) = phase {
                            image.resizable().scaledToFit()
                        }
                    }
                    .frame(maxWidth: 280, maxHeight: 84)
                } else {
                    Text(item.Name)
                        .font(.system(size: 27, weight: .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let year = item.ProductionYear { Text(String(year)) }
                    Text(item.type == "Series" ? "剧集" : "电影")
                    if let rating = item.CommunityRating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                if let overview = item.Overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
        .padding(.horizontal, 28)
        .padding(.bottom, 30)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .background {
            ZStack {
                ItemImage(item: item, client: client, kind: wideImageKind(item))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                LinearGradient(colors: [.clear, .clear, Color(.systemBackground).opacity(0.75), Color(.systemBackground)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .frame(height: 496)
        .clipped()
    }

    private func sectionHeader(_ title: String, count: Int?) -> some View {
        HStack {
            Text(title).font(.title3.bold())
            Spacer()
            if let count {
                Text("\(count)").foregroundStyle(.secondary)
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal)
    }

    private func heroAutoAdvance() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(6))
            guard !heroItems.isEmpty else { continue }
            withAnimation { heroIndex = (heroIndex + 1) % heroItems.count }
        }
    }

    private func load() async {
        guard let client = store.client() else { return }
        errorText = nil
        do {
            libraries = try await client.libraries()
            resume = try await client.resumeItems()
            latest = (try? await client.latestItems()) ?? []
        } catch {
            errorText = error.localizedDescription
        }
    }
}
