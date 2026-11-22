import MobileVLCKit
import SwiftUI
import UIKit

/// Route marker set by PlayerView when the chosen media source carries PGS
/// (bitmap) subtitles: MPVUI's renderers cannot composite those, libvlc can.
struct VLCRoute {
    let url: URL
    let sourceID: String
    let sessionID: String?
}

// MARK: - controller

final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()

    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var hasError = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var audioTracks: [(id: Int32, name: String)] = []
    @Published var subtitleTracks: [(id: Int32, name: String)] = []
    @Published var selectedAudioID: Int32 = -1
    @Published var selectedSubtitleID: Int32 = -1
    @Published var rate: Float = 1

    private var mediaConfigured = false
    private var drawableAttached = false
    private var startSeconds: Double = 0
    private var didInitialSeek = false
    private var didAutoSelectSubtitle = false

    func prepare(url: URL, startSeconds: Double) {
        guard !mediaConfigured else { return }
        mediaConfigured = true
        self.startSeconds = startSeconds
        let media = VLCMedia(url: url)
        media.addOption("network-caching=5000")
        if startSeconds > 5 {
            media.addOption("start-time=\(Int(startSeconds))")
        }
        player.media = media
        player.delegate = self
        if drawableAttached { player.play() }
    }

    func attachDrawable(_ view: UIView) {
        player.drawable = view
        drawableAttached = true
        if mediaConfigured, player.media != nil, !player.isPlaying, player.state != .playing {
            player.play()
        }
    }

    // MARK: VLCMediaPlayerDelegate

    func mediaPlayerStateChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    func mediaPlayerTimeChanged(_ aNotification: Notification) {
        DispatchQueue.main.async { [weak self] in self?.refresh() }
    }

    private func refresh() {
        let state = player.state
        isPlaying = state == .playing
        isBuffering = state == .opening || state == .buffering
        hasError = state == .error
        position = Double(player.time.intValue) / 1000
        if let media = player.media, media.length.intValue > 0 {
            duration = Double(media.length.intValue) / 1000
        }
        if duration <= 0, position > 0 {
            let remaining = player.remainingTime.map { Double($0.intValue) / 1000 } ?? 0
            if remaining > 0 { duration = position + remaining }
        }
        refreshTracks()
        if state == .playing, !didInitialSeek {
            didInitialSeek = true
            if startSeconds > 5, position < startSeconds - 2 {
                seek(to: startSeconds)
            }
        }
    }

    private func refreshTracks() {
        let audio = Self.trackList(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        if audio.count != audioTracks.count { audioTracks = audio }
        let subs = Self.trackList(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        if subs.count != subtitleTracks.count { subtitleTracks = subs }
        selectedAudioID = player.currentAudioTrackIndex
        selectedSubtitleID = player.currentVideoSubTitleIndex
        if !didAutoSelectSubtitle, subtitleTracks.count > 1 {
            didAutoSelectSubtitle = true
            if player.currentVideoSubTitleIndex < 0 {
                let pick = subtitleTracks.first(where: { $0.name.contains("简") || $0.name.contains("中") })
                    ?? subtitleTracks.first(where: { $0.id >= 0 })
                if let pick {
                    player.currentVideoSubTitleIndex = pick.id
                    selectedSubtitleID = pick.id
                }
            }
        }
    }

    private static func trackList(names: [Any]?, indexes: [Any]?) -> [(id: Int32, name: String)] {
        guard let names, let indexes else { return [] }
        return zip(names, indexes).compactMap { name, idx in
            guard let id = (idx as? NSNumber)?.int32Value else { return nil }
            return (id, (name as? String) ?? "轨道 \(id)")
        }
    }

    // MARK: transport

    func togglePlay() {
        if player.isPlaying { player.pause() } else { player.play() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in self?.refresh() }
    }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration : seconds))
        player.time = VLCTime(number: NSNumber(value: Int32(clamped * 1000)))
        position = clamped
    }

    func seekBy(_ delta: Double) { seek(to: position + delta) }

    func setRate(_ newRate: Float) {
        rate = newRate
        player.rate = newRate
    }

    func selectAudio(_ id: Int32) {
        player.currentAudioTrackIndex = id
        selectedAudioID = id
    }

    func selectSubtitle(_ id: Int32) {
        player.currentVideoSubTitleIndex = id
        selectedSubtitleID = id
    }

    var volumeLevel: Double {
        get { Double(player.audio?.volume ?? 100) / 200 }
        set { player.audio?.volume = Int32(max(0, min(newValue, 1)) * 200) }
    }
}

// MARK: - video surface

private struct VLCVideoSurface: UIViewRepresentable {
    let controller: VLCPlayerController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.attachDrawable(view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - view

struct VLCPlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: EmbyItem
    let route: VLCRoute
    let startSeconds: Double

    @StateObject private var controller = VLCPlayerController()
    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var gestureHint: String?
    @State private var dragMode: DragMode?
    @State private var dragStartPosition: Double = 0
    @State private var dragStartLevel: Double = 0

    private enum DragMode { case scrub, brightness, volume }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(controller: controller)
                .ignoresSafeArea()

            gestureLayer

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

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.body.bold())
                            .foregroundStyle(.white)
                            .padding(10)
                            .background(.black.opacity(0.45), in: Circle())
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.leading, 14)
            .padding(.top, 10)
            .zIndex(10)
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
            .allowsHitTesting(chromeVisible)

            if controller.isBuffering, !controller.hasError {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
            if controller.hasError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("VLC 引擎播放失败").font(.footnote)
                }
                .foregroundStyle(.white)
                .padding()
            }
        }
        .statusBarHidden(true)
        .task { await reportingLoop() }
        .onAppear {
            controller.prepare(url: route.url, startSeconds: startSeconds)
            scheduleHide()
        }
        .onDisappear {
            hideTask?.cancel()
            let client = store.client()
            let position = controller.position
            Task { await client?.reportStopped(itemID: item.Id, sourceID: route.sourceID, sessionID: route.sessionID, positionSeconds: position) }
            controller.player.stop()
        }
    }

    // MARK: - reporting

    private func reportingLoop() async {
        guard let client = store.client() else { return }
        await client.reportStart(itemID: item.Id, sourceID: route.sourceID, sessionID: route.sessionID, positionSeconds: startSeconds)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            await client.reportProgress(itemID: item.Id, sourceID: route.sourceID,
                                        sessionID: route.sessionID,
                                        positionSeconds: controller.position,
                                        isPaused: !controller.isPlaying)
        }
    }

    // MARK: - chrome

    private var chrome: some View {
        VStack {
            HStack(spacing: 12) {
                Spacer().frame(width: 34)
                Text(item.Name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                trackMenus
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Spacer()

            HStack(spacing: 14) {
                Button { controller.togglePlay(); pokeChrome() } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                Text(formatDuration(scrubbing ? scrubValue : controller.position))
                    .font(.caption.monospacedDigit())
                Slider(value: Binding(
                    get: { scrubbing ? scrubValue : controller.position },
                    set: { scrubValue = $0 }
                ), in: 0...max(controller.duration, 1)) { editing in
                    if editing { scrubbing = true; scrubValue = controller.position }
                    else {
                        controller.seek(to: scrubValue)
                        scrubbing = false
                        pokeChrome()
                    }
                }
                .tint(.white)
                Text(formatDuration(controller.duration))
                    .font(.caption.monospacedDigit())
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
            if controller.audioTracks.count > 1 {
                Menu {
                    ForEach(controller.audioTracks, id: \.id) { track in
                        Button {
                            controller.selectAudio(track.id)
                        } label: {
                            Label(track.name, systemImage: controller.selectedAudioID == track.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "waveform").font(.title3)
                }
            }
            if controller.subtitleTracks.count > 1 {
                Menu {
                    Text("引擎：VLCKit（PGS 字幕）")
                    ForEach(controller.subtitleTracks, id: \.id) { track in
                        Button {
                            controller.selectSubtitle(track.id)
                        } label: {
                            Label(track.name, systemImage: controller.selectedSubtitleID == track.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "captions.bubble").font(.title3)
                }
            }
            Menu {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    Button("\(rate, specifier: "%g")×") { controller.setRate(Float(rate)) }
                }
            } label: {
                Image(systemName: "gauge.with.dots.needle.33percent").font(.title3)
            }
        }
    }

    // MARK: - gestures

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in handleDrag(value) }
                    .onEnded { _ in handleDragEnd() }
            )
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { controller.seekBy(-10); pokeChrome() }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { controller.togglePlay(); pokeChrome() }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { controller.seekBy(10); pokeChrome() }
                }
            }
            .onTapGesture { toggleChrome() }
    }

    private func handleDrag(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        if dragMode == nil {
            if abs(dx) > abs(dy) {
                dragMode = .scrub
                dragStartPosition = controller.position
                scrubbing = true
            } else {
                let startX = value.startLocation.x
                let width = UIScreen.main.bounds.width
                dragMode = startX < width / 2 ? .brightness : .volume
                dragStartLevel = dragMode == .brightness
                    ? Double(UIScreen.main.brightness)
                    : controller.volumeLevel
            }
        }
        switch dragMode {
        case .scrub:
            let duration = max(controller.duration, 1)
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
            controller.volumeLevel = level
            gestureHint = "音量 \(Int(level * 100))%"
        case nil:
            break
        }
    }

    private func handleDragEnd() {
        if dragMode == .scrub {
            controller.seek(to: scrubValue)
            scrubbing = false
        }
        dragMode = nil
        gestureHint = nil
        pokeChrome()
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
            if controller.isPlaying { chromeVisible = false }
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
