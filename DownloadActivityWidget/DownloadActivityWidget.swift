import ActivityKit
import SwiftUI
import WidgetKit

struct DownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            DownloadLockScreenView(context: context)
                .widgetURL(URL(string: "deniaplayer://downloads"))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.status == "已完成" ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .foregroundStyle(state.status == "失败" ? Color.red : Color.accentColor)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.status == "下载中" ? state.progress.formatted(.percent.precision(.fractionLength(0))) : state.status)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(context.attributes.title).lineLimit(1).font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: state.progress)
                        HStack {
                            Text("\(ByteCountFormatter.string(fromByteCount: state.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: state.totalBytes, countStyle: .file))")
                            Spacer()
                            Text(state.status == "下载中" ? (state.remainingSeconds > 0 ? "剩余 \(formatRemaining(state.remainingSeconds))" : "\(ByteCountFormatter.string(fromByteCount: Int64(state.bytesPerSecond), countStyle: .file))/秒") : state.status)
                        }.font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: state.status == "已完成" ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(state.status == "失败" ? Color.red : Color.accentColor)
            } compactTrailing: {
                Text(state.status == "下载中" ? state.progress.formatted(.percent.precision(.fractionLength(0))) : state.status)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: state.status == "已完成" ? "checkmark.circle.fill" : "arrow.down.circle.fill")
            }
            .widgetURL(URL(string: "deniaplayer://downloads"))
            .keylineTint(.accentColor)
        }
    }
}

private struct DownloadLockScreenView: View {
    let context: ActivityViewContext<DownloadActivityAttributes>
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(context.attributes.title, systemImage: "arrow.down.circle.fill").lineLimit(1)
                Spacer()
                Text(context.state.status == "下载中" ? context.state.progress.formatted(.percent.precision(.fractionLength(0))) : context.state.status)
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: context.state.progress)
            HStack {
                Text("\(ByteCountFormatter.string(fromByteCount: context.state.downloadedBytes, countStyle: .file)) / \(ByteCountFormatter.string(fromByteCount: context.state.totalBytes, countStyle: .file))")
                Spacer()
                if context.state.remainingSeconds > 0 {
                    Text("剩余 \(formatRemaining(context.state.remainingSeconds))")
                } else if context.state.bytesPerSecond > 0 {
                    Text("\(ByteCountFormatter.string(fromByteCount: Int64(context.state.bytesPerSecond), countStyle: .file))/秒")
                }
            }.font(.caption2).foregroundStyle(.secondary)
        }.padding()
    }
}

@main
struct DownloadWidgets: WidgetBundle {
    var body: some Widget { DownloadActivityWidget() }
}

private func formatRemaining(_ seconds: Int) -> String {
    if seconds >= 3600 { return String(format: "%d小时%02d分", seconds / 3600, (seconds % 3600) / 60) }
    if seconds >= 60 { return String(format: "%d分%02d秒", seconds / 60, seconds % 60) }
    return "\(seconds)秒"
}
