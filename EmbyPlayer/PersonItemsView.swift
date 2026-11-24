import SwiftUI

/// Filmography for one cast member: everything in the library featuring
/// them, newest first, in the same poster grid the library tab uses.
/// Reached by tapping a person in a detail page's cast row.
struct PersonItemsView: View {
    let personID: String
    let name: String
    @Environment(AppStore.self) private var store
    @State private var items: [EmbyItem] = []
    @State private var loaded = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Prefs.posterColumns == 2 ? 150 : Prefs.posterColumns == 4 ? 88 : 110), spacing: 12)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    if let client = store.client() {
                        AsyncImage(url: client.imageURL(itemID: personID, kind: "Primary", maxHeight: 300)) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFill()
                            } else {
                                Rectangle().fill(.quaternary)
                                    .overlay(Image(systemName: "person.fill").foregroundStyle(.secondary))
                            }
                        }
                        .frame(width: 74, height: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(name).font(.title2.bold())
                        if loaded {
                            Text("共 \(items.count) 部作品").font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                if let client = store.client() {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(items) { item in
                            NavigationLink(value: Route.detail(item)) {
                                PosterCell(item: item, client: client)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if loaded && items.isEmpty {
                    Text("媒体库里暂时没有这位演员的其他作品。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .toolbar(.hidden, for: .tabBar)
        .task {
            guard let client = store.client() else { loaded = true; return }
            items = (try? await client.itemsByPerson(personID: personID)) ?? []
            loaded = true
        }
    }
}
