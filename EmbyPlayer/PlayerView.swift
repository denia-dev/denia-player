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

    @State private var player = PlayerView.makePlayer(videoOutput: .metal)
    @State private var playerGeneration = 0
    @State private var currentStreamURL: URL?
    @State private var vlcRoute: VLCRoute?
    @State private var currentSource: EmbyMediaSource?
    @State private var preparedGeneration = -1

    static func makePlayer(videoOutput: MPVPlayerConfiguration.VideoOutput) -> MPVPlayer {
        var options: [String: String] = [
            "sub-auto": "fuzzy",
            "slang": "zh-Hans,zh-CN,zh,chi,zho",
            "demuxer-max-bytes": "536870912",
            "demuxer-readahead-secs": "60",
            "stream-lavf-o": "reconnect=1,reconnect_streamed=1,reconnect_delay_max=5",
        ]
        // MPVUI ships no fonts and iOS exposes no system font dir to libass,
        // so bundle a CJK font or every Chinese subtitle renders as tofu.
        let fontURL = Bundle.main.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf")
            ?? Bundle.main.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf", subdirectory: "Fonts")
        if let fontURL {
            options["sub-fonts-dir"] = fontURL.deletingLastPathComponent().path
            options["sub-font"] = "Noto Sans CJK SC"
        }
        let created = MPVPlayer(configuration: .init(
            additionalOptions: options,
            automaticallyPlays: true,
            dolbyVisionPolicy: .profile7Compatibility,
            hardwareDecoding: .videoToolbox,
            initialBufferDuration: .seconds(3),
            networkCacheDuration: .seconds(120),
            rebufferDuration: .seconds(5),
            videoOutput: videoOutput
        ))
        created.setDiagnosticsEnabled(true)
        return created
    }

    @State private var chromeVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var session: (sourceID: String, sessionID: String?)?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var gestureHint: String?
    @State private var showDiagnostics = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // Rendering layer — constant, full-bleed, never re-laid out.
            MPVVideoPlayer(player: player)
                .id(playerGeneration)
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

            // Exit must never depend on the chrome layer: this button lives
            // outside it, above every other layer, and is always hittable.
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

            if player.state == .loading {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
            if let vlcRoute {
                VLCPlayerView(item: item, route: vlcRoute, startSeconds: startSeconds)
                    .zIndex(30)
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
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                ScrollView {
                    Text(diagnosticsText())
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("播放诊断")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("复制") { UIPasteboard.general.string = diagnosticsText() }
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        Button("关闭") { showDiagnostics = false }
                    }
                }
            }
        }
        .task { await startPlayback() }
        .task { await progressLoop() }
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            requestOrientation(.landscape)
        }
        .onDisappear {
            requestOrientation(.portrait)
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
            // PGS (bitmap) subtitles cannot be composited by MPVUI's
            // renderers (proven by diagnostics, builds 8-10): hand those
            // items to the VLCKit engine, which renders them natively.
            // The VLC view owns session reporting for this route.
            let hasPGS = (source.MediaStreams ?? []).contains {
                $0.type == "Subtitle" && ($0.Codec ?? "").lowercased().contains("pgs")
            }
            if hasPGS {
                vlcRoute = VLCRoute(url: url, sourceID: source.Id, sessionID: info.PlaySessionId)
                return
            }
            session = (source.Id, info.PlaySessionId)
            currentStreamURL = url
            currentSource = source
            player.load(url, startTime: startSeconds > 5 ? .seconds(startSeconds) : nil)
            player.requestVideoFeatures([.nativeSubtitles])
            player.setSubtitlesVisible(true)
            Task { await prepareSubtitles() }
            await client.reportStart(itemID: item.Id, sourceID: source.Id, sessionID: info.PlaySessionId, positionSeconds: startSeconds)
            scheduleHide()
        } catch {
            loadError = "加载失败：\(error.localizedDescription)"
        }
    }

    // MARK: - subtitles & orientation

    private func isChineseSub(language: String?, title: String?) -> Bool {
        let lang = (language ?? "").lowercased()
        if lang.hasPrefix("zh") || lang == "chi" || lang == "zho" { return true }
        let t = title ?? ""
        return t.contains("中") || t.contains("简") || t.contains("繁") || t.localizedCaseInsensitiveContains("chs") || t.localizedCaseInsensitiveContains("cht")
    }

    /// Adds the server's external subtitle files and, when the container did
    /// not auto-select one, selects the best embedded track (Chinese first,
    /// then the container's default, then the first track).
    private func prepareSubtitles() async {
        guard let source = currentSource, let client = store.client() else { return }
        let generation = playerGeneration
        guard preparedGeneration != generation else { return }
        preparedGeneration = generation

        let externals = client.externalSubtitles(itemID: item.Id, source: source)
        if !externals.isEmpty {
            let preferred = externals.first(where: { isChineseSub(language: $0.language, title: $0.title) }) ?? externals[0]
            for ext in externals where ext.url != preferred.url {
                player.loadExternalSubtitle(ext.url, selecting: nil)
            }
            player.loadExternalSubtitle(preferred.url, selecting: .primary)
        }

        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == playerGeneration, !Task.isCancelled else { return }
            let subs = player.subtitleTracks
            if subs.contains(where: { $0.isSelected }) { return }
            guard let best = subs.first(where: { isChineseSub(language: $0.language, title: $0.title) })
                    ?? subs.first(where: { $0.isDefault })
                    ?? subs.first else { continue }
            try? await Task.sleep(for: .seconds(1))
            guard generation == playerGeneration else { return }
            if !player.subtitleTracks.contains(where: { $0.isSelected }) {
                player.requestVideoFeatures([.nativeSubtitles])
                player.selectSubtitle(best.id)
                player.setSubtitlesVisible(true)
            }
            return
        }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
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
                // The always-on close button sits at the top-left; leave room.
                Color.clear.frame(width: 34, height: 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.Name).font(.subheadline.bold()).lineLimit(1)
                    if let series = item.SeriesName {
                        Text(series).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer()
                Button { showDiagnostics = true } label: {
                    Image(systemName: "info.circle").font(.title3)
                }
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
                            player.setSubtitlesVisible(true)
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
        if let title = track.title, !title.isEmpty {
            if let codec = track.codec, !codec.isEmpty { return "\(title) · \(codec)" }
            return title
        }
        var parts: [String] = []
        if let language = track.language { parts.append(language) }
        if let codec = track.codec { parts.append(codec) }
        return parts.isEmpty ? "轨道 \(track.mpvID)" : parts.joined(separator: " · ")
    }

    // MARK: - diagnostics

    private func diagnosticsText() -> String {
        let caps = player.videoFeatureCapabilities
        let diag = player.playbackDiagnostics
        var lines: [String] = []
        lines.append("configuredOutput: \(player.videoOutput)")
        lines.append("backend: \(caps.backend)")
        lines.append("nativeSubtitles: \(caps.nativeSubtitles.availability.rawValue) restriction=\(caps.nativeSubtitles.restriction?.rawValue ?? "-")")
        lines.append("dolbyVision: \(String(describing: player.dolbyVisionStatus))")
        lines.append("renderColor: \(String(describing: player.renderColorStatus))")
        lines.append("decoder: \(String(describing: diag.decoder))")
        lines.append("nativeOutputActive: \(diag.nativeOutputStatistics != nil)")
        lines.append("dropped: decoder=\(diag.decoderDroppedFrames ?? -1) output=\(diag.outputDroppedFrames ?? -1)")
        lines.append("featureResult: \(String(describing: player.videoFeatureRequestResult))")
        lines.append("media: \(String(describing: player.mediaInformation))")
        for track in player.subtitleTracks {
            lines.append("sub #\(track.mpvID): codec=\(track.codec ?? "-") lang=\(track.language ?? "-") selected=\(track.isSelected) external=\(track.isExternal)")
        }
        return lines.joined(separator: "\n")
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
