import ActivityKit
import Combine
import Foundation

// MARK: - download Live Activities (lock screen + Dynamic Island)
//
// Every ActivityKit interaction for downloads lives here. Two rules shaped
// this implementation:
//
// 1. The activity is requested synchronously on the main actor at the moment
//    the user taps download, while the app is guaranteed active. Requesting
//    only after the PlaybackInfo round-trip (the previous implementation)
//    lets the request land after the user has already locked the phone to
//    go look for the island — a request made from the background is not
//    presented, and the download silently has no activity at all.
// 2. No stale date is ever set. A stale activity is deprioritised by the
//    system and can drop out of the Dynamic Island mid-download; a download
//    may legitimately run far longer than any fixed stale window.
//
// Every outcome — started, refused by system settings, request error — is
// written to `status`, which the downloads list renders under the task row,
// so a failure says why instead of simply not appearing.

@MainActor
final class DownloadLiveActivityCenter: ObservableObject {
    enum Outcome {
        case completed, failed, cancelled
    }

    /// itemID -> one-line human status, shown under the download row.
    @Published private(set) var status: [String: String] = [:]
    /// itemID -> current speed in bytes per second, shown in the row.
    @Published private(set) var speeds: [String: Double] = [:]

    private var activities: [String: Activity<DownloadActivityAttributes>] = [:]
    private var lastUpdateAt: [String: Date] = [:]
    private var lastSample: [String: (date: Date, bytes: Int64)] = [:]

    init() {
        // Activities outlive the app process; adopt the ones still running.
        for activity in Activity<DownloadActivityAttributes>.activities
        where activity.activityState == .active {
            activities[activity.attributes.itemID] = activity
        }
    }

    func lastKnownBytes(for itemID: String) -> Int64 {
        lastSample[itemID]?.bytes ?? 0
    }

    /// Idempotent: safe to call at tap time and again once the real task
    /// exists. Never throws — the outcome lands in `status`.
    func start(itemID: String, title: String, totalBytes: Int64) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            status[itemID] = "实时活动被系统关掉了：去「设置 → Denia Player」打开「实时活动」"
            return
        }
        if let running = activities[itemID], running.activityState == .active {
            status[itemID] = "实时活动已开启（锁屏或灵动岛查看）"
            return
        }
        if let running = Activity<DownloadActivityAttributes>.activities
            .first(where: { $0.attributes.itemID == itemID && $0.activityState == .active }) {
            activities[itemID] = running
            status[itemID] = "实时活动已开启（锁屏或灵动岛查看）"
            return
        }
        let attributes = DownloadActivityAttributes(itemID: itemID, title: title)
        let state = DownloadActivityAttributes.ContentState(
            progress: 0, downloadedBytes: 0, totalBytes: totalBytes,
            bytesPerSecond: 0, remainingSeconds: 0, status: "下载中")
        do {
            let activity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: nil),
                pushType: nil)
            activities[itemID] = activity
            status[itemID] = "实时活动已开启（锁屏或灵动岛查看）"
        } catch {
            status[itemID] = "实时活动开启失败：\(error.localizedDescription)"
        }
    }

    /// Progress updates, throttled to one per second per item.
    func update(itemID: String, bytes: Int64, total: Int64) {
        let now = Date()
        if let last = lastUpdateAt[itemID], now.timeIntervalSince(last) < 1 { return }
        let previous = lastSample[itemID]
        let elapsed = previous.map { now.timeIntervalSince($0.date) } ?? 0
        let speed = elapsed > 0.25
            ? Double(max(0, bytes - (previous?.bytes ?? bytes))) / elapsed
            : 0
        lastSample[itemID] = (now, bytes)
        lastUpdateAt[itemID] = now
        speeds[itemID] = speed
        guard let activity = activities[itemID] else { return }
        let fraction = total > 0 ? min(1, max(0, Double(bytes) / Double(total))) : 0
        let remaining = speed > 0 && total > bytes ? Int(Double(total - bytes) / speed) : 0
        let state = DownloadActivityAttributes.ContentState(
            progress: fraction, downloadedBytes: bytes, totalBytes: total,
            bytesPerSecond: speed, remainingSeconds: remaining, status: "下载中")
        Task { await activity.update(ActivityContent(state: state, staleDate: nil)) }
    }

    /// Final state + dismissal. Completed lingers briefly so the user sees
    /// it; a cancel disappears at once.
    func finish(itemID: String, outcome: Outcome, bytes: Int64, total: Int64) {
        speeds[itemID] = nil
        lastSample[itemID] = nil
        lastUpdateAt[itemID] = nil
        status[itemID] = nil
        guard let activity = activities.removeValue(forKey: itemID) else { return }
        let label: String
        let dismissal: ActivityUIDismissalPolicy
        switch outcome {
        case .completed:
            label = "已完成"
            dismissal = .after(Date().addingTimeInterval(120))
        case .failed:
            label = "失败"
            dismissal = .after(Date().addingTimeInterval(300))
        case .cancelled:
            label = "已取消"
            dismissal = .immediate
        }
        let fraction = total > 0 ? min(1, max(0, Double(bytes) / Double(total))) : (outcome == .completed ? 1 : 0)
        let state = DownloadActivityAttributes.ContentState(
            progress: fraction, downloadedBytes: bytes, totalBytes: total,
            bytesPerSecond: 0, remainingSeconds: 0, status: label)
        Task { await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: dismissal) }
    }
}
