import SwiftUI
import Foundation
import Network

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

struct DownloadRecovery: Codable {
    var itemID: String
    var skeleton: DownloadRecord
    var container: String?
    var taskID: Int
}

@MainActor
final class DownloadsManager: NSObject, ObservableObject {
    static let shared = DownloadsManager()

    @Published private(set) var records: [DownloadRecord] = []
    @Published private(set) var progress: [String: Double] = [:]
    @Published private(set) var activeIDs: Set<String> = []
    @Published private(set) var failures: [String: String] = [:]
    /// Smoothed download rate per item (bytes/sec), computed in
    /// downloadProgress from successive byte samples; drives the
    /// speed / remaining-time readout in the downloads list.
    @Published private(set) var speeds: [String: Double] = [:]
    private var speedSamples: [String: (bytes: Int64, time: Date)] = [:]

    private let failuresKey = "denia.download.failures.v1"
    private let recoveriesKey = "denia.download.recoveries.v1"
    private var recoveries: [String: DownloadRecovery] = [:]
    private var backgroundEventsCompletion: (() -> Void)?

    private var session: URLSession!
    private var tasks: [Int: String] = [:]            // taskIdentifier -> itemID
    @Published private(set) var pending: [String: DownloadRecord] = [:] // itemID -> active download skeleton
    /// Stored snapshot of `pending` for the downloads list. The list reads
    /// ONLY this array: a plain stored @Published value cannot be lost the
    /// way a computed view over the dictionary apparently can (build 68
    /// showed a blank list mid-download while the data was provably there).
    @Published private(set) var activeList: [DownloadRecord] = []

    func syncActiveList() {
        activeList = pending.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
    private var pendingContainer: [String: String] = [:]

    /// Downloads resolved but waiting for a free slot (concurrency
    /// limit / Wi-Fi-only gate, build 92). The pending row is already
    /// published, so a queued item shows in the list at 0% until its
    /// task actually starts.
    private var startQueue: [(itemID: String, url: URL, skeleton: DownloadRecord, container: String)] = []
    private let pathMonitor = NWPathMonitor()
    /// Optimistic until the first path update lands.
    private var pathIsWiFiLike = true

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
        failures = UserDefaults.standard.dictionary(forKey: failuresKey) as? [String: String] ?? [:]
        if let data = UserDefaults.standard.data(forKey: recoveriesKey),
           let saved = try? JSONDecoder().decode([DownloadRecovery].self, from: data) {
            for recovery in saved where !isDownloaded(recovery.itemID) {
                recoveries[recovery.itemID] = recovery
                pending[recovery.itemID] = recovery.skeleton
                pendingContainer[recovery.itemID] = recovery.container ?? "mkv"
                tasks[recovery.taskID] = recovery.itemID
                activeIDs.insert(recovery.itemID)
                progress[recovery.itemID] = 0
            }
        }
        cleanupOrphans()
        let config = URLSessionConfiguration.background(withIdentifier: "com.denia.embyplayer.media-downloads")
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 12
        syncActiveList()
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wiFiLike = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                self.pathIsWiFiLike = wiFiLike
                self.pumpQueue()
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "denia.downloads.path"))
        session.getAllTasks { [weak self] restoredTasks in
            Task { @MainActor in
                guard let self else { return }
                let live = Set(restoredTasks.map(\.taskIdentifier))
                for task in restoredTasks {
                    if let itemID = self.tasks[task.taskIdentifier] {
                        task.resume()
                    }
                }
                for (itemID, recovery) in self.recoveries where !live.contains(recovery.taskID) {
                    self.finishWithFailure(itemID, message: "下载中断；点下载按钮可重新开始。")
                }
            }
        }
    }

    // MARK: lookups

    func record(for itemID: String) -> DownloadRecord? { records.first { $0.id == itemID } }
    func isDownloaded(_ itemID: String) -> Bool { record(for: itemID) != nil }
    func isDownloading(_ itemID: String) -> Bool { activeIDs.contains(itemID) }
    /// Total size of completed downloads, for the settings page.
    var downloadedBytes: Int64 {
        records.reduce(0) { $0 + $1.sizeBytes }
    }

    private var downloadsGateOpen: Bool {
        !Prefs.downloadWiFiOnly || pathIsWiFiLike
    }

    /// Starts queued downloads while a concurrency slot is free and
    /// the network gate allows it. Called whenever a download is
    /// queued, a task ends, or the network path changes.
    private func pumpQueue() {
        while downloadsGateOpen, tasks.count < Prefs.downloadMaxConcurrent, !startQueue.isEmpty {
            let next = startQueue.removeFirst()
            guard pending[next.itemID] != nil else { continue }
            let task = session.downloadTask(with: next.url)
            tasks[task.taskIdentifier] = next.itemID
            recoveries[next.itemID] = DownloadRecovery(itemID: next.itemID, skeleton: next.skeleton,
                                                       container: next.container, taskID: task.taskIdentifier)
            saveRecoveries()
            task.resume()
        }
    }

    func localURL(for record: DownloadRecord) -> URL { mediaDir.appendingPathComponent(record.fileName) }
    func posterURL(for record: DownloadRecord) -> URL? {
        record.posterFileName.map { posterDir.appendingPathComponent($0) }
    }
    var totalBytes: Int64 { records.reduce(0) { $0 + $1.sizeBytes } }
    var activeDownloads: [DownloadRecord] { pending.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending } }

    static func savedPosition(for itemID: String) -> Double {
        UserDefaults.standard.double(forKey: "dl.pos.\(itemID)")
    }
    static func savePosition(_ seconds: Double, for itemID: String) {
        UserDefaults.standard.set(seconds, forKey: "dl.pos.\(itemID)")
    }

    // MARK: enqueue / cancel / delete

    private func cleanupOrphans() {
        let indexed = Set(records.map(\.fileName))
        guard let files = try? FileManager.default.contentsOfDirectory(at: mediaDir, includingPropertiesForKeys: nil) else { return }
        for file in files where !indexed.contains(file.lastPathComponent) {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func handleBackgroundEvents(completion: @escaping () -> Void) {
        backgroundEventsCompletion = completion
    }

    fileprivate func backgroundEventsFinished() {
        backgroundEventsCompletion?()
        backgroundEventsCompletion = nil
    }

    private func saveRecoveries() {
        let data = try? JSONEncoder().encode(Array(recoveries.values))
        UserDefaults.standard.set(data, forKey: recoveriesKey)
    }

    private func saveFailures() {
        UserDefaults.standard.set(failures, forKey: failuresKey)
    }

    func failure(for itemID: String) -> String? { failures[itemID] }

    /// Resolves the media source first; refuses to start if it would leave
    /// less than 512 MiB free. The error remains visible and retryable.
    func enqueue(item: EmbyItem, client: EmbyClient) {
        guard !isDownloaded(item.Id), !isDownloading(item.Id) else { return }
        activeIDs.insert(item.Id)
        failures[item.Id] = nil
        saveFailures()
        progress[item.Id] = 0
        // Publish an immediate lightweight row before PlaybackInfo returns;
        // otherwise the downloads tab can appear completely empty while the
        // request is being resolved.
        let placeholder = DownloadRecord(
            id: item.Id, name: item.Name, type: item.type,
            seriesID: item.SeriesId, seriesName: item.SeriesName,
            indexNumber: item.IndexNumber, overview: item.Overview,
            runtimeSeconds: item.RunTimeTicks.map { Double($0) / 10_000_000 } ?? 0,
            fileName: "", posterFileName: nil, sizeBytes: 0, hasPGS: false,
            audioLabels: [], subtitleLabels: [], downloadedAt: Date())
        pending[item.Id] = placeholder
        syncActiveList()
        Task {
            do {
                let info = try await client.playbackInfo(itemID: item.Id, startSeconds: 0)
                guard self.activeIDs.contains(item.Id), !Task.isCancelled else { return }
                guard let source = info.MediaSources.first(where: { $0.SupportsDirectPlay == true }) ?? info.MediaSources.first,
                      let url = client.directStreamURL(itemID: item.Id, source: source, sessionID: info.PlaySessionId) else {
                    await MainActor.run { self.finishWithFailure(item.Id, message: "无法取得可下载的媒体源，请检查服务器连接后重试。") }
                    return
                }
                if let expected = source.Size, expected > 0,
                   let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
                   expected > available - 512 * 1024 * 1024 {
                    finishWithFailure(item.Id, message: "空间不足：影片约需 \(ByteCountFormatter.string(fromByteCount: expected, countStyle: .file))，设备需至少保留 512 MB 空间。清理后点此重试。")
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
                    fileName: "", posterFileName: nil, sizeBytes: source.Size ?? 0,
                    hasPGS: streams.contains { $0.type == "Subtitle" && ($0.Codec ?? "").lowercased().contains("pgs") },
                    audioLabels: streams.filter { $0.type == "Audio" }.sorted { $0.Index < $1.Index }
                        .map { $0.DisplayTitle ?? $0.Codec ?? "音轨" },
                    subtitleLabels: streams.filter { $0.type == "Subtitle" }.sorted { $0.Index < $1.Index }
                        .map { $0.DisplayTitle ?? $0.Codec ?? "字幕" },
                    downloadedAt: Date())
                await MainActor.run {
                    self.pending[item.Id] = skeleton
                    self.syncActiveList()
                    self.pendingContainer[item.Id] = source.Container ?? "mkv"
                    self.startQueue.append((itemID: item.Id, url: url, skeleton: skeleton,
                                            container: source.Container ?? "mkv"))
                    self.pumpQueue()
                }
                // Poster alongside, best effort.
                if let poster = client.imageURL(itemID: item.Id, kind: "Primary", maxHeight: 480) {
                    if let (data, _) = try? await URLSession.shared.data(from: poster) {
                        let name = item.Id + ".jpg"
                        try? data.write(to: self.posterDir.appendingPathComponent(name))
                        await MainActor.run {
                            self.pending[item.Id]?.posterFileName = name
                            self.syncActiveList()
                            if var existing = self.record(for: item.Id) {
                                existing.posterFileName = name
                                self.replace(existing)
                            }
                        }
                    }
                }
            } catch {
                await MainActor.run { self.finishWithFailure(item.Id, message: error.localizedDescription) }
            }
        }
    }

    func cancel(itemID: String) {
        for (tid, id) in tasks where id == itemID {
            session.getAllTasks { all in all.first { $0.taskIdentifier == tid }?.cancel() }
        }
        finishWithFailure(itemID, message: nil)
    }

    func delete(_ record: DownloadRecord) {
        try? FileManager.default.removeItem(at: localURL(for: record))
        if let poster = posterURL(for: record) { try? FileManager.default.removeItem(at: poster) }
        records.removeAll { $0.id == record.id }
        failures[record.id] = nil
        saveFailures()
        UserDefaults.standard.removeObject(forKey: "dl.pos.\(record.id)")
        persist()
    }

    // MARK: internals

    private func finishWithFailure(_ itemID: String, message: String? = "下载失败，请检查网络后重试。") {
        startQueue.removeAll { $0.itemID == itemID }
        speeds[itemID] = nil
        speedSamples[itemID] = nil
        activeIDs.remove(itemID)
        progress[itemID] = nil
        pending[itemID] = nil
        syncActiveList()
        pendingContainer[itemID] = nil
        tasks = tasks.filter { $0.value != itemID }
        recoveries[itemID] = nil
        saveRecoveries()
        failures[itemID] = message
        saveFailures()
        pumpQueue()
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
        defer { try? FileManager.default.removeItem(at: tempURL) }
        guard let itemID = tasks[taskID], var skeleton = pending[itemID] else { return }
        let ext = pendingContainer[itemID] ?? "mkv"
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
        speeds[itemID] = nil
        speedSamples[itemID] = nil
        activeIDs.remove(itemID)
        progress[itemID] = nil
        pending[itemID] = nil
        syncActiveList()
        pendingContainer[itemID] = nil
        tasks[taskID] = nil
        recoveries[itemID] = nil
        saveRecoveries()
        failures[itemID] = nil
        saveFailures()
        pumpQueue()
    }

    fileprivate func downloadFailed(taskID: Int) {
        guard let itemID = tasks[taskID] else { return }
        finishWithFailure(itemID)
    }

    fileprivate func downloadProgress(taskID: Int, fraction: Double, bytes: Int64, expected: Int64) {
        guard let itemID = tasks[taskID] else { return }
        progress[itemID] = fraction
        let now = Date()
        if let sample = speedSamples[itemID] {
            let dt = now.timeIntervalSince(sample.time)
            if dt >= 0.5 {
                let rate = Double(bytes - sample.bytes) / dt
                if rate > 0 { speeds[itemID] = rate }
                speedSamples[itemID] = (bytes, now)
            }
        } else {
            speedSamples[itemID] = (bytes, now)
        }
    }
}

extension DownloadsManager: URLSessionDownloadDelegate {
    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in self.backgroundEventsFinished() }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didFinishDownloadingTo location: URL) {
        let tid = downloadTask.taskIdentifier
        guard let response = downloadTask.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            Task { @MainActor in self.downloadFailed(taskID: tid) }
            return
        }
        // Take ownership before the delegate returns and URLSession removes its file.
        let staging = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            Task { @MainActor in self.downloadFinished(taskID: tid, tempURL: staging) }
        } catch {
            Task { @MainActor in self.downloadFailed(taskID: tid) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let tid = downloadTask.taskIdentifier
        Task { @MainActor in
            self.downloadProgress(taskID: tid, fraction: fraction,
                                  bytes: totalBytesWritten, expected: totalBytesExpectedToWrite)
        }
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
    /// Bare glyph in the detail page's Sen-style action row: no disc,
    /// muted tint, sized like its neighbouring action buttons.
    var plain: Bool = false
    @Environment(AppStore.self) private var store
    @ObservedObject private var manager = DownloadsManager.shared
    @State private var showFailure = false

    private var muted: Color { Color(red: 0.52, green: 0.50, blue: 0.62) }

    var body: some View {
        Group {
            if manager.isDownloaded(item.Id) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(plain ? Color.purple : .green)
            } else if manager.isDownloading(item.Id) {
                ZStack {
                    Circle().stroke(plain ? muted.opacity(0.35) : Color.white.opacity(0.3), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: max(0.02, manager.progress[item.Id] ?? 0))
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "stop.fill").font(.system(size: plain ? 8 : 7))
                        .foregroundStyle(plain ? muted : .white)
                }
                .onTapGesture { manager.cancel(itemID: item.Id) }
            } else if manager.failure(for: item.Id) != nil {
                Button { showFailure = true } label: {
                    Image(systemName: "exclamationmark.arrow.circlepath").foregroundStyle(.orange)
                }
            } else {
                Button {
                    if let client = store.client() { manager.enqueue(item: item, client: client) }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
            }
        }
        .font(plain ? .system(size: 24) : (mini ? .system(size: 15) : .system(size: 22)))
        .frame(width: plain ? 34 : (mini ? 28 : 44), height: plain ? 34 : (mini ? 28 : 44))
        .background(plain ? Color.clear : (mini ? Color.black.opacity(0.45) : Color.primary.opacity(0.06)), in: Circle())
        .foregroundStyle(plain ? muted : (mini ? .white : .primary))
        .alert("下载未完成", isPresented: $showFailure) {
            Button("稍后", role: .cancel) {}
            Button("重试下载") { if let client = store.client() { manager.enqueue(item: item, client: client) } }
        } message: {
            Text(manager.failure(for: item.Id) ?? "下载失败，请检查连接后重试。")
        }
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
            if !manager.activeList.isEmpty {
                Text("正在下载").font(.headline)
                ForEach(manager.activeList) { record in activeRow(record) }
            }
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

    private func activeRow(_ record: DownloadRecord) -> some View {
        let fraction = manager.progress[record.id] ?? 0
        let speed = manager.speeds[record.id] ?? 0
        return HStack(spacing: 12) {
            poster(record).frame(width: 96, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 5) {
                Text(record.episodeTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                ProgressView(value: fraction > 0 ? fraction : nil)
                HStack {
                    Text(record.sizeBytes > 0
                         ? "\(Int(fraction * 100))% · \(ByteCountFormatter.string(fromByteCount: Int64(Double(record.sizeBytes) * fraction), countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: record.sizeBytes, countStyle: .file))"
                         : "正在接收数据…")
                    Spacer(minLength: 4)
                    if speed > 0 {
                        let remaining = record.sizeBytes > 0 ? Int(Double(record.sizeBytes) * (1 - fraction) / speed) : 0
                        Text(remaining > 0 ? "剩余 \(formatDLTime(Double(remaining)))" : "\(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file))/秒")
                    }
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Button(role: .destructive) { manager.cancel(itemID: record.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.title3)
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
