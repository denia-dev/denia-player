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
    /// Returns nil when any step has no result.
    static func assFile(fileName: String, durationSeconds: Double) async -> URL? {
        guard let service = await DanmakuConfig.service() else { return nil }
        guard let episodeID = await match(service: service, fileName: fileName, durationSeconds: durationSeconds) else { return nil }
        let fontSize = Prefs.danmakuFontSize
        let scroll = Prefs.danmakuScrollSeconds
        let dir = cacheDirectory()
        let assURL = dir.appendingPathComponent("dm-\(episodeID)-\(fontSize)-\(Int(scroll * 10)).ass")
        if FileManager.default.fileExists(atPath: assURL.path) { return assURL }
        guard let comments = await comments(service: service, episodeID: episodeID), !comments.isEmpty else { return nil }
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
    /// reopening an episode skips the match round-trip.
    private static func match(service: (base: String, token: String), fileName: String, durationSeconds: Double) async -> Int? {
        let defaultsKey = "danmaku.match.\(fileName)"
        if let saved = UserDefaults.standard.object(forKey: defaultsKey) as? Int, saved > 0 { return saved }
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
        UserDefaults.standard.set(episodeID, forKey: defaultsKey)
        return episodeID
    }

    private static func comments(service: (base: String, token: String), episodeID: Int) async -> [DanmakuComment]? {
        let dir = cacheDirectory()
        let rawURL = dir.appendingPathComponent("dm-\(episodeID).json")
        let data: Data
        if let cached = try? Data(contentsOf: rawURL) {
            data = cached
        } else {
            guard let url = URL(string: "\(service.base)/\(service.token)/api/v2/comment/\(episodeID)?format=json"),
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
    private static func textWidth(_ text: String, fontSize: Double) -> Double {
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
