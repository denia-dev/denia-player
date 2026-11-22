import Foundation

// MARK: - Server configuration (persisted locally)

struct ServerConfig: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    /// One or more base URLs (lines) for the same server, tried in order.
    var baseURLs: [String]
    var activeLine: Int = 0
    var username: String = ""
    var userID: String = ""
    var accessToken: String = ""

    var baseURL: String {
        guard !baseURLs.isEmpty else { return "" }
        return baseURLs[min(activeLine, baseURLs.count - 1)]
    }
    var isLoggedIn: Bool { !accessToken.isEmpty && !userID.isEmpty }
}

// MARK: - Emby API models

struct EmbyAuthResponse: Decodable {
    struct User: Decodable { let Id: String; let Name: String }
    let User: User
    let AccessToken: String
}

struct EmbyItemsResponse: Decodable {
    let Items: [EmbyItem]
    let TotalRecordCount: Int?
}

struct EmbyItem: Decodable, Identifiable {
    let Id: String
    let Name: String
    let type: String

    enum CodingKeys: String, CodingKey {
        case Id, Name
        case type = "Type"
        case CollectionType, SeriesName, SeriesId, SeasonId, IndexNumber, ParentIndexNumber
        case Overview, ProductionYear, RunTimeTicks, ChildCount, ImageTags, BackdropImageTags
        case UserData, MediaSources
    }

    var id: String { Id }
    let CollectionType: String?
    let SeriesName: String?
    let SeriesId: String?
    let SeasonId: String?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let Overview: String?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let ChildCount: Int?
    let ImageTags: [String: String]?
    let BackdropImageTags: [String]?
    let UserData: EmbyUserData?
    let MediaSources: [EmbyMediaSource]?

    var isPlayable: Bool { type == "Movie" || type == "Episode" || type == "Video" }
    var resumeSeconds: Double {
        guard let ticks = UserData?.PlaybackPositionTicks, ticks > 0 else { return 0 }
        return Double(ticks) / 10_000_000
    }
    var durationSeconds: Double {
        guard let ticks = RunTimeTicks, ticks > 0 else { return 0 }
        return Double(ticks) / 10_000_000
    }
    var episodeLabel: String? {
        guard type == "Episode" else { return nil }
        let s = ParentIndexNumber ?? 0
        let e = IndexNumber ?? 0
        return "S\(s) E\(e)"
    }
}

struct EmbyUserData: Decodable {
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let Played: Bool?
    let IsFavorite: Bool?
}

struct EmbyMediaSource: Decodable, Identifiable {
    let Id: String
    var id: String { Id }
    let Name: String?
    let Container: String?
    let Path: String?
    let Size: Int64?
    let Bitrate: Int?
    let SupportsDirectPlay: Bool?
    let SupportsDirectStream: Bool?
    let SupportsTranscoding: Bool?
    let TranscodingUrl: String?
    let DirectStreamUrl: String?
    let MediaStreams: [EmbyMediaStream]?
}

struct EmbyMediaStream: Decodable {
    let Index: Int
    let type: String // Video | Audio | Subtitle | Data

    enum CodingKeys: String, CodingKey {
        case Index
        case type = "Type"
        case Codec, Language, DisplayTitle, IsDefault, IsExternal, IsTextSubtitleStream, DeliveryUrl
    }
    let Codec: String?
    let Language: String?
    let DisplayTitle: String?
    let IsDefault: Bool?
    let IsExternal: Bool?
    let IsTextSubtitleStream: Bool?
    let DeliveryUrl: String?
}

struct EmbyPlaybackInfo: Decodable {
    let MediaSources: [EmbyMediaSource]
    let PlaySessionId: String?
}
