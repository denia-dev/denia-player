import Foundation
import SwiftUI
import Observation

/// Multi-source ratings (IMDb, Rotten Tomatoes critics + audience,
/// Letterboxd, Metacritic, Trakt) aggregated by MDBList - the same
/// trick SenPlayer uses for its six-score strip: the Emby server
/// itself only stores a TMDB score and an RT critics score, so the
/// rest are looked up by the item's IMDb/TMDB provider IDs.
///
/// The MDBList API key is NOT in the app and NOT a user setting: it
/// lives in a tiny JSON on the user's own cloud hosting
/// (my-modules /config/ratings.json, {"mdblist": "<key>"}), fetched
/// once and cached. No key there = the feature stays dormant and
/// the built-in two scores show as before.
struct ExternalRatings: Codable, Equatable {
    var imdb: Double?
    var tmdb: Double?
    var rtCritics: Double?
    var rtAudience: Double?
    /// Letterboxd native scale is 0-5; the strip displays it x2.
    var letterboxd: Double?
    var metacritic: Double?
    var trakt: Double?

    var isEmpty: Bool {
        imdb == nil && tmdb == nil && rtCritics == nil && rtAudience == nil
            && letterboxd == nil && metacritic == nil && trakt == nil
    }
}

enum MDBListClient {
    private static let configURL = URL(string: "https://my-modules.peimingliang8.workers.dev/config/ratings.json")!
    private static let keyDefaultsKey = "ratings.mdblistKey"

    static func apiKey() async -> String? {
        if let key = UserDefaults.standard.string(forKey: keyDefaultsKey), !key.isEmpty {
            // Refresh in the background so a rotated key lands
            // without an app update; the cached one keeps working.
            Task { _ = await fetchKeyFromCloud() }
            return key
        }
        return await fetchKeyFromCloud()
    }

    private static func fetchKeyFromCloud() async -> String? {
        guard let (data, _) = try? await URLSession.shared.data(from: configURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let key = object["mdblist"] as? String, !key.isEmpty
        else { return nil }
        UserDefaults.standard.set(key, forKey: keyDefaultsKey)
        return key
    }

    /// One lookup by IMDb ID (preferred) or TMDB ID. Response shape:
    /// {"ratings": [{"source": "imdb", "value": 7.1}, ...]} where
    /// value may be a number, a string, or null. Verified against
    /// the live API 2026-11-24: the paths are /imdb/{movie|show}/{id}
    /// and /tmdb/{movie|show}/{id} (a bare /imdb/{id} is rejected),
    /// the RT audience source is named "popcorn", and tmdb/trakt
    /// values arrive on a 0-100 scale (normalized in the strip).
    static func ratings(imdbID: String?, tmdbID: String?, type: String, apiKey: String) async -> ExternalRatings? {
        let segment = type == "Movie" ? "movie" : "show"
        var components: URLComponents?
        if let imdbID, !imdbID.isEmpty {
            components = URLComponents(string: "https://api.mdblist.com/imdb/\(segment)/\(imdbID)")
        } else if let tmdbID, !tmdbID.isEmpty {
            components = URLComponents(string: "https://api.mdblist.com/tmdb/\(segment)/\(tmdbID)")
        }
        guard var components else { return nil }
        components.queryItems = [URLQueryItem(name: "apikey", value: apiKey)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = object["ratings"] as? [[String: Any]]
        else { return nil }

        var result = ExternalRatings()
        for entry in entries {
            guard let source = entry["source"] as? String else { continue }
            let value: Double?
            if let number = entry["value"] as? NSNumber {
                value = number.doubleValue
            } else if let string = entry["value"] as? String {
                value = Double(string)
            } else {
                value = nil
            }
            guard let value else { continue }
            switch source {
            case "imdb": result.imdb = value
            case "tmdb": result.tmdb = value
            case "tomatoes": result.rtCritics = value
            case "popcorn", "tomatoesaudience": result.rtAudience = value
            case "letterboxd": result.letterboxd = value
            case "metacritic": result.metacritic = value
            case "trakt": result.trakt = value
            default: break
            }
        }
        return result.isEmpty ? nil : result
    }
}

/// Session + disk cache for external ratings, keyed by Emby item
/// ID. A lookup costs one MDBList request against a ~1000/day free
/// quota, so results persist for a week.
@MainActor
@Observable
final class RatingsStore {
    static let shared = RatingsStore()

    private(set) var byItemID: [String: ExternalRatings] = [:]
    /// Items whose lookup has COMPLETED (with or without results),
    /// so callers can tell "no data" apart from "not asked yet".
    private(set) var checked: Set<String> = []
    private var fetchedAt: [String: Date] = [:]
    private var inFlight: Set<String> = []

    private let diskKey = "ratings.cache.v1"
    private let ttl: TimeInterval = 7 * 24 * 3600

    private struct DiskEntry: Codable {
        var ratings: ExternalRatings
        var at: Date
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: diskKey),
           let disk = try? JSONDecoder().decode([String: DiskEntry].self, from: data) {
            for (id, entry) in disk where Date().timeIntervalSince(entry.at) < ttl {
                byItemID[id] = entry.ratings
                fetchedAt[id] = entry.at
            }
        }
    }

    func ensure(itemID: String, imdbID: String?, tmdbID: String?, type: String) {
        if inFlight.contains(itemID) { return }
        if let at = fetchedAt[itemID], Date().timeIntervalSince(at) < ttl { return }
        guard (imdbID?.isEmpty == false) || (tmdbID?.isEmpty == false) else { return }
        inFlight.insert(itemID)
        Task {
            defer { inFlight.remove(itemID) }
            guard let key = await MDBListClient.apiKey() else { return }
            let ratings = await MDBListClient.ratings(imdbID: imdbID, tmdbID: tmdbID, type: type, apiKey: key)
            checked.insert(itemID)
            guard let ratings else { return }
            byItemID[itemID] = ratings
            fetchedAt[itemID] = Date()
            persist()
        }
    }

    private func persist() {
        var out: [String: DiskEntry] = [:]
        for (id, ratings) in byItemID {
            if let at = fetchedAt[id] { out[id] = DiskEntry(ratings: ratings, at: at) }
        }
        if let data = try? JSONEncoder().encode(out) {
            UserDefaults.standard.set(data, forKey: diskKey)
        }
    }
}

/// The SenPlayer-style ratings strip: branded pills + values for
/// every source that has data. External values win; the server's
/// own community/critic scores fill TMDB / RT when MDBList has
/// nothing (or no key is configured).
struct RatingsStrip: View {
    let external: ExternalRatings?
    var fallbackCommunity: Double?
    var fallbackCritic: Double?
    var large = false

    /// MDBList reports tmdb/trakt on a 0-100 scale; the strip shows
    /// the familiar 0-10 form.
    private static func tenScale(_ value: Double) -> Double { value > 10 ? value / 10 : value }

    private var tmdb: Double? {
        if let value = external?.tmdb { return Self.tenScale(value) }
        return fallbackCommunity
    }
    private var rtCritics: Double? { external?.rtCritics ?? fallbackCritic }

    var hasContent: Bool {
        tmdb != nil || rtCritics != nil || external?.imdb != nil || external?.rtAudience != nil
            || external?.letterboxd != nil || external?.metacritic != nil || external?.trakt != nil
    }

    private var sourceCount: Int {
        [tmdb != nil, external?.imdb != nil, rtCritics != nil, external?.rtAudience != nil,
         external?.letterboxd != nil, external?.metacritic != nil, external?.trakt != nil]
            .filter { $0 }.count
    }

    /// Five or more sources cannot share one row at phone width:
    /// the row compresses until labels wrap letter-by-letter into
    /// vertical strips (his v1.09 home screenshot). Split into two
    /// centered rows instead - and every chip is fixedSize with
    /// lineLimit(1) so a chip can never wrap, whatever the width.
    var body: some View {
        if sourceCount > 4 {
            VStack(spacing: 6) {
                HStack(spacing: large ? 12 : 10) { firstGroup }
                HStack(spacing: large ? 12 : 10) { secondGroup }
            }
        } else {
            HStack(spacing: large ? 12 : 10) {
                firstGroup
                secondGroup
            }
        }
    }

    @ViewBuilder
    private var firstGroup: some View {
        if let tmdb {
            chip("TMDB", fill: AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.01, green: 0.71, blue: 0.89),
                         Color(red: 0.56, green: 0.81, blue: 0.63)],
                startPoint: .leading, endPoint: .trailing)), textColor: .white) {
                Text(String(format: "%.1f", tmdb))
            }
        }
        if let imdb = external?.imdb {
            chip("IMDb", fill: AnyShapeStyle(Color(red: 0.96, green: 0.77, blue: 0.09)), textColor: .black) {
                Text(String(format: "%.1f", imdb))
            }
        }
        if let rtCritics {
            chip("RT", fill: AnyShapeStyle(Color(red: 0.85, green: 0.2, blue: 0.15)), textColor: .white) {
                Text("\(Int(rtCritics.rounded()))%")
            }
        }
        if let audience = external?.rtAudience {
            chip("观众", fill: AnyShapeStyle(Color(red: 0.98, green: 0.55, blue: 0.1)), textColor: .white) {
                Text("\(Int(audience.rounded()))%")
            }
        }
    }

    @ViewBuilder
    private var secondGroup: some View {
        if let letterboxd = external?.letterboxd {
            chip("LB", fill: AnyShapeStyle(Color(red: 0.13, green: 0.13, blue: 0.14)), textColor: .white) {
                Text(String(format: "%.1f", letterboxd * 2))
            }
        }
        if let metacritic = external?.metacritic {
            chip("MC", fill: AnyShapeStyle(Color(red: 0.0, green: 0.65, blue: 0.35)), textColor: .white) {
                Text("\(Int(metacritic.rounded()))%")
            }
        }
        if let trakt = external?.trakt {
            chip("Trakt", fill: AnyShapeStyle(Color(red: 0.93, green: 0.11, blue: 0.14)), textColor: .white) {
                Text(String(format: "%.1f", Self.tenScale(trakt)))
            }
        }
    }

    private func chip<Value: View>(_ label: String, fill: AnyShapeStyle, textColor: Color,
                                   @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: large ? 9 : 8.5, weight: .black))
                .foregroundStyle(textColor)
                .lineLimit(1)
                .padding(.horizontal, large ? 6 : 5)
                .padding(.vertical, large ? 3 : 2.5)
                .background(fill, in: Capsule())
            value()
                .font(large ? .system(size: 13.5, weight: .bold) : .subheadline.weight(.semibold))
                .lineLimit(1)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
