import AVKit
import MPVUI
import SwiftUI
import UIKit

extension Duration {
    var secondsValue: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// Which engine plays this item, decided once by PlayerView before any
/// player surface is created.
enum PlayerDecision {
    case vlc(VLCRoute)
    case mpv(MPVLaunch)
}

/// Everything the mpv screen needs to start without asking the server
/// again (a second PlaybackInfo would mint a second play session).
struct MPVLaunch {
    let url: URL
    let source: EmbyMediaSource?
    let sessionID: String?
}

/// Player entry point: decides the engine FIRST, then shows exactly one
/// full-screen player screen. Up to build 48 the VLC view was embedded
/// inside the mpv view's stack - two chromes, two gesture layers, two
/// close buttons in one hierarchy - and on PGS titles the VLC control
/// layer came out torn apart (info and slider at the top of the screen,
/// transport floating mid-screen, bottom empty). One screen, one engine,
/// no stacking. This container owns only the shared shell concerns:
/// engine decision, entry orientation and brightness save/restore.
struct PlayerView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: EmbyItem
    let startSeconds: Double
    var onPlayNext: ((EmbyItem) -> Void)?
    /// Offline playback (Downloads): when set, the local file is played
    /// directly - no server session, no reporting, position saved locally.
    var localFileURL: URL? = nil
    var localHasPGS: Bool = false
    var localAudioLabels: [String] = []
    var localSubtitleLabels: [String] = []

    @State private var decision: PlayerDecision?
    @State private var handoffLaunch: MPVLaunch?
    @State private var handoffPosition: Double?
    @State private var resolveError: String?
    /// False until the view has actually been laid out in landscape.
    /// The cover presents in portrait and the geometry update rotates a
    /// beat later; any chrome painted in between lands in portrait
    /// geometry and visibly jumps when the rotation lands (his
    /// long-standing "UI 错位 on entry"). Until `entered`, only the
    /// full-bleed poster backdrop shows - it is rotation-proof.
    @State private var entered = false
    /// Incremented on every geometry change; the entry gate opens only
    /// when the size has stayed put for a beat (see noteGeometry).
    @State private var sizeToken = 0
    @State private var savedBrightness: CGFloat = UIScreen.main.brightness

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !entered {
                if let client = store.client() {
                    ItemImage(item: item, client: client, kind: wideImageKind(item))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.25))
                }
            } else if let decision {
                switch decision {
                case .vlc(let route):
                    VLCPlayerView(item: item, route: route, startSeconds: startSeconds, onPlayNext: onPlayNext,
                                  switchToMPV: { position in performHandoff(position) })
                case .mpv(let launch):
                    MPVPlayerScreen(item: item, startSeconds: handoffPosition ?? startSeconds, onPlayNext: onPlayNext,
                                    localFileURL: localFileURL, localHasPGS: localHasPGS,
                                    localAudioLabels: localAudioLabels, localSubtitleLabels: localSubtitleLabels,
                                    launch: launch, continuingVLCSession: handoffPosition != nil)
                        .transition(.opacity)
                }
            } else {
                if let client = store.client() {
                    ItemImage(item: item, client: client, kind: wideImageKind(item))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.25))
                }
                if let resolveError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                        Text(resolveError).font(.footnote).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white)
                    .padding()
                } else {
                    ProgressView().tint(.white).scaleEffect(1.4)
                }
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
            }
        }
        .statusBarHidden(true)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { noteGeometry(geo.size) }
                    .onChange(of: geo.size) { _, size in noteGeometry(size) }
            }
        }
        .task { await resolve() }
        .task {
            // Rotation-locked phones refuse the landscape request; never
            // leave the player stuck on the backdrop in that case.
            try? await Task.sleep(for: .seconds(1.6))
            if !entered { withAnimation(.easeIn(duration: 0.2)) { entered = true } }
        }
        .onAppear {
            savedBrightness = UIScreen.main.brightness
            if Prefs.independentBrightness {
                UIScreen.main.brightness = CGFloat(Prefs.playerBrightness)
            }
            applyEntryOrientation()
        }
        .onDisappear {
            requestOrientation(.portrait)
            if Prefs.independentBrightness {
                Prefs.playerBrightness = Double(UIScreen.main.brightness)
            }
            UIScreen.main.brightness = savedBrightness
        }
    }

    /// Opens the gate only when the landscape size has STOPPED changing.
    /// Build 54 waited a fixed 120 ms after the first landscape size,
    /// but the cover's rotation animation is still interpolating the
    /// window frame then - the player screen was inserted mid-flight,
    /// painted its chrome at an intermediate geometry, and the chrome
    /// visibly JUMPED when the animation landed (his report on 54:
    /// "旋转后跳到那个位置"). Debouncing on stability inserts the
    /// screen only into final geometry.
    private func noteGeometry(_ size: CGSize) {
        guard size.width > size.height, !entered else { return }
        sizeToken += 1
        let token = sizeToken
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            if token == sizeToken, !entered {
                withAnimation(.easeIn(duration: 0.2)) { entered = true }
            }
        }
    }

    /// Decide the engine before any surface exists.
    /// VLC → MPV handoff for PiP (GPT's branch had this inline in the
    /// switch closure, where `decision` is the shadowed `if let` constant
    /// and cannot be assigned - CI build 63 caught it). The MPV screen
    /// inherits the position and the same Emby play session.
    private func performHandoff(_ position: Double) {
        guard let launch = handoffLaunch else { return }
        handoffPosition = position
        decision = .mpv(launch)
    }

    private func resolve() async {
        guard decision == nil else { return }
        if let localFileURL {
            handoffLaunch = MPVLaunch(url: localFileURL, source: nil, sessionID: nil)
            decision = localHasPGS
                ? .vlc(VLCRoute(url: localFileURL, sourceID: "", sessionID: nil,
                                preferredAudioOrdinal: nil,
                                audioLabels: localAudioLabels, subtitleLabels: localSubtitleLabels,
                                audioStreamIndexes: [], preferredSubtitleOrdinal: nil,
                                subtitleOff: false, subtitleStreamIndexes: [], isLocal: true))
                : .mpv(MPVLaunch(url: localFileURL, source: nil, sessionID: nil))
            return
        }
        guard let client = store.client() else { resolveError = "没有可用服务器"; return }
        do {
            let info = try await client.playbackInfo(itemID: item.Id, startSeconds: startSeconds)
            guard let source = info.MediaSources.first(where: { $0.SupportsDirectPlay == true }) ?? info.MediaSources.first else {
                resolveError = "服务器没有返回媒体源"
                return
            }
            guard let url = client.directStreamURL(itemID: item.Id, source: source, sessionID: info.PlaySessionId) else {
                resolveError = "无法生成直连地址"
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
                handoffLaunch = MPVLaunch(url: url, source: source, sessionID: info.PlaySessionId)
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
                let audioLabels = audios.map { stream in
                    let base = stream.DisplayTitle ?? stream.Codec ?? "音轨"
                    return stream.Channels.map { base + " · " + channelLayoutName($0) } ?? base
                }
                let subtitleStreams = (source.MediaStreams ?? [])
                    .filter { $0.type == "Subtitle" }
                    .sorted { $0.Index < $1.Index }
                let subtitleLabels = subtitleStreams.map { $0.DisplayTitle ?? $0.Codec ?? "字幕" }
                var preferredSubtitleOrdinal: Int? = nil
                var subtitleOff = false
                if Prefs.rememberSubtitleChoice,
                   let rememberedSub = Prefs.rememberedSubtitleIndex(for: item.SeriesId ?? item.Id) {
                    if rememberedSub < 0 { subtitleOff = true }
                    else { preferredSubtitleOrdinal = subtitleStreams.firstIndex(where: { $0.Index == rememberedSub }) }
                }
                decision = .vlc(VLCRoute(url: url, sourceID: source.Id, sessionID: info.PlaySessionId,
                                    preferredAudioOrdinal: ordinal,
                                    audioLabels: audioLabels, subtitleLabels: subtitleLabels,
                                    audioStreamIndexes: audios.map { $0.Index },
                                    preferredSubtitleOrdinal: preferredSubtitleOrdinal,
                                    subtitleOff: subtitleOff,
                                    subtitleStreamIndexes: subtitleStreams.map { $0.Index }))
                return
            }
            decision = .mpv(MPVLaunch(url: url, source: source, sessionID: info.PlaySessionId))
        } catch {
            resolveError = "加载失败：\(error.localizedDescription)"
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

}

/// The mpv player screen. Layout rule (from the post-mortem): the
/// rendering view is created once and never moves; gestures live on their
/// own transparent layer; chrome is a sibling overlay animated by opacity
/// only. PlayerView shows this screen only after the engine decision is
/// made, so it never shares its stack with the VLC view.
struct MPVPlayerScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: EmbyItem
    let startSeconds: Double
    var onPlayNext: ((EmbyItem) -> Void)?
    /// Offline playback (Downloads): when set, the local file is played
    /// directly - no server session, no reporting, position saved locally.
    var localFileURL: URL? = nil
    var localHasPGS: Bool = false
    var localAudioLabels: [String] = []
    var localSubtitleLabels: [String] = []
    /// Playback context resolved by the container before this screen
    /// exists, so it never has to ask the server again.
    let launch: MPVLaunch
    var continuingVLCSession = false

    @State private var player = MPVPlayerScreen.makePlayer(videoOutput:
        Prefs.pictureInPicture && !Prefs.appLock && AVPictureInPictureController.isPictureInPictureSupported()
            ? .sampleBuffer : .metal)
    @Environment(\.scenePhase) private var playbackScenePhase
    @State private var playerGeneration = 0
    @State private var currentStreamURL: URL?
    @State private var currentSource: EmbyMediaSource?
    @State private var preparedGeneration = -1

    static func makePlayer(videoOutput: MPVPlayerConfiguration.VideoOutput) -> MPVPlayer {
        // Subtitle styling from the subtitle settings (build 92).
        let subColorValue: String = {
            switch Prefs.subColorName {
            case "yellow": return "#FFFF00"
            case "cyan": return "#00FFFF"
            case "green": return "#7CFC00"
            default: return "#FFFFFF"
            }
        }()
        let subBorderValue: String = {
            switch Prefs.subBorderStyle {
            case "box": return "opaque-box"
            case "none": return "none"
            default: return "outline-and-shadow"
            }
        }()
        var options: [String: String] = [
            "sub-auto": "fuzzy",
            "slang": "zh-Hans,zh-CN,zh,chi,zho",
            "demuxer-max-bytes": "536870912",
            "demuxer-max-back-bytes": "268435456",
            // Smoothness batch 2: forward cache window (120 s default,
            // adjustable in 视频设置 since build 92) so brief network
            // stalls on the tunnel lines don't reach the decoder, and
            // reconnect on network errors too, not just stream errors.
            "cache": "yes",
            "cache-secs": "\(Prefs.cacheSeconds)",
            "demuxer-readahead-secs": "\(Prefs.cacheSeconds)",
            "stream-lavf-o": "reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=5",
            "vd-lavc-threads": "\(Prefs.softwareThreads)",
            "sub-scale": String(format: "%.2f", Prefs.subScale),
            "sub-delay": String(format: "%.1f", Prefs.subDelay),
            "audio-delay": String(format: "%.1f", Prefs.audioDelay),
            "sub-color": subColorValue,
            "sub-border-style": subBorderValue,
            "sub-margin-y": "\(Prefs.subMarginY)",
        ]
        // ASS subtitles carry their own colors and borders, and mpv's
        // default override mode keeps them - which would make the
        // color/border settings silently do nothing on exactly the
        // anime content he watches most. When he picks a non-default
        // color or border, force the override so the setting is real.
        if Prefs.subColorName != "white" || Prefs.subBorderStyle != "outline" {
            options["sub-ass-override"] = "force"
        }
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
            networkCacheDuration: .seconds(Prefs.cacheSeconds),
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
    @State private var currentRate: Double = 1
    @State private var boostSavedRate: Double?
    @State private var nextEpisode: EmbyItem?
    @State private var previousEpisode: EmbyItem?
    @State private var segments: [MediaSegment] = []
    @State private var autoSkippedStarts: Set<Double> = []
    @State private var translating = false
    @State private var translateProgressText = ""
    @State private var translateError: String?
    @State private var activeSegment: MediaSegment?
    @State private var seasonEpisodes: [EmbyItem] = []
    @State private var showEpisodePicker = false
    @State private var chapters: [EmbyChapter] = []
    @State private var showChapters = false
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
                    if player.pictureInPicture.isPossible && !Prefs.appLock {
                        Button { player.pictureInPicture.start() } label: {
                            Image(systemName: "pip.enter")
                                .frame(width: 44, height: 44)
                                .foregroundStyle(.white)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("进入画中画")
                        .disabled(player.pictureInPicture.isActive || player.pictureInPicture.isTransitioning)
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
        .alert("AI 翻译", isPresented: Binding(
            get: { translateError != nil },
            set: { if !$0 { translateError = nil } }
        )) {
            Button("好", role: .cancel) { translateError = nil }
        } message: {
            Text(translateError ?? "")
        }
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
        // Keep the full-screen cover and the same player mounted during PiP.
        // MPVUI restores the attached surface; only an actual dismissal tears it down.
        .onChange(of: playbackScenePhase) { _, phase in
            if phase == .background, !player.pictureInPicture.isActive,
               !player.pictureInPicture.isTransitioning { player.pause() }
        }
        .onChange(of: player.pictureInPicture.isActive) { wasActive, active in
            if wasActive && !active && playbackScenePhase == .background { player.pause() }
        }
        .task { await startPlayback() }
        .task { await progressLoop() }
        .onAppear {
            if !Prefs.toastTitleOnPlay { chromeVisible = false }
        }
        .overlay(alignment: .center) {
            SeekPreview(itemID: item.Id, client: localFileURL != nil ? nil : store.client(),
                        scrubbing: scrubbing, seconds: scrubValue, label: formatDuration(scrubValue))
                .id(item.Id)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .trailing) {
            if showEpisodePicker {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { showEpisodePicker = false }
                        episodePanel
                            .frame(width: geo.size.width * 0.44)
                    }
                }
                .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: showEpisodePicker)
        .sheet(isPresented: $showChapters) { chaptersSheet }
        .onDisappear {
            hideTask?.cancel()
            sleepTask?.cancel()
            endWatchTask?.cancel()
            if let session {
                let client = store.client()
                let position = player.position.secondsValue
                Task { await client?.reportStopped(itemID: item.Id, sourceID: session.sourceID, sessionID: session.sessionID, positionSeconds: position) }
            }
            if localFileURL != nil {
                DownloadsManager.savePosition(player.position.secondsValue, for: item.Id)
            }
            player.pictureInPicture.stop()
            player.stop()
        }
    }

    // MARK: - playback session

    private func startPlayback() async {
        if let localFileURL {
            player.load(localFileURL, startTime: startSeconds > 0 ? .seconds(startSeconds) : nil)
            player.requestVideoFeatures([.nativeSubtitles])
            player.setSubtitlesVisible(true)
            currentRate = Prefs.defaultRate
            if Prefs.defaultRate != 1.0 { player.setPlaybackRate(Prefs.defaultRate) }
            Task { await prepareAudio() }
            Task { await applySecondarySubtitle() }
            scheduleHide()
            startSleepTimer()
            endWatchTask = Task { await watchForEnd() }
            return
        }
        guard let source = launch.source, let client = store.client() else {
            loadError = "没有可用服务器"
            return
        }
        session = (source.Id, launch.sessionID)
        currentStreamURL = launch.url
        currentSource = source
        player.load(launch.url, startTime: startSeconds > 0 ? .seconds(startSeconds) : nil)
        player.requestVideoFeatures([.nativeSubtitles])
        player.setSubtitlesVisible(true)
        currentRate = Prefs.defaultRate
        if Prefs.defaultRate != 1.0 { player.setPlaybackRate(Prefs.defaultRate) }
        Task { await prepareSubtitles() }
        Task { await prepareAudio() }
        Task { await applySecondarySubtitle() }
        if !continuingVLCSession {
            await client.reportStart(itemID: item.Id, sourceID: source.Id, sessionID: launch.sessionID, positionSeconds: startSeconds)
        }
        scheduleHide()
        startSleepTimer()
        fetchNextEpisode()
        fetchChapters()
        fetchSegments()
        endWatchTask = Task { await watchForEnd() }
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
    /// given subtitle preference at all.
    private func subtitleScore(_ pref: Prefs.SubtitlePreference, language: String?, title: String?) -> Int? {
        switch pref {
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

    private func subtitlePrefScore(language: String?, title: String?) -> Int? {
        subtitleScore(Prefs.subtitlePreference, language: language, title: title)
    }

    /// Dual subtitles: when a secondary language is configured, pick the
    /// best matching track that is not the primary and show it as the
    /// secondary track. Runs once at playback start; manual picks in
    /// the subtitle menu afterwards are untouched.
    private func applySecondarySubtitle() async {
        let pref = Prefs.secondarySubtitlePreference
        guard pref != .off else { return }
        let generation = playerGeneration
        for _ in 0..<24 {
            try? await Task.sleep(for: .milliseconds(500))
            guard generation == playerGeneration, !Task.isCancelled else { return }
            let subs = player.subtitleTracks
            guard subs.count > 1 else { continue }
            if subs.contains(where: { $0.subtitleRole == .secondary }) { return }
            guard let primary = subs.first(where: { $0.isSelected }) else { continue }
            let best = subs
                .filter { $0.id != primary.id && subtitleScore(pref, language: $0.language, title: $0.title) != nil }
                .min(by: { (subtitleScore(pref, language: $0.language, title: $0.title) ?? Int.max) < (subtitleScore(pref, language: $1.language, title: $1.title) ?? Int.max) })
            guard let best else { return }
            player.selectSubtitle(best.id, for: .secondary)
            player.setSubtitlesVisible(true)
            return
        }
    }

    private var aiCachedForSelection: Bool {
        guard let selected = player.subtitleTracks.first(where: { $0.isSelected }),
              let ordinal = player.subtitleTracks.firstIndex(where: { $0.id == selected.id }),
              let streamIndex = subtitleStreamIndex(ordinal: ordinal) else { return false }
        return SubtitleTranslator.shared.cachedFile(itemID: item.Id, streamIndex: streamIndex) != nil
    }

    /// AI translation of the currently selected subtitle track: fetch
    /// its text from the server, translate via the configured API and
    /// load the result back as the primary (replace) or secondary
    /// (dual-subtitle) track.
    private func startAITranslation(mode: MPVSubtitleRole, force: Bool) {
        guard let source = currentSource, let client = store.client() else {
            translateError = "本地文件暂不支持 AI 翻译"
            return
        }
        guard let selected = player.subtitleTracks.first(where: { $0.isSelected }),
              let ordinal = player.subtitleTracks.firstIndex(where: { $0.id == selected.id }),
              let streamIndex = subtitleStreamIndex(ordinal: ordinal) else {
            translateError = "先选一条字幕，再用 AI 翻译"
            return
        }
        let codec = (source.MediaStreams?.first { $0.Index == streamIndex }?.Codec ?? "").lowercased()
        if codec.contains("pgs") || codec == "sup" || codec.contains("hdmv") {
            translateError = "这条是图片字幕（PGS），没有文本、翻译不了"
            return
        }
        guard let subtitleURL = client.subtitleStreamURL(itemID: item.Id, source: source, streamIndex: streamIndex) else { return }
        translating = true
        translateProgressText = "正在取字幕…"
        let generation = playerGeneration
        Task {
            do {
                let file = try await SubtitleTranslator.shared.translate(
                    itemID: item.Id, streamIndex: streamIndex, subtitleURL: subtitleURL, force: force
                ) { done, total in
                    Task { @MainActor in
                        if total > 0 { translateProgressText = "翻译中 \(done)/\(total) 批" }
                    }
                }
                guard generation == playerGeneration else { translating = false; return }
                player.loadExternalSubtitle(file, selecting: mode)
                player.setSubtitlesVisible(true)
            } catch {
                if generation == playerGeneration {
                    translateError = (error as? LocalizedError)?.errorDescription ?? "翻译失败：\(error.localizedDescription)"
                }
            }
            translating = false
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
            if Prefs.rememberSubtitleChoice,
               let remembered = Prefs.rememberedSubtitleIndex(for: item.SeriesId ?? item.Id) {
                if remembered < 0 { return }
                let streams = (currentSource?.MediaStreams ?? []).filter { $0.type == "Subtitle" }.sorted { $0.Index < $1.Index }
                if let ordinal = streams.firstIndex(where: { $0.Index == remembered }), ordinal < subs.count {
                    try? await Task.sleep(for: .seconds(1))
                    guard generation == playerGeneration else { return }
                    if !player.subtitleTracks.contains(where: { $0.isSelected }) {
                        player.requestVideoFeatures([.nativeSubtitles])
                        player.selectSubtitle(subs[ordinal].id)
                        player.setSubtitlesVisible(true)
                    }
                    return
                }
            }
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
                        .onTapGesture(count: 2) { if !controlsLocked { UIImpactFeedbackGenerator(style: .light).impactOccurred(); seekBy(-Prefs.seekStepSeconds) } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { player.togglePlayback() } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { UIImpactFeedbackGenerator(style: .light).impactOccurred(); seekBy(Prefs.seekStepSeconds) } }
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

    /// Episode picker docked to the right side of the player: the video
    /// keeps playing on the left while he browses (his request).
    private var episodePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.SeriesName ?? "选集").font(.headline).foregroundStyle(.white)
                Spacer()
                Button { showEpisodePicker = false } label: {
                    Image(systemName: "xmark").font(.subheadline.bold()).foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(seasonEpisodes) { episode in
                        Button {
                            showEpisodePicker = false
                            if episode.Id != item.Id { onPlayNext?(episode) }
                        } label: {
                            HStack(spacing: 10) {
                                if let client = store.client() {
                                    ItemImage(item: episode, client: client, kind: "Primary")
                                        .frame(width: 72, height: 41)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("第 \(episode.IndexNumber ?? 0) 集")
                                        .font(.caption.bold())
                                        .foregroundStyle(episode.Id == item.Id ? Color.accentColor : .white)
                                    Text(episode.Name).font(.caption2)
                                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                                Spacer()
                                if episode.Id == item.Id {
                                    Image(systemName: "play.fill").font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                } else if episode.resumeSeconds > 5 {
                                    Text(formatDuration(episode.resumeSeconds))
                                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(episode.Id == item.Id ? Color.white.opacity(0.12) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
    }


    private var chaptersSheet: some View {
        NavigationStack {
            List(Array(chapters.enumerated()), id: \.offset) { index, chapter in
                Button {
                    showChapters = false
                    player.seek(to: .seconds(chapter.startSeconds))
                    pokeChrome()
                } label: {
                    HStack {
                        Text(chapter.Name ?? "章节 \(index + 1)").lineLimit(1)
                        Spacer()
                        Text(formatDuration(chapter.startSeconds)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("章节")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("关闭") { showChapters = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func fetchChapters() {
        guard let client = store.client() else { return }
        Task {
            guard let full = try? await client.item(id: item.Id) else { return }
            let list = (full.Chapters ?? []).filter { $0.MarkerType == nil || $0.MarkerType == "Chapter" }
            if list.count > 1 { chapters = list }
        }
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
            if let index = sorted.firstIndex(where: { $0.Id == item.Id }), index > 0 {
                previousEpisode = sorted[index - 1]
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
        // Auto-skip: same action as the button, once per segment per
        // playback, and never while paused (a deliberate seek into the
        // intro while paused must not yank him out of it).
        if Prefs.autoSkipSegments, let hit, !player.isPaused,
           !autoSkippedStarts.contains(hit.startSeconds) {
            autoSkippedStarts.insert(hit.startSeconds)
            skipActiveSegment()
        }
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
            // Top bar: plain icons, no glass (his SenPlayer reference).
            HStack(spacing: 0) {
                // Symmetric side zones: the left one clears the always-on
                // close (+PiP) buttons in the overlay layer, the right one
                // mirrors it, so the title sits truly centered and can
                // never slide under either side (his 2026-11-23 report:
                // title collided with the close/PiP buttons).
                Color.clear.frame(width: 118, height: 1)
                if !controlsLocked, Prefs.showTitleInPlayer {
                    VStack(alignment: .center, spacing: 1) {
                        Text(item.Name).font(.subheadline.bold()).lineLimit(1)
                        if let series = item.SeriesName {
                            Text(series).font(.caption).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Spacer()
                }
                ZStack(alignment: .trailing) {
                    Color.clear.frame(width: 118, height: 1)
                    if !controlsLocked, Prefs.showDiagnosticsButton {
                        Button { showDiagnostics = true } label: {
                            Image(systemName: "info.circle").font(.title2)
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.top, 8)

            Spacer()

            if controlsLocked {
                HStack {
                    Button { controlsLocked = false; pokeChrome() } label: {
                        Image(systemName: "lock.fill").font(.title3)
                    }
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            } else {
                VStack(spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(streamInfoLine)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        circleMenus
                    }
                    .padding(.horizontal, 14)

                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Text(formatDuration(scrubbing ? scrubValue : player.position.secondsValue))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .glassEffect(.regular, in: Capsule())
                            Slider(value: Binding(
                                get: { scrubbing ? scrubValue : player.position.secondsValue },
                                set: { scrubValue = $0 }
                            ), in: 0...max(player.duration.secondsValue, 1)) { editing in
                                if editing { hideTask?.cancel(); scrubbing = true; scrubValue = player.position.secondsValue }
                                else {
                                    player.seek(to: .seconds(scrubValue))
                                    scrubbing = false
                                    pokeChrome()
                                }
                            }
                            .tint(.white)
                            .animation(scrubbing ? nil : .linear(duration: 0.35), value: player.position.secondsValue)
                            Text(Prefs.timeMode == .remaining
                                 ? "-" + formatDuration(max(player.duration.secondsValue - (scrubbing ? scrubValue : player.position.secondsValue), 0))
                                 : formatDuration(player.duration.secondsValue))
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .glassEffect(.regular, in: Capsule())
                        }
                        if let error = player.lastError {
                            Text(String(describing: error)).font(.caption2).foregroundStyle(.red.opacity(0.9)).lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 12)

                    HStack {
                        Button { controlsLocked = true; pokeChrome() } label: {
                            Image(systemName: "lock.open").font(.title3)
                        }
                        .frame(width: 34, alignment: .leading)
                        Spacer()
                        transportButtons
                        Spacer()
                        Group {
                            if seasonEpisodes.count > 1 {
                                Button { showEpisodePicker = true } label: {
                                    Image(systemName: "list.bullet").font(.title3)
                                }
                            } else {
                                Color.clear.frame(width: 34, height: 34)
                            }
                        }
                        .frame(width: 34, alignment: .trailing)
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }
        }
        .foregroundStyle(.white)
        .background(
            LinearGradient(colors: [.black.opacity(0.35), .clear, .black.opacity(0.45)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var transportButtons: some View {
        HStack(spacing: 36) {
            Button {
                if let previousEpisode { onPlayNext?(previousEpisode) }
                else { seekBy(-Prefs.seekStepSeconds) }
            } label: {
                Image(systemName: seasonEpisodes.count > 1 ? "backward.end.fill" : "gobackward.\(Int(Prefs.seekStepSeconds))")
                    .font(.title)
            }
            Button { player.togglePlayback(); pokeChrome() } label: {
                Image(systemName: player.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 36))
            }
            Button {
                if let nextEpisode { onPlayNext?(nextEpisode) }
                else { seekBy(Prefs.seekStepSeconds) }
            } label: {
                Image(systemName: seasonEpisodes.count > 1 ? "forward.end.fill" : "goforward.\(Int(Prefs.seekStepSeconds))")
                    .font(.title)
            }
        }
    }

    private var circleMenus: some View {
        HStack(spacing: 10) {
            if Prefs.showAudioButton, !player.audioTracks.isEmpty {
                Menu {
                    ForEach(Array(player.audioTracks.enumerated()), id: \.element.mpvID) { ordinal, track in
                        Button {
                            player.selectTrack(track.id)
                            if Prefs.rememberAudioChoice,
                               let streams = currentSource?.MediaStreams?.filter({ $0.type == "Audio" }).sorted(by: { $0.Index < $1.Index }),
                               ordinal < streams.count {
                                Prefs.rememberAudio(index: streams[ordinal].Index, for: item.SeriesId ?? item.Id)
                            }
                        } label: {
                            Label(audioTrackLabel(track, ordinal: ordinal), systemImage: track.isSelected ? "checkmark" : "")
                        }
                    }
                } label: { circleLabel("waveform") }
            }
            if Prefs.showSubtitleButton, !player.subtitleTracks.isEmpty {
                Menu {
                    Button("关闭字幕") {
                        player.selectSubtitle(nil)
                        rememberSubtitlePick(streamIndex: -1)
                    }
                    ForEach(player.subtitleTracks, id: \.mpvID) { track in
                        Button {
                            player.selectSubtitle(track.id)
                            player.setSubtitlesVisible(true)
                            if let ordinal = player.subtitleTracks.firstIndex(where: { $0.id == track.id }) {
                                rememberSubtitlePick(streamIndex: subtitleStreamIndex(ordinal: ordinal))
                            }
                        } label: {
                            Label(trackLabel(track), systemImage: track.isSelected ? "checkmark" : "")
                        }
                    }
                    if player.subtitleTracks.count > 1 {
                        Section("副字幕（双字幕）") {
                            Button("关闭副字幕") { player.selectSubtitle(nil, for: .secondary) }
                            ForEach(player.subtitleTracks, id: \.mpvID) { track in
                                Button {
                                    player.selectSubtitle(track.id, for: .secondary)
                                    player.setSubtitlesVisible(true)
                                } label: {
                                    Label(trackLabel(track), systemImage: track.subtitleRole == .secondary ? "checkmark" : "")
                                }
                            }
                        }
                    }
                    Section("AI 翻译") {
                        if translating {
                            Text(translateProgressText)
                        } else {
                            Button("译文替换当前字幕") { startAITranslation(mode: .primary, force: false) }
                            Button("双字幕显示译文") { startAITranslation(mode: .secondary, force: false) }
                            if aiCachedForSelection {
                                Button("重新翻译（不用缓存）") { startAITranslation(mode: .secondary, force: true) }
                            }
                        }
                    }
                } label: { circleLabel("captions.bubble") }
            }
            Menu {
                if let nextEpisode {
                    Button("下一集") { onPlayNext?(nextEpisode) }
                }
                if chapters.count > 1 {
                    Button("章节") { showChapters = true }
                }
                Section("倍速") {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate, specifier: "%g")×") { player.setPlaybackRate(rate); currentRate = rate }
                    }
                }
            } label: { circleLabel("ellipsis") }
        }
    }

    private func circleLabel(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .semibold))
            .frame(width: 38, height: 38)
            .background(Color.black.opacity(0.45), in: Circle())
    }

    /// "HW  HEVC  DV P7→P8.1  2160p  24FPS  63.0mbps" - whatever the
    /// engine actually reports, nothing invented.
    private var streamInfoLine: String {
        let media = player.mediaInformation
        let diag = player.playbackDiagnostics
        var parts: [String] = []
        if let hw = diag.decoder.videoToolboxSessionUsesHardware {
            parts.append(hw ? "HW" : "SW")
        }
        if let codec = media.videoCodec ?? diag.decoder.codec {
            parts.append(codec.uppercased())
        }
        if let profile = player.dolbyVisionStatus.sourceProfile {
            parts.append(Prefs.dvP7Convert && profile == 7 ? "DV P7→P8.1" : "DV")
        }
        if let dims = media.dimensions, dims.height > 0 {
            parts.append("\(dims.height)p")
        }
        if let fps = media.framesPerSecond, fps > 0 {
            parts.append("\(Int(fps.rounded()))FPS")
        }
        if let size = media.fileSize, let duration = media.duration, duration.secondsValue > 0 {
            parts.append(String(format: "%.1fmbps", Double(size) * 8 / duration.secondsValue / 1_000_000))
        }
        return parts.joined(separator: "  ")
    }


    private func audioTrackLabel(_ track: MPVMediaTrack, ordinal: Int) -> String {
        var label = trackLabel(track)
        let streams = (currentSource?.MediaStreams ?? []).filter { $0.type == "Audio" }.sorted { $0.Index < $1.Index }
        if ordinal < streams.count, let channels = streams[ordinal].Channels {
            label += " · " + channelLayoutName(channels)
        }
        return label
    }

    private func subtitleStreamIndex(ordinal: Int) -> Int? {
        let streams = (currentSource?.MediaStreams ?? []).filter { $0.type == "Subtitle" }.sorted { $0.Index < $1.Index }
        return ordinal < streams.count ? streams[ordinal].Index : nil
    }

    private func rememberSubtitlePick(streamIndex: Int?) {
        guard Prefs.rememberSubtitleChoice, let streamIndex else { return }
        Prefs.rememberSubtitle(index: streamIndex, for: item.SeriesId ?? item.Id)
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
        let media = player.mediaInformation
        // Keep this allowlist explicit: the model's sourceURL contains the Emby api_key.
        let duration = media.duration.map { String(format: "%.1f", $0.secondsValue) } ?? "-"
        lines.append("media container=\(media.container ?? "-") video=\(media.videoCodec ?? "-") audio=\(media.audioCodec ?? "-") size=\(media.fileSize.map { String($0) } ?? "-") dimensions=\(media.dimensions.map { "\($0.width)x\($0.height)" } ?? "-") fps=\(media.framesPerSecond.map { String(format: "%.3g", $0) } ?? "-") duration=\(duration)")
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
