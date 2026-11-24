import Foundation
import SwiftUI

// MARK: - ASSRT (assrt.net) online subtitles

struct AssrtSearchResult: Identifiable {
    let id: Int
    let title: String
    let language: String
}

struct AssrtFile: Identifiable {
    let name: String
    let url: URL
    var id: String { url.absoluteString }
}

enum AssrtError: LocalizedError {
    case api(String)
    case noFiles
    case unsupportedPackage

    var errorDescription: String? {
        switch self {
        case .api(let message):
            return message.isEmpty ? "ASSRT 接口出错" : "ASSRT：\(message)"
        case .noFiles:
            return "这条字幕没有可下载的文件"
        case .unsupportedPackage:
            return "这条是压缩包字幕且没有散文件，换一个结果"
        }
    }
}

/// Thin client for the assrt.net API (the same public API the Kodi
/// subtitle addons use): keyword search, then a detail call whose
/// filelist carries direct per-file download URLs, so no archive
/// handling is needed for the common cases.
final class AssrtClient {
    static let shared = AssrtClient()
    private init() {}

    private static let defaultToken = "vXMvTf8eu4pfmAVmllp8OY6aYqVbeB4F"

    private var token: String {
        let custom = KeychainStore.get("assrtToken") ?? ""
        return custom.isEmpty ? Self.defaultToken : custom
    }

    private func getJSON(_ path: String, query: [String: String]) async throws -> [String: Any] {
        var components = URLComponents(string: "https://api.assrt.net/" + path)
        components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw AssrtError.noFiles }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AssrtError.api("返回格式不对")
        }
        if let status = json["status"] as? Int, status != 0 {
            throw AssrtError.api((json["errmsg"] as? String) ?? "")
        }
        return json
    }

    func search(query: String) async throws -> [AssrtSearchResult] {
        let json = try await getJSON("v1/sub/search", query: ["q": query, "cnt": "20", "pos": "0"])
        let subs = ((json["sub"] as? [String: Any])?["subs"] as? [[String: Any]]) ?? []
        return subs.compactMap { entry in
            guard let id = entry["id"] as? Int else { return nil }
            let title = (entry["native_name"] as? String)
                ?? (entry["filename"] as? String)
                ?? "字幕 \(id)"
            var language = ""
            if let lang = entry["lang"] as? [String: Any] {
                language = (lang["desc"] as? String) ?? ""
            }
            return AssrtSearchResult(id: id, title: title, language: language)
        }
    }

    /// The downloadable subtitle files behind one search result.
    func files(for resultID: Int) async throws -> [AssrtFile] {
        let json = try await getJSON("v1/sub/detail", query: ["id": String(resultID)])
        guard let sub = ((json["sub"] as? [String: Any])?["subs"] as? [[String: Any]])?.first else {
            throw AssrtError.noFiles
        }
        let subtitleExts = [".srt", ".ass", ".ssa", ".vtt"]
        if let filelist = sub["filelist"] as? [[String: Any]], !filelist.isEmpty {
            let files = filelist.compactMap { entry -> AssrtFile? in
                guard let name = entry["f"] as? String,
                      let urlString = entry["url"] as? String,
                      let url = URL(string: urlString),
                      subtitleExts.contains(where: { name.lowercased().hasSuffix($0) }) else { return nil }
                return AssrtFile(name: name, url: url)
            }
            if files.isEmpty { throw AssrtError.noFiles }
            return files
        }
        if let filename = sub["filename"] as? String,
           let urlString = sub["url"] as? String, let url = URL(string: urlString) {
            if subtitleExts.contains(where: { filename.lowercased().hasSuffix($0) }) {
                return [AssrtFile(name: filename, url: url)]
            }
            throw AssrtError.unsupportedPackage
        }
        throw AssrtError.noFiles
    }

    /// Downloads the file into the online-subtitles cache and returns
    /// its local URL, ready for the player to load.
    func download(_ file: AssrtFile) async throws -> URL {
        let (data, _) = try await URLSession.shared.data(from: file.url)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnlineSubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = file.name.replacingOccurrences(of: "/", with: "_")
        let out = dir.appendingPathComponent(safeName)
        try data.write(to: out, options: .atomic)
        return out
    }
}

/// A subtitle file the user picked from an online source, kept per
/// series (Application Support, survives cache purges) so the same
/// choice is restored on the next episode or reopen. The file's
/// presence IS the memory; picking an embedded track or switching
/// subtitles off clears it.
enum RememberedExternalSubtitle {
    static func url(for key: String) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        return files.first { $0.deletingPathExtension().lastPathComponent == key }
    }

    static func save(_ source: URL, for key: String) {
        clear(for: key)
        let ext = source.pathExtension.isEmpty ? "srt" : source.pathExtension
        let dest = directory.appendingPathComponent("\(key).\(ext)")
        try? FileManager.default.copyItem(at: source, to: dest)
    }

    static func clear(for key: String) {
        if let existing = url(for: key) {
            try? FileManager.default.removeItem(at: existing)
        }
    }

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RememberedSubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }
}

// MARK: - OpenSubtitles (opensubtitles.com) online subtitles

struct OSSearchResult: Identifiable {
    let fileID: Int
    let releaseName: String
    let language: String
    let downloads: Int
    var id: Int { fileID }
}

enum OSError: LocalizedError {
    case noKey
    case api(String)

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "OpenSubtitles 需要 API Key：在 opensubtitles.com 免费注册并申请后，填到 设置 → 字幕设置"
        case .api(let message):
            return message.isEmpty ? "OpenSubtitles 接口出错" : "OpenSubtitles：\(message)"
        }
    }
}

/// Client for the opensubtitles.com REST API. Unlike ASSRT there is
/// no shared public key: every app registers its own free API key,
/// which the user pastes into the subtitle settings (Keychain).
final class OpenSubtitlesClient {
    static let shared = OpenSubtitlesClient()
    private init() {}

    private var apiKey: String { KeychainStore.get("osApiKey") ?? "" }

    private func request(path: String, method: String = "GET",
                         query: [String: String] = [:], body: [String: Any]? = nil) async throws -> [String: Any] {
        guard !apiKey.isEmpty else { throw OSError.noKey }
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/" + path)
        if !query.isEmpty {
            components?.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components?.url else { throw OSError.api("地址不对") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("DeniaPlayer v1.01", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let message = (json?["message"] as? String) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 {
                throw OSError.api(message.isEmpty ? "API Key 无效" : message)
            }
            if http.statusCode == 429 {
                throw OSError.api("今日下载额度用完了")
            }
            throw OSError.api(message.isEmpty ? "HTTP \(http.statusCode)" : message)
        }
        guard let json else { throw OSError.api("返回格式不对") }
        return json
    }

    func search(query: String) async throws -> [OSSearchResult] {
        let json = try await request(path: "subtitles", query: [
            "query": query,
            "languages": "zh-cn,zh-tw,en",
            "order_by": "download_count",
            "order_direction": "desc",
        ])
        let data = (json["data"] as? [[String: Any]]) ?? []
        return data.compactMap { entry in
            guard let attributes = entry["attributes"] as? [String: Any],
                  let file = (attributes["files"] as? [[String: Any]])?.first,
                  let fileID = file["file_id"] as? Int else { return nil }
            return OSSearchResult(
                fileID: fileID,
                releaseName: (attributes["release"] as? String) ?? (file["file_name"] as? String) ?? "字幕",
                language: (attributes["language"] as? String) ?? "",
                downloads: (attributes["download_count"] as? Int) ?? 0)
        }
    }

    /// Two-step download: exchange the file id for a temporary link,
    /// then fetch the file into the shared online-subtitles cache.
    func download(_ result: OSSearchResult) async throws -> URL {
        let json = try await request(path: "download", method: "POST", body: ["file_id": result.fileID])
        guard let linkString = json["link"] as? String, let link = URL(string: linkString) else {
            throw OSError.api("没拿到下载链接")
        }
        let fileName = (json["file_name"] as? String) ?? "subtitle-\(result.fileID).srt"
        let (data, _) = try await URLSession.shared.data(from: link)
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OnlineSubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safeName = fileName.replacingOccurrences(of: "/", with: "_")
        let out = dir.appendingPathComponent(safeName)
        try data.write(to: out, options: .atomic)
        return out
    }
}

// MARK: - Search sheet

struct OnlineSubtitleSearchView: View {
    let onLoaded: (URL) -> Void

    private enum Source: String, CaseIterable {
        case assrt = "ASSRT"
        case opensubtitles = "OpenSubtitles"
    }

    @Environment(\.dismiss) private var dismiss
    @State private var source: Source = .assrt
    @State private var query: String
    @State private var results: [AssrtSearchResult] = []
    @State private var osResults: [OSSearchResult] = []
    @State private var searching = false
    @State private var downloading = false
    @State private var errorText: String?
    @State private var fileChoices: [AssrtFile] = []
    @State private var showFilePicker = false

    init(defaultQuery: String, onLoaded: @escaping (URL) -> Void) {
        self.onLoaded = onLoaded
        _query = State(initialValue: defaultQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                Picker("字幕源", selection: $source) {
                    ForEach(Source.allCases, id: \.self) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .onChange(of: source) { _, _ in Task { await runSearch() } }
                if searching {
                    HStack(spacing: 10) { ProgressView(); Text("搜索中…") }
                }
                if downloading {
                    HStack(spacing: 10) { ProgressView(); Text("下载中…") }
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
                if source == .assrt {
                    ForEach(results) { result in
                        Button {
                            Task { await pick(result) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.title)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                if !result.language.isEmpty {
                                    Text(result.language)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .disabled(downloading)
                    }
                } else {
                    ForEach(osResults) { result in
                        Button {
                            Task { await pickOS(result) }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(result.releaseName)
                                    .font(.system(size: 14))
                                    .foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading)
                                Text("\(result.language) · 下载 \(result.downloads) 次")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(downloading)
                    }
                }
            }
            .navigationTitle("在线字幕")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "片名 + 季集，如 街角魔族 S01E06")
            .onSubmit(of: .search) { Task { await runSearch() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .task { await runSearch() }
            .sheet(isPresented: $showFilePicker) {
                NavigationStack {
                    List(fileChoices) { file in
                        Button {
                            showFilePicker = false
                            Task { await finish(file) }
                        } label: {
                            Text(file.name)
                                .font(.system(size: 14))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .navigationTitle("选择文件")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("取消") { showFilePicker = false }
                        }
                    }
                }
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !searching else { return }
        searching = true
        errorText = nil
        do {
            if source == .assrt {
                results = try await AssrtClient.shared.search(query: trimmed)
                if results.isEmpty { errorText = "没搜到，换个关键词试试" }
            } else {
                osResults = try await OpenSubtitlesClient.shared.search(query: trimmed)
                if osResults.isEmpty { errorText = "没搜到，换个关键词试试" }
            }
        } catch {
            results = []
            osResults = []
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        searching = false
    }

    private func pickOS(_ result: OSSearchResult) async {
        errorText = nil
        downloading = true
        do {
            let local = try await OpenSubtitlesClient.shared.download(result)
            downloading = false
            onLoaded(local)
            dismiss()
        } catch {
            downloading = false
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func pick(_ result: AssrtSearchResult) async {
        errorText = nil
        do {
            let files = try await AssrtClient.shared.files(for: result.id)
            if files.count == 1 {
                await finish(files[0])
            } else {
                fileChoices = files
                showFilePicker = true
            }
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func finish(_ file: AssrtFile) async {
        downloading = true
        do {
            let local = try await AssrtClient.shared.download(file)
            downloading = false
            onLoaded(local)
            dismiss()
        } catch {
            downloading = false
            errorText = "下载失败：\(error.localizedDescription)"
        }
    }
}
