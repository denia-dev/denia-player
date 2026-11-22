import MPVUI
import SwiftUI
import UIKit

extension Duration {
    var secondsValue: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Spike player: proves the mpv direct-play core on real files.
/// Layout rule (from the post-mortem): the rendering view is created once and
/// never moves; gestures live on their own transparent layer; chrome is a
/// sibling overlay animated by opacity only.
struct PlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: EmbyItem
    let startSeconds: Double

    @State private var player = MPVPlayer(configuration: .init(
        automaticallyPlays: true,
        hardwareDecoding: .automatic,
        networkCacheDuration: .seconds(120),
        additionalOptions: [
            "sub-auto": "fuzzy",
            "demuxer-max-bytes": "536870912",
        ]
    ))

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var session: (sourceID: String, sessionID: String?)?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var gestureHint: String?
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Rendering layer — constant, full-bleed, never re-laid out.
            MPVVideoPlayer(player: player)
                .ignoresSafeArea()

            // Gesture layer.
            gestureLayer

            // Chrome overlay — opacity only.
            chrome
                .opacity(chromeVisible ? 1 : 0)
                .animation(.easeInOut(duration: 0.25), value: chromeVisible)
                .allowsHitTesting(chromeVisible)

            if let gestureHint {
                Text(gestureHint)
                    .font(.headline)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: Capsule())
                    .foregroundStyle(.white)
            }

            if player.state == .loading {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
            if let loadError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text(loadError).font(.footnote).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .statusBarHidden(true)
        .task { await startPlayback() }
        .task { await progressLoop() }
        .onAppear { savedBrightness = UIScreen.main.brightness }
        .onDisappear {
            hideTask?.cancel()
            UIScreen.main.brightness = savedBrightness
            if let session {
                let client = store.client()
                let position = player.position.secondsValue
                Task { await client?.reportStopped(itemID: item.Id, sourceID: session.sourceID, sessionID: session.sessionID, positionSeconds: position) }
            }
            player.stop()
        }
    }

    // MARK: - playback session

    private func startPlayback() async {
        guard let client = store.client() else { loadError = "没有可用服务器"; return }
        do {
            let info = try await client.playbackInfo(itemID: item.Id, startSeconds: startSeconds)
            guard let source = info.MediaSources.first(where: { $0.SupportsDirectPlay == true }) ?? info.MediaSources.first else {
                loadError = "服务器没有返回媒体源"
                return
            }
            guard let url = client.directStreamURL(itemID: item.Id, source: source, sessionID: info.PlaySessionId) else {
                loadError = "无法生成直连地址"
                return
            }
            session = (source.Id, info.PlaySessionId)
            player.load(url, startTime: startSeconds > 5 ? .seconds(startSeconds) : nil)
            await client.reportStart(itemID: item.Id, sourceID: source.Id, sessionID: info.PlaySessionId, positionSeconds: startSeconds)
            scheduleHide()
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    private func progressLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard let session, let client = store.client() else { continue }
            await client.reportProgress(itemID: item.Id, sourceID: session.sourceID,
                                         sessionID: session.sessionID,
                                         positionSeconds: player.position.secondsValue,
                                         isPaused: player.isPaused)
        }
    }

    // MARK: - gestures

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in handleDrag(value) }
                    .onEnded { value in handleDragEnd(value) }
            )
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { seekBy(-10) }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { player.togglePlayback() }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { seekBy(10) }
                }
            }
            .onTapGesture { toggleChrome() }
    }

    @State private var dragMode: DragMode?
    @State private var dragStartPosition: Double = 0
    @State private var dragStartLevel: Double = 0

    private enum DragMode { case scrub, brightness, volume }

    private func handleDrag(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        if dragMode == nil {
            if abs(dx) > abs(dy) {
                dragMode = .scrub
                dragStartPosition = player.position.secondsValue
                scrubbing = true
            } else {
                let startX = value.startLocation.x
                let width = UIScreen.main.bounds.width
                dragMode = startX < width / 2 ? .brightness : .volume
                dragStartLevel = dragMode == .brightness
                    ? Double(UIScreen.main.brightness)
                    : player.volume / 100
            }
        }
        switch dragMode {
        case .scrub:
            let duration = max(player.duration.secondsValue, 1)
            let delta = Double(dx) / Double(UIScreen.main.bounds.width) * duration * 0.5
            scrubValue = min(max(dragStartPosition + delta, 0), duration)
            gestureHint = "\(formatDuration(scrubValue)) / \(formatDuration(duration))"
        case .brightness:
            let delta = -Double(dy) / 240
            UIScreen.main.brightness = CGFloat(min(max(dragStartLevel + delta, 0.05), 1))
            gestureHint = "亮度 \(Int(UIScreen.main.brightness * 100))%"
        case .volume:
            let delta = -Double(dy) / 240
            let level = min(max(dragStartLevel + delta, 0), 1)
            player.setVolume(level * 100)
            gestureHint = "音量 \(Int(level * 100))%"
        case nil:
            break
        }
    }

    private func handleDragEnd(_ value: DragGesture.Value) {
        if dragMode == .scrub {
            player.seek(to: .seconds(scrubValue))
        }
        dragMode = nil
        scrubbing = false
        gestureHint = nil
    }

    private func seekBy(_ delta: Double) {
        player.seek(by: .seconds(delta))
        flashHint(delta > 0 ? "+\(Int(delta))s" : "\(Int(delta))s")
        pokeChrome()
    }

    private func flashHint(_ text: String) {
        gestureHint = text
        Task {
            try? await Task.sleep(for: .seconds(0.7))
            if gestureHint == text { gestureHint = nil }
        }
    }

    // MARK: - chrome

    private var chrome: some View {
        VStack {
            HStack(spacing: 14) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.title3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.Name).font(.subheadline.bold()).lineLimit(1)
                    if let series = item.SeriesName {
                        Text(series).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer()
                trackMenus
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            Button { player.togglePlayback(); pokeChrome() } label: {
                Image(systemName: player.isPaused ? "play.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 54))
            }

            Spacer()

            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    Text(formatDuration(scrubbing ? scrubValue : player.position.secondsValue))
                        .font(.caption.monospacedDigit())
                    Slider(value: Binding(
                        get: { scrubbing ? scrubValue : player.position.secondsValue },
                        set: { scrubValue = $0 }
                    ), in: 0...max(player.duration.secondsValue, 1)) { editing in
                        if editing { scrubbing = true; scrubValue = player.position.secondsValue }
                        else {
                            player.seek(to: .seconds(scrubValue))
                            scrubbing = false
                            pokeChrome()
                        }
                    }
                    .tint(.white)
                    Text(formatDuration(player.duration.secondsValue))
                        .font(.caption.monospacedDigit())
                }
                if let error = player.lastError {
                    Text(String(describing: error)).font(.caption2).foregroundStyle(.red.opacity(0.9)).lineLimit(2)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 10)
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var trackMenus: some View {
        HStack(spacing: 14) {
            if !player.audioTracks.isEmpty {
                Menu {
                    ForEach(player.audioTracks, id: \.mpvID) { track in
                        Button {
                            player.selectTrack(track.id)
                        } label: {
                            Label(trackLabel(track), systemImage: track.isSelected ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "waveform").font(.title3)
                }
            }
            if !player.subtitleTracks.isEmpty {
                Menu {
                    Button("关闭字幕") { player.selectSubtitle(nil) }
                    ForEach(player.subtitleTracks, id: \.mpvID) { track in
                        Button {
                            player.selectSubtitle(track.id)
                        } label: {
                            Label(trackLabel(track), systemImage: track.isSelected ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble").font(.title3)
                }
            }
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button("\(rate, specifier: "%g")×") { player.setPlaybackRate(rate) }
                }
            } label: {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title3)
            }
        }
    }

    private func trackLabel(_ track: MPVMediaTrack) -> String {
        if let title = track.title, !title.isEmpty { return title }
        var parts: [String] = []
        if let language = track.language { parts.append(language) }
        if let codec = track.codec { parts.append(codec) }
        return parts.isEmpty ? "轨道 \(track.mpvID)" : parts.joined(separator: " · ")
    }

    // MARK: - chrome visibility

    private func toggleChrome() {
        chromeVisible.toggle()
        if chromeVisible { scheduleHide() } else { hideTask?.cancel() }
    }

    private func pokeChrome() {
        chromeVisible = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            if !player.isPaused { chromeVisible = false }
        }
    }
}
