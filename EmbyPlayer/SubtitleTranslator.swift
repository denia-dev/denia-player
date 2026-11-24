import Foundation
import Security

// MARK: - Keychain (the translation API key never touches UserDefaults)

enum KeychainStore {
    private static let service = "com.denia.embyplayer"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if value.isEmpty {
            SecItemDelete(query as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let attributes: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            SecItemAdd(item as CFDictionary, nil)
        }
    }
}

// MARK: - SRT document

struct SRTDocument {
    struct Cue { var start: String; var end: String; var text: String }
    var cues: [Cue]

    static func parse(_ content: String) -> SRTDocument {
        let normalized = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.components(separatedBy: "\n")
            guard let tsIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { continue }
            let parts = lines[tsIndex].components(separatedBy: " --> ")
            guard parts.count == 2 else { continue }
            let textLines = Array(lines[(tsIndex + 1)...])
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            guard !textLines.isEmpty else { continue }
            var text = textLines.joined(separator: "\n")
            // Drop SSA override tags {...} that can survive ASS->SRT conversion.
            while let open = text.firstIndex(of: "{"),
                  let close = text[open...].firstIndex(of: "}") {
                text.removeSubrange(open...close)
            }
            let endToken = parts[1].trimmingCharacters(in: .whitespaces)
                .components(separatedBy: " ").first ?? parts[1]
            cues.append(Cue(start: parts[0].trimmingCharacters(in: .whitespaces),
                            end: endToken,
                            text: text))
        }
        return SRTDocument(cues: cues)
    }

    func serialized() -> String {
        cues.enumerated()
            .map { index, cue in "\(index + 1)\n\(cue.start) --> \(cue.end)\n\(cue.text)" }
            .joined(separator: "\n\n") + "\n"
    }
}

// MARK: - Translator

enum SubtitleTranslateError: LocalizedError {
    case noKey
    case emptySubtitles
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noKey:
            return "还没填 API Key：设置 → AI 字幕翻译"
        case .emptySubtitles:
            return "这条字幕没有取到文本（图片字幕无法翻译）"
        case .http(let code, let snippet):
            return "翻译接口返回 \(code)\(snippet.isEmpty ? "" : "：\(snippet)")"
        case .badResponse:
            return "翻译接口返回的格式不对"
        }
    }
}

/// Downloads a subtitle track as SRT from the Emby server, translates
/// it in numbered batches through an OpenAI-compatible chat API and
/// caches the result on disk per item/track/language.
final class SubtitleTranslator {
    static let shared = SubtitleTranslator()
    private init() {}

    private var cacheDir: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AITranslatedSubtitles", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cacheFile(itemID: String, streamIndex: Int) -> URL {
        cacheDir.appendingPathComponent("\(itemID)_\(streamIndex)_\(Prefs.aiTargetLang).srt")
    }

    func cachedFile(itemID: String, streamIndex: Int) -> URL? {
        let url = cacheFile(itemID: itemID, streamIndex: streamIndex)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func translate(itemID: String, streamIndex: Int, subtitleURL: URL, force: Bool,
                   progress: @escaping (Int, Int) -> Void) async throws -> URL {
        if !force, let cached = cachedFile(itemID: itemID, streamIndex: streamIndex) {
            return cached
        }
        guard let key = KeychainStore.get("aiTranslateKey"), !key.isEmpty else {
            throw SubtitleTranslateError.noKey
        }
        let (data, response) = try await URLSession.shared.data(from: subtitleURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SubtitleTranslateError.http(http.statusCode, "")
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw SubtitleTranslateError.emptySubtitles
        }
        var doc = SRTDocument.parse(text)
        guard !doc.cues.isEmpty else { throw SubtitleTranslateError.emptySubtitles }

        let batchSize = 40
        let batchCount = (doc.cues.count + batchSize - 1) / batchSize
        progress(0, batchCount)
        for batch in 0..<batchCount {
            let lower = batch * batchSize
            let upper = min(lower + batchSize, doc.cues.count)
            let translated = try await translateBatch(Array(doc.cues[lower..<upper]), key: key)
            for offset in 0..<(upper - lower) {
                if let t = translated[offset], !t.isEmpty {
                    doc.cues[lower + offset].text = t
                }
            }
            progress(batch + 1, batchCount)
        }
        let out = cacheFile(itemID: itemID, streamIndex: streamIndex)
        try doc.serialized().write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    /// One retry per batch; a cue the model drops keeps its original
    /// text rather than vanishing.
    private func translateBatch(_ cues: [SRTDocument.Cue], key: String) async throws -> [Int: String] {
        var lastError: Error?
        for _ in 0..<2 {
            do { return try await translateBatchOnce(cues, key: key) }
            catch { lastError = error }
        }
        throw lastError ?? SubtitleTranslateError.badResponse
    }

    private func translateBatchOnce(_ cues: [SRTDocument.Cue], key: String) async throws -> [Int: String] {
        var endpoint = Prefs.aiEndpoint.trimmingCharacters(in: .whitespaces)
        if !endpoint.hasSuffix("/chat/completions") {
            endpoint = endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"
        }
        guard let url = URL(string: endpoint) else { throw SubtitleTranslateError.badResponse }
        let source = cues.enumerated()
            .map { "[\($0.offset + 1)] \($0.element.text)" }
            .joined(separator: "\n")
        let system = "You are a professional subtitle translator. Translate every numbered subtitle block into \(Prefs.aiTargetName). Keep the [N] numbering exactly, output ONLY the translated blocks, preserve line breaks inside a block, and keep translations natural and concise for subtitles."
        let body: [String: Any] = [
            "model": Prefs.aiModel,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": source],
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw SubtitleTranslateError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SubtitleTranslateError.badResponse
        }
        var result: [Int: String] = [:]
        var current: Int?
        var buffer: [String] = []
        func flush() {
            if let current {
                result[current - 1] = buffer.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            buffer = []
        }
        for rawLine in content.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]"),
               let number = Int(trimmed[trimmed.index(after: trimmed.startIndex)..<close]) {
                flush()
                current = number
                buffer = [String(trimmed[trimmed.index(after: close)...])
                    .trimmingCharacters(in: .whitespaces)]
            } else if current != nil {
                buffer.append(rawLine)
            }
        }
        flush()
        return result
    }
}
