import ActivityKit
import Foundation

struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var progress: Double
        var downloadedBytes: Int64
        var totalBytes: Int64
        var bytesPerSecond: Double
        var remainingSeconds: Int
        var status: String
    }

    var itemID: String
    var title: String
}
