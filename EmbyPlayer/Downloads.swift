import SwiftUI
import Foundation

// MARK: - offline downloads
//
// Downloads the direct-play file for a movie/episode plus its poster into
// Application Support, with a JSON registry. Playback of a downloaded item
// goes through the normal players with a local file URL (PlayerView's
// local branch); resume positions live in UserDefaults under dl.pos.<id>.

struct DownloadRecord: Codable, Identifiable, Hashable {
    var id: String                 // Emby item id
    var name: String
    var type: String               // Movie / Episode
    var seriesID: String?
    var seriesName: String?
    var indexNumber: Int?
    var overview: String?
    var runtimeSeconds: Double
    var fileName: String           // inside media/
    var posterFileName: String?    // inside posters/
    var sizeBytes: Int64
    var hasPGS: Bool
    var audioLabels: [String]
    var subtitleLabels: [String]
    var downloadedAt: Date

    var episodeTitle: String {
        if type == "Episode", let n = indexNumber { return "第 \(n) 集 · \(name)" }
        return name
    }
}

@MainActor
final class DownloadsManager: NSObject, ObservableObject {
    static let shared = DownloadsManager()

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var activeIDs: Set<String> = []

    private var session: URLSession!
    private var tasks: [Int: String] = [:]            // taskIdentifier -> itemID
    private var pending: [String: DownloadRecord] = [:] // itemID -> record skeleton
    private var pendingSource: [String: EmbyMediaSource] = [:]

    private var root: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DeniaDownloads", isDirectory: true)
    }
    private var mediaDir: URL { root.appendingPathComponent("media", isDirectory: true) }
    private var posterDir: URL { root.appendingPathComponent("posters", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("index.json") }

    override init() {
        super.init()
        for dir in [root, mediaDir, posterDir] {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let data = try? Data(contentsOf: indexURL),
           let saved = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
            // Drop records whose media file vanished.
            records = saved.filter { FileManager.default.fileExists(atPath: mediaDir.appendingPathComponent($0.fileName).path) }
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: lookups

    func record(for itemID: String) -> DownloadRecord? { records.first { $0.id == itemID } }
    func isDownloaded(_ itemID: String) -> Bool { record(for: itemID) != nil }
    func isDownloading(_ itemID: String) -> Bool { activeIDs.contains(itemID) }
    func localURL(for record: DownloadRecord) -> URL { mediaDir.appendingPathComponent(record.fileName) }
    func posterURL(for record: DownloadRecord) -> URL? {
        record.posterFileName.map { posterDir.appendingPathComponent($0) }
    }
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.sizeBytes } }

    static func savedPosition(for itemID: String) -> Double {
        UserDefaults.standard.double(forKey: "dl.pos.\(itemID)")
    }
    static func savePosition(_ seconds: Double, for itemID: String) {
        UserDefaults.standard.set(seconds, forKey: "dl.pos.\(itemID)")
    }

    // MARK: enqueue / cancel / delete

    /// Resolves the same direct-play source the player would use, then
    /// downloads it. Safe to call for items already downloaded/downloading.
    func enqueue(item: EmbyItem, client: EmbyClient) {
        guard !isDownloaded(item.Id), !isDownloading(item.Id) else { return }
        activeIDs.insert(item.Id)
        progress[item.Id] = 0
        Task {
            do {
                let info = try await client.playbackInfo(itemID: item.Id, startSeconds: 0)
                guard let source = info.MediaSources.first(where: { $0.SupportsDirectPlay == true }) ?? info.MediaSources.first,
                      let url = client.directStreamURL(itemID: item.Id, source: source, sessionID: info.PlaySessionId) else {
                    await MainActor.run { self.finishWithFailure(item.Id) }
                    return
                }
                let streams = source.MediaStreams ?? []
                let skeleton = DownloadRecord(
                    id: item.Id,
                    name: item.Name,
                    type: item.type,
                    seriesID: item.SeriesId,
                    seriesName: item.SeriesName,
                    indexNumber: item.IndexNumber,
                    overview: item.Overview,
                    runtimeSeconds: item.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0,
                    fileName: "", posterFileName: nil, sizeBytes: 0,
                    hasPGS: streams.contains { $0.type == "Subtitle" && ($0.Codec ?? "").lowercased().contains("pgs") },
                    audioLabels: streams.filter { $0.type == "Audio" }.sorted { $0.Index < $1.Index }
                        .map { $0.DisplayTitle ?? $0.Codec ?? "音轨" },
                    subtitleLabels: streams.filter { $0.type == "Subtitle" }.sorted { $0.Index < $1.Index }
                        .map { $0.DisplayTitle ?? $0.Codec ?? "字幕" },
                    downloadedAt: Date())
                await MainActor.run {
                    self.pending[item.Id] = skeleton
                    self.pendingSource[item.Id] = source
                    let task = self.session.downloadTask(with: url)
                    self.tasks[task.taskIdentifier] = item.Id
                    task.resume()
                }
                // Poster alongside, best effort.
                if let poster = client.imageURL(itemID: item.Id, kind: "Primary", maxHeight: 480) {
                    if let (data, _) = try? await URLSession.shared.data(from: poster) {
                        let name = item.Id + ".jpg"
                        try? data.write(to: self.posterDir.appendingPathComponent(name))
                        await MainActor.run {
                            self.pending[item.Id]?.posterFileName = name
                            if var existing = self.record(for: item.Id) {
                                existing.posterFileName = name
                                self.replace(existing)
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.finishWithFailure(item.Id) }
            }
        }
    }

    func cancel(itemID: String) {
        for (tid, id) in tasks where id == itemID {
            session.getAllTasks { all in all.first { $0.taskIdentifier == tid }?.cancel() }
        }
        finishWithFailure(itemID)
    }

    func delete(_ record: DownloadRecord) {
        try? FileManager.default.removeItem(at: localURL(for: record))
        if let poster = posterURL(for: record) { try? FileManager.default.removeItem(at: poster) }
        records.removeAll { $0.id == record.id }
        UserDefaults.standard.removeObject(forKey: "dl.pos.\(record.id)")
        persist()
    }

    // MARK: internals

    private func finishWithFailure(_ itemID: String) {
        activeIDs.remove(itemID)
        progress[itemID] = nil
        pending[itemID] = nil
        pendingSource[itemID] = nil
        tasks = tasks.filter { $0.value != itemID }
    }

    private func replace(_ record: DownloadRecord) {
        if let idx = records.firstIndex(where: { $0.id == record.id }) { records[idx] = record }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: indexURL, options: .atomic)
        }
    }

    fileprivate func downloadFinished(taskID: Int, tempURL: URL) {
        guard let itemID = tasks[taskID], var skeleton = pending[itemID] else { return }
        let ext = pendingSource[itemID]?.Container ?? "mkv"
        let fileName = itemID + "." + ext
        let destination = mediaDir.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch { finishWithFailure(itemID); return }
        skeleton.fileName = fileName
        skeleton.sizeBytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0
        skeleton.downloadedAt = Date()
        records.removeAll { $0.id == itemID }
        records.append(skeleton)
        persist()
        activeIDs.remove(itemID)
        progress[itemID] = nil
        pending[itemID] = nil
        pendingSource[itemID] = nil
        tasks[taskID] = nil
    }

    fileprivate func downloadFailed(taskID: Int) {
        guard let itemID = tasks[taskID] else { return }
        finishWithFailure(itemID)
    }

    fileprivate func downloadProgress(taskID: Int, fraction: Double) {
        guard let itemID = tasks[taskID] else { return }
        progress[itemID] = fraction
    }
}

extension DownloadsManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this returns: move it synchronously
        // via a semaphore-free handoff - copy the bytes first.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(downloadTask.taskIdentifier).tmp")
        try? FileManager.default.removeItem(at: staging)
        try? FileManager.default.copyItem(at: location, to: staging)
        let tid = downloadTask.taskIdentifier
        Task { @MainActor in self.downloadFinished(taskID: tid, tempURL: staging) }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let tid = downloadTask.taskIdentifier
        Task { @MainActor in self.downloadProgress(taskID: tid, fraction: fraction) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard error != nil else { return }
        let tid = task.taskIdentifier
        Task { @MainActor in self.downloadFailed(taskID: tid) }
    }
}

// MARK: - download button (detail pages & episode cards)

struct DownloadButton: View {
    let item: EmbyItem
    var mini: Bool = false
    @Environment(AppStore.self) private var store
    @ObservedObject private var manager = DownloadsManager.shared

    var body: some View {
        Group {
            if manager.isDownloaded(item.Id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if manager.isDownloading(item.Id) {
                ZStack {
                    Circle().stroke(Color.white.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, manager.progress[item.Id] ?? 0))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: 7)).foregroundStyle(.white)
                }
                .onTapGesture { manager.cancel(itemID: item.Id) }
            } else {
                Button {
                    if let client = store.client() { manager.enqueue(item: item, client: client) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
        }
        .font(mini ? .system(size: 15) : .system(size: 22))
        .frame(width: mini ? 28 : 44, height: mini ? 28 : 44)
        .background(mini ? Color.black.opacity(0.45) : Color.primary.opacity(0.06), in: Circle())
        .foregroundStyle(mini ? .white : .primary)
    }
}

// MARK: - downloads list (\"下载\" segment in Records)

struct DownloadsView: View {
    @ObservedObject private var manager = DownloadsManager.shared
    @State private var playing: DownloadRecord?

    private var movies: [DownloadRecord] { manager.records.filter { $0.type != "Episode" } }
    private var seriesGroups: [(name: String, episodes: [DownloadRecord])] {
        let grouped = Dictionary(grouping: manager.records.filter { $0.type == "Episode" }) { $0.seriesName ?? "剧集" }
        return grouped.map { (name: $0.key, episodes: $0.value.sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if manager.records.isEmpty && manager.activeIDs.isEmpty {
                Text("还没有下载。在详情页点下载按钮，影片会存到本地，没网也能看。")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .padding(.top, 8)
            }
            ForEach(seriesGroups, id: \.name) { group in
                Text(group.name).font(.headline).padding(.top, 4)
                ForEach(group.episodes) { record in row(record) }
            }
            if !movies.isEmpty {
                Text("电影").font(.headline).padding(.top, 4)
                ForEach(movies) { record in row(record) }
            }
            if !manager.records.isEmpty {
                Text("共占用 " + ByteCountFormatter.string(fromByteCount: manager.totalBytes, countStyle: .file))
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
        }
        .fullScreenCover(item: $playing) { record in
            PlayerView(item: record.asItem,
                       startSeconds: DownloadsManager.savedPosition(for: record.id),
                       localFileURL: manager.localURL(for: record),
                       localHasPGS: record.hasPGS,
                       localAudioLabels: record.audioLabels,
                       localSubtitleLabels: record.subtitleLabels)
        }
    }

    private func row(_ record: DownloadRecord) -> some View {
        HStack(spacing: 12) {
            poster(record)
                .frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(record.episodeTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .file)
                     + (DownloadsManager.savedPosition(for: record.id) > 5
                        ? " · 看到 " + formatDLTime(DownloadsManager.savedPosition(for: record.id)) : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { playing = record } label: {
                Image(systemName: "play.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
            }
            Button(role: .destructive) { manager.delete(record) } label: {
                Image(systemName: "trash").font(.body)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func poster(_ record: DownloadRecord) -> some View {
        if let url = manager.posterURL(for: record),
           let data = try? Data(contentsOf: url),
           let image = UIImage(data: data) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Color.primary.opacity(0.08)
                .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
        }
    }
}

private func formatDLTime(_ seconds: Double) -> String {
    let total = Int(seconds)
    return String(format: "%d:%02d", total / 60, total % 60)
}

extension DownloadRecord {
    /// Minimal EmbyItem reconstruction for the players.
    var asItem: EmbyItem {
        var dict: [String: Any] = ["Id": id, "Name": name, "Type": type,
                                   "RunTimeTicks": Int64(runtimeSeconds * 10_000_000)]
        if let seriesID { dict["SeriesId"] = seriesID }
        if let seriesName { dict["SeriesName"] = seriesName }
        if let indexNumber { dict["IndexNumber"] = indexNumber }
        if let overview { dict["Overview"] = overview }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(EmbyItem.self, from: data)
    }
}
