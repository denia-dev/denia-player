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

    /// One automatic retry for transient connection drops (the free servers
    /// reset connections often enough that a single attempt is not reliable).
    private func dataWithRetry(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost, .notConnectedToInternet].contains(error.code) {
            try await Task.sleep(for: .milliseconds(800))
            return try await URLSession.shared.data(for: request)
        }
    }

    private func send<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await dataWithRetry(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func sendVoid(_ request: URLRequest) async throws {
        let (_, response) = try await dataWithRetry(request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ClientError.http(http.statusCode)
        }
    }

    private func jsonBody(_ object: [String: Any]) -> Data? {
        try? JSONSerialization.data(withJSONObject: object)
    }

    /// Only reads the server-generated index; never downloads or decodes the media.
    func seekArchive(itemID: String) async throws -> SeekBIF? {
        let limit = 24 * 1024 * 1024
        var req = try makeRequest(path: "/Videos/\(itemID)/index.bif",
                                  query: [URLQueryItem(name: "Width", value: "320")])
        req.timeoutInterval = 15
        req.networkServiceType = .background
        req.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
        let (url, response) = try await URLSession.shared.download(for: req)
        defer { try? FileManager.default.removeItem(at: url) }
        guard let http = response as? HTTPURLResponse, [200, 206].contains(http.statusCode),
              let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 72, size <= limit else { return nil }
        if http.statusCode == 206 {
            guard let range = http.value(forHTTPHeaderField: "Content-Range"),
                  range.lowercased() == "bytes 0-\(size - 1)/\(size)" else { return nil }
        }
        try Task.checkCancellation()
        return SeekBIF(try Data(contentsOf: url, options: .mappedIfSafe))
    }

    // MARK: - address normalization

    /// Turns whatever the user typed into candidate base URLs, best first.
    /// Accepts a bare domain ("emby.example.com"), a LAN address with port
    /// ("192.168.1.10:8096"), a full URL, and repairs common keyboard damage
    /// (full-width colon/slashes from the Chinese IME, missing "//").
    /// A bare domain defaults to https first; an IP or explicit port
    /// defaults to http first (typical LAN Emby).
    static func candidateBaseURLs(from raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "：", with: ":")
                   .replacingOccurrences(of: "／", with: "/")
                   .replacingOccurrences(of: " ", with: "")
        // Strip any scheme the user typed, however mangled ("http:host",
        // "https：//host", "http//host"), remembering an explicit http.
        var explicitHTTP = false
        let lowered = text.lowercased()
        if lowered.hasPrefix("http") {
            explicitHTTP = lowered.hasPrefix("http:") && !lowered.hasPrefix("https")
            if let range = text.range(of: "://") {
                text = String(text[range.upperBound...])
            } else if let colon = text.firstIndex(of: ":") {
                // "http:host" — but leave "host:8096" (starts with a digit
                // or has no letters before the colon that spell a scheme).
                let before = text[..<colon].lowercased()
                if before == "http" || before == "https" {
                    text = String(text[text.index(after: colon)...]).drop(while: { $0 == "/" }).description
                }
            }
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !text.isEmpty else { return [] }
        let hostPart = text.split(separator: "/").first.map(String.init) ?? text
        let looksLikeIP = hostPart.range(of: #"^\d{1,3}(\.\d{1,3}){3}"#, options: .regularExpression) != nil
        let hasPort = hostPart.contains(":")
        let https = "https://" + text
        let http = "http://" + text
        if explicitHTTP { return [http, https] }
        if looksLikeIP || hasPort { return [http, https] }
        return [https, http]
    }

    // MARK: - auth

    /// Authenticates against a raw user-typed address, trying each
    /// normalized candidate in order. Returns a filled-in config copy.
    static func authenticate(address: String, name: String, username: String, password: String) async throws -> ServerConfig {
        let candidates = candidateBaseURLs(from: address)
        guard !candidates.isEmpty else { throw ClientError.badURL }
        var lastError: Error = ClientError.badURL
        for baseURL in candidates {
            do {
                return try await authenticate(baseURL: baseURL, name: name, username: username, password: password)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

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

    /// One page of a library/collection's children. The plain children()
    /// call returns whatever the server's implicit cap allows (goemby
    /// truncates around 20), so browsable lists must page explicitly.
    func childrenPage(parentID: String, startIndex: Int, limit: Int) async throws -> EmbyItemsResponse {
        let query = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "SortOrder", value: "Ascending"),
            URLQueryItem(name: "Fields", value: "Overview"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
        ]
        return try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
    }

    func item(id: String) async throws -> EmbyItem {
        // People/Chapters/MediaSources are NOT in Emby's default field
        // set: without naming them here the detail response carries no
        // cast at all and the detail page's cast section never renders
        // (found on-device 2026-11-24 - the section existed since the
        // Sen rebuild but its data was never requested).
        let query = [
            URLQueryItem(name: "Fields", value: "Overview,Genres,People,Chapters,MediaSources,ProviderIds"),
        ]
        return try await send(makeRequest(path: "/Users/\(server.userID)/Items/\(id)", query: query))
    }

    /// Year/ratings/runtime for one item. goemby's LIST responses
    /// (/Items/Latest etc.) omit ProductionYear and CommunityRating
    /// even though the items have them - only the single-item
    /// response carries them - so the home hero hydrates its items
    /// through here (found on-device 2026-11-24: two list-sourced
    /// series in a row showed genres/overview but no year or rating).
    func itemMeta(id: String) async -> (year: Int?, community: Double?, critic: Double?, runTimeTicks: Int64?, imdbID: String?, tmdbID: String?)? {
        let query = [URLQueryItem(name: "Fields", value: "Overview,ProviderIds")]
        guard let item: EmbyItem = try? await send(makeRequest(path: "/Users/\(server.userID)/Items/\(id)", query: query)) else {
            return nil
        }
        return (item.ProductionYear, item.CommunityRating, item.CriticRating, item.RunTimeTicks,
                item.ProviderIds?["Imdb"], item.ProviderIds?["Tmdb"])
    }

    /// Latest additions inside one library, newest first, for the
    /// library tab's per-library poster rails.
    func latestInLibrary(parentID: String, limit: Int = 15) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Fields", value: "Overview,Genres"),
            URLQueryItem(name: "Limit", value: String(limit)),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        return response.Items
    }

    /// Total movie/series count under a library (recursive).
    func libraryItemCount(parentID: String) async -> Int? {
        let query = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "StartIndex", value: "0"),
            URLQueryItem(name: "Limit", value: "1"),
            URLQueryItem(name: "EnableTotalRecordCount", value: "true"),
        ]
        let response: EmbyItemsResponse? = try? await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        return response?.TotalRecordCount
    }

    func seasons(seriesID: String) async throws -> [EmbyItem] {
        let query = [URLQueryItem(name: "UserId", value: server.userID)]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Shows/\(seriesID)/Seasons", query: query))
        return response.Items
    }

    /// Intro/outro segments (the server's MediaSegments API, fed by
    /// the intro-skipper plugin or Emby's own chapter analysis).
    /// Servers without segment data answer 404 or an empty list -
    /// both read as "no segments", never as an error worth showing.
    func mediaSegments(itemID: String) async -> [MediaSegment] {
        guard let request = try? makeRequest(path: "/MediaSegments/\(itemID)", query: []) else { return [] }
        if let array: [MediaSegment] = try? await send(request) { return array }
        if let wrapped: MediaSegmentsResponse = try? await send(request) { return wrapped.Items }
        return []
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

    /// Items Emby rates as similar to the given one (same endpoint
    /// SenPlayer's detail page uses for its recommendation row).
    func similarItems(itemID: String) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "UserId", value: server.userID),
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,Genres"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Items/\(itemID)/Similar", query: query))
        return response.Items
    }

    /// Everything in the library featuring one person, newest first -
    /// backs the cast tap-through page.
    func itemsByPerson(personID: String) async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "PersonIds", value: personID),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "PremiereDate"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "60"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        return response.Items
    }

    /// Recently added movies/series for the home hero and the
    /// 最新添加 rail. The dedicated /Items/Latest endpoint answers an
    /// empty list (or errors) on some servers even for large
    /// libraries - which silently collapsed the home hero to the
    /// resume items - so fall back to the plain items query sorted
    /// by creation date, the same set through a door that works
    /// everywhere else in the app.
    func latestItems() async -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Fields", value: "Overview,Genres"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ]
        if let items: [EmbyItem] = try? await send(makeRequest(path: "/Users/\(server.userID)/Items/Latest", query: query)),
           !items.isEmpty {
            return items
        }
        let fallbackQuery = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "12"),
            URLQueryItem(name: "Fields", value: "Overview,Genres"),
            URLQueryItem(name: "EnableUserData", value: "true"),
        ]
        let response: EmbyItemsResponse? = try? await send(makeRequest(path: "/Users/\(server.userID)/Items", query: fallbackQuery))
        return response?.Items ?? []
    }

    /// The home hero's rotation pool: a mix instead of one
    /// "recently added" list (his 2026-11-24 verdict: 全是这些
    /// 没意思的电影）. A few newest, a few highest-rated, a few
    /// random - the random slice makes every launch a different
    /// batch. Round-robin interleaved and deduped, best-effort:
    /// any slice may come back empty without sinking the others.
    ///
    /// v1.47: the carousel only admits animation (heroItems
    /// filter), but the old pool sampled the WHOLE library, so on
    /// a mostly live-action server only ~4 animation titles ever
    /// survived the filter and the carousel sat stuck at 4 (his
    /// report). Three genre-targeted slices (Anime / Animation /
    /// 动画, newest + top-rated + random) now lead the merge so
    /// the filter has real candidates; the general slices stay
    /// as fallback.
    func heroPool() async -> [EmbyItem] {
        func slice(sortBy: String, limit: Int, genres: String? = nil) async -> [EmbyItem] {
            var query = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                URLQueryItem(name: "SortBy", value: sortBy),
                URLQueryItem(name: "SortOrder", value: "Descending"),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "Overview,Genres,ProviderIds,Tags"),
                URLQueryItem(name: "EnableUserData", value: "true"),
            ]
            if let genres {
                query.append(URLQueryItem(name: "Genres", value: genres))
            }
            let response: EmbyItemsResponse? = try? await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
            return response?.Items ?? []
        }
        async let animeNewest = slice(sortBy: "DateCreated", limit: 40, genres: "Anime,Animation,动画")
        async let animeTopRated = slice(sortBy: "CommunityRating", limit: 40, genres: "Anime,Animation,动画")
        async let animeRandom = slice(sortBy: "Random", limit: 40, genres: "Anime,Animation,动画")
        async let newest = slice(sortBy: "DateCreated", limit: 60)
        async let topRated = slice(sortBy: "CommunityRating", limit: 60)
        async let random = slice(sortBy: "Random", limit: 60)
        let slices = await [animeNewest, animeTopRated, animeRandom, newest, topRated, random]
        var merged: [EmbyItem] = []
        var seen = Set<String>()
        for index in 0..<60 {
            for sliceItems in slices where index < sliceItems.count {
                let item = sliceItems[index]
                if seen.insert(item.Id).inserted { merged.append(item) }
            }
        }
        return Array(merged.prefix(120))
    }

    func favoriteItems() async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "Filters", value: "IsFavorite"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode"),
            URLQueryItem(name: "Limit", value: "60"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        let items = response.Items
        // Servers happily mark individual episodes as favorites (some
        // clients cascade a series favorite down to its episodes), and
        // a favorites grid full of "Episode 294" cells is meaningless.
        // Roll every favorited episode up to its series, once.
        let seriesIDs = Array(Set(items.filter { $0.type == "Episode" }.compactMap { $0.SeriesId }))
        var seriesByID: [String: EmbyItem] = [:]
        if !seriesIDs.isEmpty {
            let seriesQuery = [
                URLQueryItem(name: "Ids", value: seriesIDs.joined(separator: ",")),
                URLQueryItem(name: "Fields", value: "Overview"),
            ]
            if let seriesResponse: EmbyItemsResponse = try? await send(makeRequest(path: "/Users/\(server.userID)/Items", query: seriesQuery)) {
                for series in seriesResponse.Items { seriesByID[series.Id] = series }
            }
        }
        var seen = Set<String>()
        var result: [EmbyItem] = []
        for item in items {
            if item.type == "Episode" {
                if let seriesID = item.SeriesId, let series = seriesByID[seriesID], seen.insert(seriesID).inserted {
                    result.append(series)
                }
            } else if seen.insert(item.Id).inserted {
                result.append(item)
            }
        }
        return result
    }

    func historyItems() async throws -> [EmbyItem] {
        let query = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsPlayed"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: "24"),
            URLQueryItem(name: "Fields", value: "Overview"),
        ]
        let response: EmbyItemsResponse = try await send(makeRequest(path: "/Users/\(server.userID)/Items", query: query))
        return response.Items
    }

    func setFavorite(itemID: String, _ favorite: Bool) async {
        let request = try? makeRequest(path: "/Users/\(server.userID)/FavoriteItems/\(itemID)",
                                       method: favorite ? "POST" : "DELETE")
        if let request { try? await sendVoid(request) }
    }

    func setPlayed(itemID: String, _ played: Bool) async {
        let request = try? makeRequest(path: "/Users/\(server.userID)/PlayedItems/\(itemID)",
                                       method: played ? "POST" : "DELETE")
        if let request { try? await sendVoid(request) }
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

    /// One entry of an item's backdrop set （艺术图）, by index. An item
    /// can carry several backdrops; the plain imageURL(kind: "Backdrop")
    /// only ever reaches index 0.
    func backdropURL(itemID: String, index: Int, maxHeight: Int = 720) -> URL? {
        var components = URLComponents(string: server.baseURL + "/Items/\(itemID)/Images/Backdrop/\(index)")
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
                ["Format": "pgs", "Method": "External"], ["Format": "sup", "Method": "External"],
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

    /// External subtitle files live outside the media container, so the
    /// static stream URL never contains them; the player must add them itself.
    func externalSubtitles(itemID: String, source: EmbyMediaSource) -> [(url: URL, title: String?, language: String?)] {
        guard let streams = source.MediaStreams else { return [] }
        return streams.compactMap { stream in
            // Sidecar files (IsExternal) and embedded text tracks the server
            // offers as a download (DeliveryUrl, e.g. mov_text extracted to
            // srt) both live outside the static stream bytes.
            guard stream.type == "Subtitle", stream.IsExternal == true || stream.DeliveryUrl != nil else { return nil }
            var url: URL?
            if let delivery = stream.DeliveryUrl {
                url = URL(string: server.baseURL + delivery)
            }
            if url == nil {
                let rawCodec = (stream.Codec ?? "srt").lowercased()
                let format = rawCodec.contains("pgs") ? "sup" : rawCodec
                url = URL(string: server.baseURL + "/Videos/\(itemID)/\(source.Id)/Subtitles/\(stream.Index)/Stream.\(format)")
            }
            guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
            var query = components.queryItems ?? []
            if !query.contains(where: { $0.name == "api_key" }) {
                query.append(URLQueryItem(name: "api_key", value: server.accessToken))
                components.queryItems = query
            }
            guard let finalURL = components.url else { return nil }
            return (finalURL, stream.DisplayTitle, stream.Language)
        }
    }

    /// Any subtitle track delivered as SRT text (the server converts
    /// embedded text tracks and sidecar files alike); AI translation
    /// fetches its source text from here.
    func subtitleStreamURL(itemID: String, source: EmbyMediaSource, streamIndex: Int) -> URL? {
        var components = URLComponents(string: server.baseURL + "/Videos/\(itemID)/\(source.Id)/Subtitles/\(streamIndex)/Stream.srt")
        components?.queryItems = [URLQueryItem(name: "api_key", value: server.accessToken)]
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


/// One intro/outro segment from the MediaSegments API (ticks are
/// 100ns units, as everywhere in Emby).
struct MediaSegment: Decodable {
    let kind: String
    let StartTicks: Int64
    let EndTicks: Int64

    enum CodingKeys: String, CodingKey {
        case kind = "Type"
        case StartTicks, EndTicks
    }

    var startSeconds: Double { Double(StartTicks) / 10_000_000 }
    var endSeconds: Double { Double(EndTicks) / 10_000_000 }
    var isIntro: Bool { kind.lowercased().contains("intro") }
    var isOutro: Bool { kind.lowercased().contains("outro") }
}

private struct MediaSegmentsResponse: Decodable {
    let Items: [MediaSegment]
}
