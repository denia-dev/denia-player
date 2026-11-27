import Foundation

/// Danmaku (bullet comments) served by the user's self-hosted
/// danmu_api deployment (LogVar danmu_api on his own Cloudflare
/// Worker, DanDanPlay-compatible). Like the MDBList ratings key, the
/// service address + token are NOT in the app and NOT a user setting:
/// they live in a tiny JSON on his cloud hosting
/// (my-modules /config/danmaku.json, {"base": "https://...workers.dev",
/// "token": "..."}), fetched once and cached. No config there = the
/// feature stays dormant.
enum DanmakuConfig {
    private static let configURL = URL(string: "https://my-modules.peimingliang8.workers.dev/config/danmaku.json")!
    private static let baseKey = "danmaku.serviceBase"
    private static let tokenKey = "danmaku.serviceToken"

    static func service() async -> (base: String, token: String)? {
        if let base = UserDefaults.standard.string(forKey: baseKey),
           let token = UserDefaults.standard.string(forKey: tokenKey),
           !base.isEmpty, !token.isEmpty {
            // Refresh in the background so a rotated address lands
            // without an app update; the cached one keeps working.
            Task { _ = await fetchFromCloud() }
            return (base, token)
        }
        return await fetchFromCloud()
    }

    private static func fetchFromCloud() async -> (base: String, token: String)? {
        guard let (data, _) = try? await URLSession.shared.data(from: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let base = object["base"] as? String, !base.isEmpty,
              let token = object["token"] as? String, !token.isEmpty
        else { return nil }
        UserDefaults.standard.set(base, forKey: baseKey)
        UserDefaults.standard.set(token, forKey: tokenKey)
        return (base, token)
    }
}

struct DanmakuComment {
    var time: Double
    var mode: Int   // DanDanPlay modes: 1 scroll, 4 bottom, 5 top
    var color: Int  // decimal RGB
    var text: String
}

enum DanmakuService {
    /// Full pipeline: match the title against the danmaku service,
    /// download the episode's comments and render them into a local
    /// ASS file the player loads as an external subtitle track.
    /// Candidate names are tried in order (a remembered manual pick
    /// first, then the real file name, then constructed names), so a
    /// garbage file name no longer sinks an otherwise matchable show.
    /// Returns nil when no candidate produces comments.
    static func assFile(fileNames: [String], durationSeconds: Double) async -> URL? {
        guard let service = await DanmakuConfig.service() else { return nil }
        for name in fileNames where !name.isEmpty {
            if let url = await assFile(service: service, fileName: name, durationSeconds: durationSeconds) {
                return url
            }
        }
        return nil
    }

    /// Raw comments for the native danmaku overlay (v1.59): same
    /// candidate-name matching as assFile, but returns the parsed
    /// comments instead of an ASS file. The ASS route was dropped
    /// because the player's subtitle pipeline kept flattening the
    /// authored \move animation into stacked plain-text lines (his
    /// reports on v1.57 and v1.58); the overlay draws the comments
    /// itself on the player's clock, which no subtitle setting can
    /// flatten.
    static func comments(fileNames: [String], durationSeconds: Double) async -> [DanmakuComment]? {
        guard let service = await DanmakuConfig.service() else { return nil }
        for name in fileNames where !name.isEmpty {
            guard let matched = await match(service: service, fileName: name, durationSeconds: durationSeconds)
            else { continue }
            if let list = await comments(service: service, episodeID: matched.episodeID, sourceURL: matched.url),
               !list.isEmpty {
                return list
            }
        }
        return nil
    }

    private static func assFile(service: (base: String, token: String), fileName: String, durationSeconds: Double) async -> URL? {
        guard let matched = await match(service: service, fileName: fileName, durationSeconds: durationSeconds) else { return nil }
        let episodeID = matched.episodeID
        let fontSize = Prefs.danmakuFontSize
        let scroll = Prefs.danmakuScrollSeconds
        let dir = cacheDirectory()
        let assURL = dir.appendingPathComponent("dm-\(episodeID)-\(fontSize)-\(Int(scroll * 10)).ass")
        if FileManager.default.fileExists(atPath: assURL.path) { return assURL }
        guard let comments = await comments(service: service, episodeID: episodeID, sourceURL: matched.url), !comments.isEmpty else { return nil }
        let ass = DanmakuASS.convert(comments: comments, fontSize: Double(fontSize), scrollDuration: scroll)
        guard let data = ass.data(using: .utf8) else { return nil }
        try? data.write(to: assURL, options: .atomic)
        return assURL
    }

    private static func cacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("danmaku", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Remembered matches keyed by the exact query file name, so
    /// reopening an episode skips the match round-trip. The match's
    /// source page URL is remembered alongside the episode ID: on
    /// Cloudflare Workers the service's ID -> URL table lives in
    /// per-isolate memory and is usually gone by the time the
    /// comment request lands, so comments are fetched through the
    /// stateless /comment?url= form instead (verified live
    /// 2026-11-27: ID form 404s, URL form returns full comments).
    private static func match(service: (base: String, token: String), fileName: String, durationSeconds: Double) async -> (episodeID: Int, url: String?)? {
        let idKey = "danmaku.match.\(fileName)"
        let urlKey = "danmaku.matchurl.\(fileName)"
        if let saved = UserDefaults.standard.object(forKey: idKey) as? Int, saved > 0,
           let savedURL = UserDefaults.standard.string(forKey: urlKey), !savedURL.isEmpty {
            return (saved, savedURL)
        }
        guard let url = URL(string: "\(service.base)/\(service.token)/api/v2/match") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "fileName": fileName,
            "fileHash": "",
            "fileSize": 0,
            "videoDuration": Int(durationSeconds.rounded()),
            "matchMode": "hashAndFileName"
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let matches = object["matches"] as? [[String: Any]],
              let first = matches.first,
              let episodeID = (first["episodeId"] as? NSNumber)?.intValue, episodeID > 0
        else { return nil }
        let sourceURL = first["url"] as? String
        UserDefaults.standard.set(episodeID, forKey: idKey)
        if let sourceURL, !sourceURL.isEmpty {
            UserDefaults.standard.set(sourceURL, forKey: urlKey)
        }
        return (episodeID, sourceURL)
    }

    private static func comments(service: (base: String, token: String), episodeID: Int, sourceURL: String?) async -> [DanmakuComment]? {
        let dir = cacheDirectory()
        let rawURL = dir.appendingPathComponent("dm-\(episodeID).json")
        let data: Data
        if let cached = try? Data(contentsOf: rawURL) {
            data = cached
        } else {
            let endpoint: URL?
            if let sourceURL, sourceURL.hasPrefix("http") {
                var components = URLComponents(string: "\(service.base)/\(service.token)/api/v2/comment")
                components?.queryItems = [URLQueryItem(name: "url", value: sourceURL)]
                endpoint = components?.url
            } else {
                endpoint = URL(string: "\(service.base)/\(service.token)/api/v2/comment/\(episodeID)?format=json")
            }
            guard let url = endpoint,
                  let (fetched, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200
            else { return nil }
            try? fetched.write(to: rawURL, options: .atomic)
            data = fetched
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["comments"] as? [[String: Any]]
        else { return nil }
        var out: [DanmakuComment] = []
        out.reserveCapacity(entries.count)
        for entry in entries {
            guard let p = entry["p"] as? String, let m = entry["m"] as? String else { continue }
            let parts = p.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 3,
                  let time = Double(String(parts[0])),
                  let mode = Int(String(parts[1])),
                  let color = Int(String(parts[2]))
            else { continue }
            let text = m.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { continue }
            out.append(DanmakuComment(time: time, mode: mode, color: color, text: text))
        }
        return out
    }
}

/// DanDanPlay comments -> ASS, in the spirit of danmaku2ass: scroll
/// comments get a track whose previous occupant's tail must be fully
/// on screen (plus a no-rear-end rule for wider, faster followers),
/// top/bottom comments stack in fixed rows for a few seconds. The
/// ASS rides the player's secondary subtitle slot, so pause, seek
/// and rate changes stay in sync for free.
enum DanmakuASS {
    private static let playX = 1280
    private static let playY = 720

    static func convert(comments: [DanmakuComment], fontSize: Double, scrollDuration: Double) -> String {
        var list = comments.sorted { $0.time < $1.time }
        // libass slows down with very large event counts and dense
        // episodes can carry 10k+ comments; even sampling keeps the
        // feel while bounding render cost.
        let cap = 3000
        if list.count > cap {
            let stride = Double(list.count) / Double(cap)
            var sampled: [DanmakuComment] = []
            sampled.reserveCapacity(cap)
            var index = 0.0
            while Int(index) < list.count {
                sampled.append(list[Int(index)])
                index += stride
            }
            list = sampled
        }

        let rowHeight = fontSize * 1.25
        let scrollRows = max(1, Int(Double(playY) * 0.85 / rowHeight))
        let fixedRows = 6
        let fixedDuration = 4.5
        var lastScroll = Array(repeating: (start: -1_000_000.0, width: 0.0), count: scrollRows)
        var lastTop = Array(repeating: -1_000_000.0, count: fixedRows)
        var lastBottom = Array(repeating: -1_000_000.0, count: fixedRows)

        var events: [String] = []
        events.reserveCapacity(list.count)
        for comment in list {
            let width = textWidth(comment.text, fontSize: fontSize)
            let color = colorTag(comment.color)
            let body = escape(comment.text)
            switch comment.mode {
            case 5:
                var placed: Int?
                for row in 0..<fixedRows where comment.time >= lastTop[row] + fixedDuration {
                    placed = row
                    break
                }
                guard let row = placed else { continue }
                lastTop[row] = comment.time
                let y = Int(Double(row) * rowHeight)
                events.append(event(start: comment.time, end: comment.time + fixedDuration,
                                    text: "{\\pos(\(playX / 2),\(y))\\an8\(color)}\(body)"))
            case 4:
                var placed: Int?
                for row in 0..<fixedRows where comment.time >= lastBottom[row] + fixedDuration {
                    placed = row
                    break
                }
                guard let row = placed else { continue }
                lastBottom[row] = comment.time
                let y = playY - Int(Double(row) * rowHeight)
                events.append(event(start: comment.time, end: comment.time + fixedDuration,
                                    text: "{\\pos(\(playX / 2),\(y))\\an2\(color)}\(body)"))
            default:
                var placed: Int?
                for row in 0..<scrollRows {
                    let last = lastScroll[row]
                    // The previous comment's tail must be fully on
                    // screen before the next head enters.
                    let tailIn = last.start + scrollDuration * last.width / (Double(playX) + last.width)
                    guard comment.time >= tailIn else { continue }
                    // A wider comment moves faster; it must not
                    // rear-end the previous one before that leaves.
                    if width > last.width {
                        let safe = last.start + scrollDuration * (last.width + width) / (Double(playX) + last.width)
                        guard comment.time >= safe else { continue }
                    }
                    placed = row
                    break
                }
                guard let row = placed else { continue }
                lastScroll[row] = (comment.time, width)
                let y = Int(Double(row) * rowHeight)
                events.append(event(start: comment.time, end: comment.time + scrollDuration,
                                    text: "{\\move(\(playX),\(y),\(-Int(width.rounded())),\(y))\(color)}\(body)"))
            }
        }

        var out = """
        [Script Info]
        Title: Danmaku
        ScriptType: v4.00+
        PlayResX: \(playX)
        PlayResY: \(playY)
        WrapStyle: 2
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Danmaku,PingFang SC,\(Int(fontSize)),&H00FFFFFF,&H00FFFFFF,&H80000000,&H00000000,0,0,0,0,100,100,0,0,1,2,0,7,0,0,0,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        out += events.joined(separator: "\n")
        out += "\n"
        return out
    }

    private static func event(start: Double, end: Double, text: String) -> String {
        "Dialogue: 0,\(timestamp(start)),\(timestamp(end)),Danmaku,,0,0,0,,\(text)"
    }

    private static func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int((seconds * 100).rounded()))
        let cs = total % 100
        let s = (total / 100) % 60
        let m = (total / 6000) % 60
        let h = total / 360000
        return String(format: "%d:%02d:%02d.%02d", h, m, s, cs)
    }

    /// Rough advance-width estimate in font-size units: full width
    /// for CJK / fullwidth forms, ~0.55 for ASCII, 0.8 otherwise.
    static func textWidth(_ text: String, fontSize: Double) -> Double {
        var units = 0.0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if v < 0x80 {
                units += 0.55
            } else if (0x2E80...0x9FFF).contains(v) || (0xF900...0xFAFF).contains(v)
                        || (0xFF00...0xFF60).contains(v) || (0x20000...0x2FA1F).contains(v) {
                units += 1.0
            } else {
                units += 0.8
            }
        }
        return units * fontSize
    }

    /// ASS colours are BGR; white is the style default and needs no
    /// override. Returned without braces, for embedding in an
    /// existing override block.
    private static func colorTag(_ color: Int) -> String {
        if color <= 0 || color == 0xFFFFFF { return "" }
        let r = (color >> 16) & 0xFF
        let g = (color >> 8) & 0xFF
        let b = color & 0xFF
        return String(format: "\\c&H%02X%02X%02X&", b, g, r)
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "\\N")
    }
}

// MARK: - Manual search

struct DanmakuEpisodeOption {
    var episodeId: Int
    var title: String
    var number: Int
}

struct DanmakuAnimeOption {
    var animeId: Int
    /// Cleaned display/match title (year, 【tags】 and "from X" removed).
    var title: String
    var sourceName: String
    var episodes: [DanmakuEpisodeOption]
}

extension DanmakuService {

    /// One stateless call that returns candidate anime with their
    /// full episode lists (the service resolves episodes inside the
    /// same request, which is the only search flow that survives
    /// Cloudflare Workers' per-request isolates).
    static func search(keyword: String) async -> [DanmakuAnimeOption] {
        guard let service = await DanmakuConfig.service() else { return [] }
        var components = URLComponents(string: "\(service.base)/\(service.token)/api/v2/search/episodes")
        components?.queryItems = [URLQueryItem(name: "anime", value: keyword)]
        guard let url = components?.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let animes = root["animes"] as? [[String: Any]] else { return [] }
        return animes.compactMap { anime in
            guard let animeId = (anime["animeId"] as? NSNumber)?.intValue,
                  let rawTitle = anime["animeTitle"] as? String else { return nil }
            let episodes = (anime["episodes"] as? [[String: Any]] ?? []).enumerated().compactMap { index, ep -> DanmakuEpisodeOption? in
                guard let episodeId = (ep["episodeId"] as? NSNumber)?.intValue,
                      let title = ep["episodeTitle"] as? String else { return nil }
                return DanmakuEpisodeOption(episodeId: episodeId, title: title,
                                            number: episodeNumber(from: title) ?? index + 1)
            }
            guard !episodes.isEmpty else { return nil }
            return DanmakuAnimeOption(animeId: animeId, title: cleanTitle(rawTitle),
                                      sourceName: sourceDisplayName(rawTitle), episodes: episodes)
        }
    }

    private static func episodeNumber(from title: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: "第\\s*(\\d+)\\s*[集话話回]"),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return Int(title[range])
    }

    /// "上伊那牡丹，酒醉身姿似百合花般（2026）【动画】from renren" →
    /// "上伊那牡丹，酒醉身姿似百合花般" — the form the match
    /// endpoint recognises.
    static func cleanTitle(_ raw: String) -> String {
        var title = raw
        if let range = title.range(of: "from ", options: .caseInsensitive) {
            title = String(title[..<range.lowerBound])
        }
        title = title.replacingOccurrences(of: "【[^】]*】", with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: "[(（]\\s*(19|20)\\d{2}\\s*[)）]", with: "", options: .regularExpression)
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sourceDisplayName(_ rawTitle: String) -> String {
        guard let range = rawTitle.range(of: "from ", options: .caseInsensitive) else { return "弹幕库" }
        let key = rawTitle[range.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        let names = ["renren": "人人", "dandan": "弹弹", "bahamut": "巴哈姆特",
                     "bilibili": "哔哩哔哩", "tencent": "腾讯", "youku": "优酷",
                     "iqiyi": "爱奇艺", "migu": "咪咕", "imgo": "芒果TV",
                     "sohu": "搜狐", "leshi": "乐视", "xigua": "西瓜",
                     "douban": "豆瓣", "hanjutv": "韩剧TV", "360": "360"]
        return names[key] ?? key
    }
}

/// One comment placed for the native overlay: which track row it
/// rides and how wide it is in the virtual 1280x720 space the ASS
/// converter used, so the collision rules carry over unchanged.
struct DanmakuPlaced {
    enum Kind { case scroll, top, bottom }
    var index: Int   // position in the laid-out array; unique view identity
    var time: Double
    var end: Double
    var kind: Kind
    var row: Int
    var width: Double   // virtual units (1280-wide space)
    var color: Int
    var text: String
}

/// Track allocation for the native overlay - the same rules as
/// DanmakuASS.convert (a scroll row's previous tail must be fully
/// on screen, wider followers must not rear-end, fixed comments
/// stack in a few rows), minus the ASS serialisation.
enum DanmakuLayout {
    static let playX = 1280.0
    static let playY = 720.0
    static let fixedDuration = 4.5

    static func build(comments: [DanmakuComment], fontSize: Double, scrollDuration: Double, scrollRows: Int) -> [DanmakuPlaced] {
        var list = comments.sorted { $0.time < $1.time }
        let cap = 3000
        if list.count > cap {
            let stride = Double(list.count) / Double(cap)
            var sampled: [DanmakuComment] = []
            sampled.reserveCapacity(cap)
            var index = 0.0
            while Int(index) < list.count {
                sampled.append(list[Int(index)])
                index += stride
            }
            list = sampled
        }

        let scrollRows = max(1, scrollRows)
        // Fixed comments stay inside the chosen area as well: the
        // top stack shrinks with it, and bottom-fixed comments get
        // the same cap counted from the bottom edge.
        let fixedRows = min(6, scrollRows)
        var lastScroll = Array(repeating: (start: -1_000_000.0, width: 0.0), count: scrollRows)
        var lastTop = Array(repeating: -1_000_000.0, count: fixedRows)
        var lastBottom = Array(repeating: -1_000_000.0, count: fixedRows)

        var placed: [DanmakuPlaced] = []
        placed.reserveCapacity(list.count)
        for comment in list {
            let width = DanmakuASS.textWidth(comment.text, fontSize: fontSize)
            switch comment.mode {
            case 5:
                guard let row = (0..<fixedRows).first(where: { comment.time >= lastTop[$0] + fixedDuration })
                else { continue }
                lastTop[row] = comment.time
                placed.append(DanmakuPlaced(index: placed.count, time: comment.time, end: comment.time + fixedDuration,
                                            kind: .top, row: row, width: width,
                                            color: comment.color, text: comment.text))
            case 4:
                guard let row = (0..<fixedRows).first(where: { comment.time >= lastBottom[$0] + fixedDuration })
                else { continue }
                lastBottom[row] = comment.time
                placed.append(DanmakuPlaced(index: placed.count, time: comment.time, end: comment.time + fixedDuration,
                                            kind: .bottom, row: row, width: width,
                                            color: comment.color, text: comment.text))
            default:
                var row: Int?
                for candidate in 0..<scrollRows {
                    let last = lastScroll[candidate]
                    let tailIn = last.start + scrollDuration * last.width / (playX + last.width)
                    guard comment.time >= tailIn else { continue }
                    if width > last.width {
                        let safe = last.start + scrollDuration * (last.width + width) / (playX + last.width)
                        guard comment.time >= safe else { continue }
                    }
                    row = candidate
                    break
                }
                guard let row else { continue }
                lastScroll[row] = (comment.time, width)
                placed.append(DanmakuPlaced(index: placed.count, time: comment.time, end: comment.time + scrollDuration,
                                            kind: .scroll, row: row, width: width,
                                            color: comment.color, text: comment.text))
            }
        }
        return placed
    }
}
