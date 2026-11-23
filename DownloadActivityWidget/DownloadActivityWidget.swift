import ActivityKit
import SwiftUI
import WidgetKit

// Lock screen + Dynamic Island presentation for download activities.
// Pure presentation: all state arrives in the activity's ContentState.

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenView(context: context)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIcon(status: state.status)
                        .font(.title3)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.status == "下载中"
                         ? state.progress.formatted(.percent.precision(.fractionLength(0)))
                         : state.status)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: state.progress)
                            .tint(.accentColor)
                        HStack {
                            Text("\(byteText(state.downloadedBytes)) / \(byteText(state.totalBytes))")
                            Spacer()
                            Text(trailingText(state))
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                StatusIcon(status: state.status)
            } compactTrailing: {
                Text(state.status == "下载中"
                     ? state.progress.formatted(.percent.precision(.fractionLength(0)))
                     : state.status)
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .frame(minWidth: 36)
            } minimal: {
                StatusIcon(status: state.status)
            }
            .keylineTint(.accentColor)
        }
    }
}

private struct StatusIcon: View {
    let status: String
    var body: some View {
        Image(systemName: status == "已完成" ? "checkmark.circle.fill"
              : status == "失败" ? "exclamationmark.circle.fill"
              : "arrow.down.circle.fill")
            .foregroundStyle(status == "失败" ? Color.red : Color.accentColor)
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>

    var body: some View {
        let state = context.state
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                StatusIcon(status: state.status)
                Text(context.attributes.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(state.status == "下载中"
                     ? state.progress.formatted(.percent.precision(.fractionLength(0)))
                     : state.status)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
            }
            ProgressView(value: state.progress)
                .tint(.accentColor)
            HStack {
                Text("\(byteText(state.downloadedBytes)) / \(byteText(state.totalBytes))")
                Spacer()
                Text(trailingText(state))
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding()
        .activityBackgroundTint(Color.black.opacity(0.35))
        .activitySystemActionForegroundColor(.white)
    }
}

private func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

private func trailingText(_ state: DownloadActivityAttributes.ContentState) -> String {
    guard state.status == "下载中" else { return state.status }
    if state.remainingSeconds > 0 { return "剩余 \(remainingText(state.remainingSeconds))" }
    if state.bytesPerSecond > 0 { return "\(byteText(Int64(state.bytesPerSecond)))/秒" }
    return "正在接收数据…"
}

private func remainingText(_ seconds: Int) -> String {
    if seconds >= 3600 { return String(format: "%d小时%02d分", seconds / 3600, (seconds % 3600) / 60) }
    if seconds >= 60 { return String(format: "%d分%02d秒", seconds / 60, seconds % 60) }
    return "\(seconds)秒"
}

@main
struct DownloadWidgets: WidgetBundle {
    var body: some Widget {
        DownloadActivityWidget()
    }
}
