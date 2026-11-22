import Foundation

/// Emby REST client. Playback is direct-play only by design: the device
/// decodes the original file (mpv), the server is never asked to transcode.
struct EmbyClient {
    let server: ServerConfig

    enum ClientError: LocalizedError {
        case badURL, http(Int), empty, notLoggedIn
        var errorDescription: String? {
            switch self {
            case .badURL: return "服务器地址无效"
            case .http(let code): return "服务器返回 HTTP \(code)"
            case .empty: return "服务器未返回数据"
            case .notLoggedIn: return "尚未登录"
            }
        }
    }

    static var deviceID: String {
        let key = "embyplayer.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: key)
        return fresh
    }

    private var authHeaderValue: String {
        "MediaBrowser Client=\"EmbyPlayer\", Device=\"iPhone\", DeviceId=\"\(Self.deviceID)\", Version=\"1.0\""
    }

    // MARK: - plumbing

    private func makeRequest(path: String, method: String = "GET",
                             query: [URLQueryItem] = [], body: Data? = nil,
                             authorized: Bool = true) throws -> URLRequest {
        guard var components = URLComponents(string: server.baseURL + path) else { throw ClientError.badURL }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.badURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(authHeaderValue, forHTTPHeaderField: "X-Emby-Authorization")
        if authorized, !server.accessToken.isEmpty {
            request.setValue(server.accessToken, forHTTPHeaderField: "X-Emby-Token")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendVoid(_ request: URLRequest) async throws {
        let (_, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
    }

    private func jsonBody(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - auth

    /// Authenticates against one base URL. Returns a filled-in config copy.
    static func authenticate(baseURL: String, name: String, username: String, password: String) async throws -> ServerConfig {
        var probe = ServerConfig(id: UUID().uuidString, name: name, baseURLs: [baseURL])
        probe.baseURLs = [baseURL]
        let client = EmbyClient(server: probe)
        let request = try client.makeRequest(
            path: "/Users/AuthenticateByName", method: "POST",
            body: client.jsonBody(["Username": username, "Pw": password]),
            authorized: false)
        let auth: EmbyAuthResponse = try await client.send(request)
        probe.username = username
        probe.userID = auth.User.Id
        probe.accessToken = auth.AccessToken
        if probe.name.isEmpty { probe.name = auth.User.Name }
        return probe
    }

    // MARK: - library

    func libraries() async throws -> [EmbyItem] {
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Views"))
        return response.Items
    }

    func resumeItems() async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "MediaTypes", value: "Video"),
            URLQueryItem(name: "Limit", value: "20"),
            URLQueryItem(name: "Fields", value: "Overview,MediaSources"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items/Resume", query: query))
        return response.Items
    }

    func children(parentID: String) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        return response.Items
    }

    func item(id: String) async throws -> EmbyItem {
        try await send(makeRequest(path: "/Users/\(server.userID)/Items/\(id)"))
    }

    func seasons(seriesID: String) async throws -> [EmbyItem] {
        let query = [URLQueryItem(name: "UserId", value: server.userID)]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Shows/\(seriesID)/Seasons", query: query))
        return response.Items
    }

    func episodes(seriesID: String, seasonID: String) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "SeasonId", value: seasonID),
            URLQueryItem(name: "UserId", value: server.userID),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Shows/\(seriesID)/Episodes", query: query))
        return response.Items
    }

    func search(term: String) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "40"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        return response.Items
    }

    // MARK: - images

    func imageURL(itemID: String, kind: String = "Primary", maxHeight: Int = 640) -> URL? {
        var components = URLComponents(string: server.baseURL + "/Items/\(itemID)/Images/\(kind)")
        components?.queryItems = [
            URLQueryItem(name: "maxHeight", value: String(maxHeight)),
            URLQueryItem(name: "api_key", value: server.accessToken),
        ]
        return components?.url
    }

    // MARK: - playback (direct play only)

    /// Device profile that declares everything the phone can decode locally,
    /// so the server offers the original file and never a transcode.
    private var directPlayProfile: [String: Any] {
        [
            "Name": "EmbyPlayer mpv",
            "MaxStreamingBitrate": 200_000_000,
            "DirectPlayProfiles": [
                ["Type": "Video",
                 "Container": "mkv,mp4,m4v,mov,avi,ts,m2ts,webm,flv,wmv,mpg,mpeg",
                 "VideoCodec": "hevc,h264,vp9,av1,mpeg4,mpeg2video,vc1,msmpeg4",
                 "AudioCodec": "flac,aac,ac3,eac3,dts,dtshd,truehd,mp3,mp2,opus,vorbis,pcm_s16le,pcm_s24le,alac"],
                ["Type": "Audio", "Container": "flac,mp3,aac,m4a,ogg,opus,wav", "AudioCodec": "flac,mp3,aac,opus,vorbis"],
            ],
            "TranscodingProfiles": [] as [[String: Any]],
            "CodecProfiles": [] as [[String: Any]],
            "SubtitleProfiles": [
                ["Format": "ass", "Method": "Embed"], ["Format": "ssa", "Method": "Embed"],
                ["Format": "srt", "Method": "Embed"], ["Format": "srt", "Method": "External"],
                ["Format": "vtt", "Method": "Embed"], ["Format": "vtt", "Method": "External"],
                ["Format": "pgs", "Method": "Embed"], ["Format": "sup", "Method": "Embed"],
            ],
        ]
    }

    func playbackInfo(itemID: String, startSeconds: Double) async throws -> EmbyPlaybackInfo {
        let body: [String: Any] = [
            "UserId": server.userID,
            "IsPlayback": true,
            "AutoOpenLiveStream": true,
            "StartTimeTicks": Int64(startSeconds * 10_000_000),
            "DeviceProfile": directPlayProfile,
            "MaxStreamingBitrate": 200_000_000,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": false,
        ]
        let request = try makeRequest(path: "/Items/\(itemID)/PlaybackInfo", method: "POST", body: jsonBody(body))
        return try await send(request)
    }

    /// Static original-file URL: the server serves the file bytes untouched
    /// (range requests supported); mpv demuxes/decodes locally and reads the
    /// embedded ASS/fonts itself.
    func directStreamURL(itemID: String, source: EmbyMediaSource, sessionID: String?) -> URL? {
        let ext = (source.Container ?? "mkv").lowercased()
        var components = URLComponents(string: server.baseURL + "/Videos/\(itemID)/stream.\(ext)")
        var query = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "MediaSourceId", value: source.Id),
            URLQueryItem(name: "api_key", value: server.accessToken),
        ]
        if let sessionID { query.append(URLQueryItem(name: "PlaySessionId", value: sessionID)) }
        components?.queryItems = query
        return components?.url
    }

    // MARK: - session reporting

    private func report(path: String, itemID: String, sourceID: String, sessionID: String?, positionSeconds: Double, isPaused: Bool? = nil) async {
        var body: [String: Any] = [
            "ItemId": itemID,
            "MediaSourceId": sourceID,
            "PositionTicks": Int64(positionSeconds * 10_000_000),
            "CanSeek": true,
        ]
        if let sessionID { body["PlaySessionId"] = sessionID }
        if let isPaused { body["IsPaused"] = isPaused }
        guard let request = try? makeRequest(path: path, method: "POST", body: jsonBody(body)) else { return }
        try? await sendVoid(request)
    }

    func reportStart(itemID: String, sourceID: String, sessionID: String?, positionSeconds: Double) async {
        await report(path: "/Sessions/Playing", itemID: itemID, sourceID: sourceID, sessionID: sessionID, positionSeconds: positionSeconds)
    }

    func reportProgress(itemID: String, sourceID: String, sessionID: String?, positionSeconds: Double, isPaused: Bool) async {
        await report(path: "/Sessions/Playing/Progress", itemID: itemID, sourceID: sourceID, sessionID: sessionID, positionSeconds: positionSeconds, isPaused: isPaused)
    }

    func reportStopped(itemID: String, sourceID: String, sessionID: String?, positionSeconds: Double) async {
        await report(path: "/Sessions/Playing/Stopped", itemID: itemID, sourceID: sourceID, sessionID: sessionID, positionSeconds: positionSeconds)
    }
}
