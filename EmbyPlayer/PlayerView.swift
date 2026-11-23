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
    var onPlayNext: ((EmbyItem) -> Void)?

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
            "vd-lavc-threads": "\(Prefs.softwareThreads)",
            "sub-scale": String(format: "%.2f", Prefs.subScale),
            "sub-delay": String(format: "%.1f", Prefs.subDelay),
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
            dolbyVisionPolicy: Prefs.dvP7Convert ? .profile7Compatibility : .strict,
            hardwareDecoding: Prefs.decodeMode == "software" ? .disabled : (Prefs.decodeMode == "auto" ? .automatic : .videoToolbox),
            initialBufferDuration: .seconds(3),
            networkCacheDuration: .seconds(120),
            rebufferDuration: .seconds(5),
            videoOutput: videoOutput
        ))
        created.setDiagnosticsEnabled(true)
        return created
    }

    @State private var chromeVisible = true
    @State private var controlsLocked = false
    @State private var pressStart: Date?
    @State private var pressBoosted = false
    @State private var pressTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var loadError: String?
    @State private var session: (sourceID: String, sessionID: String?)?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var gestureHint: String?
    @State private var showDiagnostics = false
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness
    @State private var currentRate: Double = 1
    @State private var boostSavedRate: Double?
    @State private var nextEpisode: EmbyItem?
    @State private var segments: [MediaSegment] = []
    @State private var activeSegment: MediaSegment?
    @State private var seasonEpisodes: [EmbyItem] = []
    @State private var showEpisodePicker = false
    @State private var endWatchTask: Task<Void, Never>?
    @State private var sleepTask: Task<Void, Never>?

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
                    .glassEffect(.regular, in: Capsule())
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
                            .glassEffect(.regular.interactive(), in: Circle())
                            .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
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

            // Loading backdrop: gives the glass chrome something to
            // refract before the first frame arrives - over pure black
            // the glass renders as a black blob.
            Group {
                if player.state == .loading, let client = store.client() {
                    ItemImage(item: item, client: client, kind: wideImageKind(item))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.25))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: player.state == .loading)
            .allowsHitTesting(false)

            if player.state == .loading {
                ProgressView().tint(.white).scaleEffect(1.4)
            }
            if let vlcRoute {
                VLCPlayerView(item: item, route: vlcRoute, startSeconds: startSeconds, onPlayNext: onPlayNext)
                    .zIndex(30)
            }

            if let activeSegment {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button { skipActiveSegment() } label: {
                            Text(activeSegment.isIntro ? "跳过片头" : "跳过片尾")
                                .font(.subheadline.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 16).padding(.vertical, 9)
                                .glassEffect(.regular.interactive(), in: Capsule())
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.trailing, 16)
                .padding(.bottom, 96)
                .zIndex(20)
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
            if Prefs.independentBrightness {
                UIScreen.main.brightness = CGFloat(Prefs.playerBrightness)
            }
            applyEntryOrientation()
            if !Prefs.toastTitleOnPlay { chromeVisible = false }
        }
        .sheet(isPresented: $showEpisodePicker) { episodePicker }
        .onDisappear {
            requestOrientation(.portrait)
            hideTask?.cancel()
            sleepTask?.cancel()
            endWatchTask?.cancel()
            if Prefs.independentBrightness {
                Prefs.playerBrightness = Double(UIScreen.main.brightness)
            }
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
                let audios = (source.MediaStreams ?? [])
                    .filter { $0.type == "Audio" }
                    .sorted { $0.Index < $1.Index }
                func isTrueHD(_ stream: EmbyMediaStream) -> Bool {
                    (stream.Codec ?? "").lowercased().contains("truehd")
                }
                func isChineseAudio(_ stream: EmbyMediaStream) -> Bool {
                    let lang = (stream.Language ?? "").lowercased()
                    return lang.hasPrefix("zh") || lang == "chi" || lang == "zho"
                }
                let audioMatchesPreferred: (EmbyMediaStream) -> Bool = { stream in
                    let lang = (stream.Language ?? "").lowercased()
                    let title = stream.DisplayTitle ?? ""
                    switch Prefs.audioLanguage {
                    case "en": return lang.hasPrefix("en") || lang == "eng" || title.contains("英")
                    case "ja": return lang.hasPrefix("ja") || lang == "jpn" || title.contains("日")
                    case "ko": return lang.hasPrefix("ko") || lang == "kor" || title.contains("韩")
                    default: return isChineseAudio(stream)
                    }
                }
                let preferredAudio: EmbyMediaStream?
                if Prefs.rememberAudioChoice,
                   let remembered = Prefs.rememberedAudioIndex(for: item.SeriesId ?? item.Id),
                   let hit = audios.first(where: { $0.Index == remembered }) {
                    preferredAudio = hit
                } else if Prefs.audioLanguage == "default" {
                    preferredAudio = audios.first
                } else {
                    preferredAudio = audios.first(where: { audioMatchesPreferred($0) && !isTrueHD($0) })
                        ?? audios.first(where: { audioMatchesPreferred($0) })
                        ?? audios.first(where: { !isTrueHD($0) })
                        ?? audios.first
                }
                let ordinal = preferredAudio.flatMap { pick in audios.firstIndex(where: { $0.Index == pick.Index }) }
                let audioLabels = audios.map { $0.DisplayTitle ?? $0.Codec ?? "音轨" }
                let subtitleLabels = (source.MediaStreams ?? [])
                    .filter { $0.type == "Subtitle" }
                    .sorted { $0.Index < $1.Index }
                    .map { $0.DisplayTitle ?? $0.Codec ?? "字幕" }
                vlcRoute = VLCRoute(url: url, sourceID: source.Id, sessionID: info.PlaySessionId,
                                    preferredAudioOrdinal: ordinal,
                                    audioLabels: audioLabels, subtitleLabels: subtitleLabels,
                                    audioStreamIndexes: audios.map { $0.Index })
                return
            }
            session = (source.Id, info.PlaySessionId)
            currentStreamURL = url
            currentSource = source
            player.load(url, startTime: startSeconds > 5 ? .seconds(startSeconds) : nil)
            player.requestVideoFeatures([.nativeSubtitles])
            player.setSubtitlesVisible(true)
            currentRate = Prefs.defaultRate
            if Prefs.defaultRate != 1.0 { player.setPlaybackRate(Prefs.defaultRate) }
            Task { await prepareSubtitles() }
            Task { await prepareAudio() }
            await client.reportStart(itemID: item.Id, sourceID: source.Id, sessionID: info.PlaySessionId, positionSeconds: startSeconds)
            scheduleHide()
            startSleepTimer()
            fetchNextEpisode()
            fetchSegments()
            endWatchTask = Task { await watchForEnd() }
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

    private func isSimplifiedSub(language: String?, title: String?) -> Bool {
        let lang = (language ?? "").lowercased()
        if lang == "zh-hans" || lang == "zh-cn" { return true }
        let t = title ?? ""
        return t.contains("简") || t.localizedCaseInsensitiveContains("chs")
    }

    private func isTraditionalSub(language: String?, title: String?) -> Bool {
        let lang = (language ?? "").lowercased()
        if lang == "zh-hant" || lang == "zh-tw" || lang == "zh-hk" { return true }
        let t = title ?? ""
        return t.contains("繁") || t.localizedCaseInsensitiveContains("cht")
    }

    private func isEnglishSub(language: String?, title: String?) -> Bool {
        let lang = (language ?? "").lowercased()
        if lang.hasPrefix("en") || lang == "eng" { return true }
        let t = title ?? ""
        return t.contains("英") || t.localizedCaseInsensitiveContains("english")
    }

    /// Lower scores win; nil means the track does not match the
    /// configured subtitle preference at all.
    private func subtitlePrefScore(language: String?, title: String?) -> Int? {
        switch Prefs.subtitlePreference {
        case .zhHans:
            if isSimplifiedSub(language: language, title: title) { return 0 }
            if isChineseSub(language: language, title: title) { return 1 }
            return nil
        case .zhHant:
            if isTraditionalSub(language: language, title: title) { return 0 }
            if isChineseSub(language: language, title: title) { return 1 }
            return nil
        case .en:
            return isEnglishSub(language: language, title: title) ? 0 : nil
        case .off:
            return nil
        }
    }

    private func isChineseAudioTrack(_ track: MPVMediaTrack) -> Bool {
        let lang = (track.language ?? "").lowercased()
        if lang.hasPrefix("zh") || lang == "chi" || lang == "zho" { return true }
        let t = track.title ?? ""
        return t.contains("国语") || t.contains("中文") || t.contains("普通话")
    }

    private func audioTrackMatchesPreferred(_ track: MPVMediaTrack) -> Bool {
        let lang = (track.language ?? "").lowercased()
        let t = track.title ?? ""
        switch Prefs.audioLanguage {
        case "en": return lang.hasPrefix("en") || lang == "eng" || t.contains("英")
        case "ja": return lang.hasPrefix("ja") || lang == "jpn" || t.contains("日")
        case "ko": return lang.hasPrefix("ko") || lang == "kor" || t.contains("韩")
        default: return isChineseAudioTrack(track)
        }
    }

    /// Mirrors the VLCKit route's entry rule for the mpv engine: a
    /// remembered track (by stream ordinal) wins, then the preferred
    /// language avoiding TrueHD, applied once when tracks appear.
    private func prepareAudio() async {
        let key = item.SeriesId ?? item.Id
        let remembered = Prefs.rememberAudioChoice ? Prefs.rememberedAudioIndex(for: key) : nil
        guard remembered != nil || Prefs.audioLanguage != "default" else { return }
        let generation = playerGeneration
        for _ in 0..<16 {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == playerGeneration, !Task.isCancelled else { return }
            let audios = player.audioTracks
            guard !audios.isEmpty else { continue }
            if let remembered,
               let streams = currentSource?.MediaStreams?.filter({ $0.type == "Audio" }).sorted(by: { $0.Index < $1.Index }),
               let ordinal = streams.firstIndex(where: { $0.Index == remembered }),
               ordinal < audios.count {
                let target = audios[ordinal]
                if !target.isSelected { player.selectTrack(target.id) }
                return
            }
            if let selected = audios.first(where: { $0.isSelected }),
               audioTrackMatchesPreferred(selected),
               !(selected.codec ?? "").lowercased().contains("truehd") { return }
            guard let best = audios.first(where: { audioTrackMatchesPreferred($0) && !($0.codec ?? "").lowercased().contains("truehd") })
                    ?? audios.first(where: { audioTrackMatchesPreferred($0) }) else { return }
            player.selectTrack(best.id)
            return
        }
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
            if Prefs.subtitlePreference == .off {
                for ext in externals {
                    player.loadExternalSubtitle(ext.url, selecting: nil)
                }
            } else {
                let preferred = externals
                    .filter { subtitlePrefScore(language: $0.language, title: $0.title) != nil }
                    .min(by: { (subtitlePrefScore(language: $0.language, title: $0.title) ?? Int.max) < (subtitlePrefScore(language: $1.language, title: $1.title) ?? Int.max) })
                    ?? externals[0]
                for ext in externals where ext.url != preferred.url {
                    player.loadExternalSubtitle(ext.url, selecting: nil)
                }
                player.loadExternalSubtitle(preferred.url, selecting: .primary)
            }
        }

        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == playerGeneration, !Task.isCancelled else { return }
            let subs = player.subtitleTracks
            if subs.contains(where: { $0.isSelected }) { return }
            if Prefs.subtitlePreference == .off { return }
            let scored = subs
                .filter { subtitlePrefScore(language: $0.language, title: $0.title) != nil }
                .min(by: { (subtitlePrefScore(language: $0.language, title: $0.title) ?? Int.max) < (subtitlePrefScore(language: $1.language, title: $1.title) ?? Int.max) })
            guard let best = scored
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

    private func applyEntryOrientation() {
        switch Prefs.playerOrientation {
        case .landscape: requestOrientation(Prefs.landscapeMask)
        case .portrait: requestOrientation(.portrait)
        case .auto: break
        }
    }

    private func requestOrientation(_ mask: UIInterfaceOrientationMask) {
        AppDelegate.orientationMask = mask
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        guard mask != .all else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
            AppDelegate.lastOrientationError = "\(error)"
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
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { seekBy(-Prefs.seekStepSeconds) } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { player.togglePlayback() } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { seekBy(Prefs.seekStepSeconds) } }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in if !controlsLocked { handleDrag(value) } }
                    .onEnded { value in if !controlsLocked { handleDragEnd(value) } }
            )
            .onTapGesture { toggleChrome() }
            .simultaneousGesture(pressTracker)
    }

    // Press-and-hold boost, tracked from the raw touch stream: a
    // zero-distance drag sees every touch, and a 2-second timer
    // started at touch-down is the only path to engaging. Movement
    // past 10pt (a real drag) or lifting the finger cancels the
    // timer and restores the rate. The LongPressGesture machinery
    // this replaces fired on taps in builds 33-38 and then never
    // fired at all in build 39 - its state resets in this gesture
    // composition for reasons outside our control, so it is gone.
    private var pressTracker: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if pressStart == nil {
                    pressStart = value.time
                    pressTask?.cancel()
                    pressTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.0))
                        guard !Task.isCancelled, pressStart != nil, !pressBoosted else { return }
                        pressBoosted = true
                        startBoost()
                    }
                }
                if abs(value.translation.width) + abs(value.translation.height) > 10 {
                    pressTask?.cancel()
                    pressStart = nil
                    if pressBoosted { pressBoosted = false; endBoost() }
                }
            }
            .onEnded { _ in
                pressTask?.cancel()
                pressStart = nil
                if pressBoosted { pressBoosted = false; endBoost() }
            }
    }

    private func startBoost() {
        guard Prefs.longPressBoost, boostSavedRate == nil, !player.isPaused, !controlsLocked else { return }
        boostSavedRate = currentRate
        player.setPlaybackRate(Prefs.boostRate)
        gestureHint = String(format: "%g× 快进中", Prefs.boostRate)
    }

    private func endBoost() {
        guard let saved = boostSavedRate else { return }
        boostSavedRate = nil
        player.setPlaybackRate(saved)
        if gestureHint?.hasSuffix("快进中") == true { gestureHint = nil }
    }

    private var episodePicker: some View {
        NavigationStack {
            List(seasonEpisodes) { episode in
                Button {
                    showEpisodePicker = false
                    if episode.Id != item.Id { onPlayNext?(episode) }
                } label: {
                    HStack(spacing: 12) {
                        if let client = store.client() {
                            ItemImage(item: episode, client: client, kind: "Primary")
                                .frame(width: 96, height: 54)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text("第 \(episode.IndexNumber ?? 0) 集").font(.subheadline.bold())
                                .foregroundStyle(.primary)
                            Text(episode.Name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if episode.Id == item.Id {
                            Image(systemName: "play.fill").foregroundStyle(Color.accentColor)
                        } else if episode.resumeSeconds > 5 {
                            Text(formatDuration(episode.resumeSeconds))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(item.SeriesName ?? "选集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showEpisodePicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fetchNextEpisode() {
        guard item.type == "Episode", let seriesID = item.SeriesId,
              let seasonID = item.SeasonId, let client = store.client() else { return }
        Task {
            guard let episodes = try? await client.episodes(seriesID: seriesID, seasonID: seasonID) else { return }
            let sorted = episodes.sorted { ($0.IndexNumber ?? 0) < ($1.IndexNumber ?? 0) }
            seasonEpisodes = sorted
            if let index = sorted.firstIndex(where: { $0.Id == item.Id }), index + 1 < sorted.count {
                nextEpisode = sorted[index + 1]
            }
        }
    }

    private func watchForEnd() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            updateActiveSegment(position: player.position.secondsValue)
            if player.state == .ended {
                if Prefs.autoPlayNext, let nextEpisode { onPlayNext?(nextEpisode) }
                return
            }
        }
    }

    private func fetchSegments() {
        guard let client = store.client() else { return }
        Task { segments = await client.mediaSegments(itemID: item.Id) }
    }

    private func updateActiveSegment(position: Double) {
        guard Prefs.skipSegments else {
            if activeSegment != nil { activeSegment = nil }
            return
        }
        let hit = segments.first {
            position >= $0.startSeconds && position <= $0.endSeconds - 2 && ($0.isIntro || $0.isOutro)
        }
        if hit?.startSeconds != activeSegment?.startSeconds { activeSegment = hit }
    }

    private func skipActiveSegment() {
        guard let segment = activeSegment else { return }
        activeSegment = nil
        if segment.isOutro, let nextEpisode {
            onPlayNext?(nextEpisode)
        } else {
            player.seek(to: .seconds(segment.endSeconds + 0.3))
        }
    }

    private func startSleepTimer() {
        sleepTask?.cancel()
        let minutes = Prefs.sleepTimerMinutes
        guard minutes > 0 else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled else { return }
            if !player.isPaused { player.togglePlayback() }
        }
    }

    @State private var dragMode: DragMode?
    @State private var dragStartPosition: Double = 0
    @State private var dragStartLevel: Double = 0

    private enum DragMode { case scrub, brightness, volume }

    private func handleDrag(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        if dragMode == nil {
            if abs(dx) > abs(dy) {
                if Prefs.gestureScrub {
                    dragMode = .scrub
                    dragStartPosition = player.position.secondsValue
                    scrubbing = true
                }
            } else {
                let startX = value.startLocation.x
                let width = UIScreen.main.bounds.width
                let mode: DragMode = startX < width / 2 ? .brightness : .volume
                if (mode == .brightness && Prefs.gestureBrightness) || (mode == .volume && Prefs.gestureVolume) {
                    dragMode = mode
                    dragStartLevel = mode == .brightness
                        ? Double(UIScreen.main.brightness)
                        : player.volume / 100
                }
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
                if controlsLocked {
                    Spacer()
                    Button { controlsLocked = false; pokeChrome() } label: {
                        Image(systemName: "lock.fill").font(.title3)
                    }
                } else {
                if Prefs.showTitleInPlayer {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.Name).font(.subheadline.bold()).lineLimit(1)
                    if let series = item.SeriesName {
                        Text(series).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                }
                Spacer()
                if Prefs.showDiagnosticsButton {
                Button { showDiagnostics = true } label: {
                    Image(systemName: "info.circle").font(.title3)
                }
                }
                trackMenus
                Button { controlsLocked = true; pokeChrome() } label: {
                    Image(systemName: "lock.open").font(.title3)
                }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            if !controlsLocked {
            centerCluster

            Spacer()

            VStack(spacing: 6) {
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
                    Text(Prefs.timeMode == .remaining
                         ? "-" + formatDuration(max(player.duration.secondsValue - (scrubbing ? scrubValue : player.position.secondsValue), 0))
                         : formatDuration(player.duration.secondsValue))
                        .font(.caption.monospacedDigit())
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                if let error = player.lastError {
                    Text(String(describing: error)).font(.caption2).foregroundStyle(.red.opacity(0.9)).lineLimit(2)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
            }
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var centerCluster: some View {
        HStack(spacing: 30) {
            clusterButton(icon: "gobackward.\(Int(Prefs.seekStepSeconds))", size: 56) {
                player.seek(to: .seconds(max(0, player.position.secondsValue - Prefs.seekStepSeconds)))
                pokeChrome()
            }
            clusterButton(icon: player.isPaused ? "play.fill" : "pause.fill", size: 78) {
                player.togglePlayback()
                pokeChrome()
            }
            clusterButton(icon: "goforward.\(Int(Prefs.seekStepSeconds))", size: 56) {
                player.seek(to: .seconds(min(player.duration.secondsValue, player.position.secondsValue + Prefs.seekStepSeconds)))
                pokeChrome()
            }
        }
    }

    private func clusterButton(icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(.plain)
    }

    private var trackMenus: some View {
        HStack(spacing: 14) {
            if seasonEpisodes.count > 1 {
                Button { showEpisodePicker = true } label: {
                    Image(systemName: "list.bullet").font(.title3)
                }
            }
            if let nextEpisode {
                Button { onPlayNext?(nextEpisode) } label: {
                    Image(systemName: "forward.end.fill").font(.title3)
                }
            }
            if Prefs.showAudioButton, !player.audioTracks.isEmpty {
                Menu {
                    ForEach(player.audioTracks, id: \.mpvID) { track in
                        Button {
                            player.selectTrack(track.id)
                            if Prefs.rememberAudioChoice,
                               let ordinal = player.audioTracks.firstIndex(where: { $0.id == track.id }),
                               let streams = currentSource?.MediaStreams?.filter({ $0.type == "Audio" }).sorted(by: { $0.Index < $1.Index }),
                               ordinal < streams.count {
                                Prefs.rememberAudio(index: streams[ordinal].Index, for: item.SeriesId ?? item.Id)
                            }
                        } label: {
                            Label(trackLabel(track), systemImage: track.isSelected ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "waveform").font(.title3)
                }
            }
            if Prefs.showSubtitleButton, !player.subtitleTracks.isEmpty {
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
                    Button("\(rate, specifier: "%g")×") { player.setPlaybackRate(rate); currentRate = rate }
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
        lines.append("orientation: pref=\(Prefs.playerOrientation.rawValue) side=\(Prefs.landscapeSide.rawValue) mask=\(AppDelegate.orientationMask.rawValue) error=\(AppDelegate.lastOrientationError ?? "-")")
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
        let delay = Prefs.chromeHideSeconds
        guard delay > 0 else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            if !player.isPaused { chromeVisible = false }
        }
    }
}
