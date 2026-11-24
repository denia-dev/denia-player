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

// MARK: - Search sheet

struct OnlineSubtitleSearchView: View {
    let onLoaded: (URL) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var results: [AssrtSearchResult] = []
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
                if searching {
                    HStack(spacing: 10) { ProgressView(); Text("搜索中…") }
                }
                if downloading {
                    HStack(spacing: 10) { ProgressView(); Text("下载中…") }
                }
                if let errorText {
                    Text(errorText).font(.footnote).foregroundStyle(.red)
                }
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
            }
            .navigationTitle("在线字幕（ASSRT）")
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
            results = try await AssrtClient.shared.search(query: trimmed)
            if results.isEmpty { errorText = "没搜到，换个关键词试试" }
        } catch {
            results = []
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        searching = false
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
