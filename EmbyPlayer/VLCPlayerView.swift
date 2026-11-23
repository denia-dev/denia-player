import AVFoundation
import MobileVLCKit
import SwiftUI
import UIKit

/// Route marker set by PlayerView when the chosen media source carries PGS
/// (bitmap) subtitles: MPVUI's renderers cannot composite those, libvlc can.
struct VLCRoute {
    let url: URL
    let sourceID: String
    let sessionID: String?
    /// Ordinal (among the file's audio streams) of the audio track to prefer:
    /// PlayerView picks a Chinese non-TrueHD track, because libvlc can fail
    /// silent on TrueHD/Atmos defaults.
    let preferredAudioOrdinal: Int?
    let audioLabels: [String]
    let subtitleLabels: [String]
    /// Emby stream Index for each audio ordinal, so a manual pick in
    /// the menu can be remembered per series.
    let audioStreamIndexes: [Int]
}

// MARK: - controller

final class VLCPlayerController: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    var player = VLCMediaPlayer()

    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var hasError = false
    @Published var hasEnded = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var audioTracks: [(id: Int32, name: String)] = []
    @Published var subtitleTracks: [(id: Int32, name: String)] = []
    @Published var selectedAudioID: Int32 = -1
    @Published var selectedSubtitleID: Int32 = -1
    @Published var rate: Float = 1

    private var mediaConfigured = false
    private var drawableAttached = false
    private weak var surfaceView: UIView?
    private var startSeconds: Double = 0
    private var didInitialSeek = false
    private var didAutoSelectSubtitle = false
    private var didAutoSelectAudio = false
    private var preferredAudioOrdinal: Int?
    private var loadDate = Date()
    private var resumeAttempts = 0
    private(set) var maxPosition: Double = 0
    private var desiredAudioOrdinal: Int?
    private var desiredSubtitleOrdinal: Int?
    private var desiredSubtitleOff = false
    private var lastPositionSample: Double = -1
    private var lastAdvanceAt = Date()
    private var selectionCounter = 0
    private var currentURL: URL?
    private var reloadTarget: Double?
    private var reloadSeekAttempts = 0
    private var needsPostReloadApply = false
    private var userPaused = false
    private let logStart = Date()
    private var eventLog: [String] = []
    private var lastSampleState: VLCMediaPlayerState?
    private var lastSampleAudio: Int32 = .min
    private var lastSampleSub: Int32 = .min

    func logEvent(_ message: String) {
        let t = Date().timeIntervalSince(logStart)
        eventLog.append(String(format: "[+%06.1fs] %@", t, message))
        if eventLog.count > 150 { eventLog.removeFirst(eventLog.count - 150) }
    }

    func diagnosticsDump() -> String {
        var lines: [String] = []
        lines.append("VLC DIAG build 21 (build16 base)")
        lines.append("state=\(player.state.rawValue) playing=\(player.isPlaying) pos=\(Int(position))/\(Int(duration))")
        lines.append("audio readback=\(player.currentAudioTrackIndex) selected=\(selectedAudioID) desiredOrdinal=\(desiredAudioOrdinal.map(String.init) ?? "-")")
        lines.append("sub readback=\(player.currentVideoSubTitleIndex) selected=\(selectedSubtitleID) desiredOrdinal=\(desiredSubtitleOrdinal.map(String.init) ?? "-") off=\(desiredSubtitleOff)")
        lines.append("audioTracks=\(audioTracks.map { "\($0.id):\($0.name)" }.joined(separator: " | "))")
        lines.append("subTracks=\(subtitleTracks.map { "\($0.id):\($0.name)" }.joined(separator: " | "))")
        if let media = player.media {
            lines.append("media decodedAudio=\(media.numberOfDecodedAudioBlocks) playedBuffers=\(media.numberOfPlayedAudioBuffers) lostBuffers=\(media.numberOfLostAudioBuffers)")
            lines.append("media decodedVideo=\(media.numberOfDecodedVideoBlocks) displayed=\(media.numberOfDisplayedPictures) lostPictures=\(media.numberOfLostPictures)")
            lines.append("media inputBitrate=\(media.inputBitrate) demuxBitrate=\(media.demuxBitrate)")
        }
        let session = AVAudioSession.sharedInstance()
        lines.append("audioSession category=\(session.category.rawValue) route=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ","))")
        lines.append("--- events ---")
        lines.append(contentsOf: eventLog)
        return lines.joined(separator: "\n")
    }

    func prepare(url: URL, startSeconds: Double, preferredAudioOrdinal: Int?) {
        guard !mediaConfigured else { return }
        mediaConfigured = true
        currentURL = url
        self.startSeconds = startSeconds
        self.preferredAudioOrdinal = preferredAudioOrdinal
        loadDate = Date()
        let media = VLCMedia(url: url)
        media.addOption("network-caching=15000")
        if startSeconds > 5 {
            media.addOption("start-time=\(Int(startSeconds))")
        }
        player.media = media
        player.delegate = self
        logEvent("prepare start=\(Int(startSeconds)) prefAudio=\(preferredAudioOrdinal ?? -1)")
        if drawableAttached { player.play() }
    }

    func attachDrawable(_ view: UIView) {
        surfaceView = view
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

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        let state = player.state
        hasError = state == .error
        position = Double(player.time.intValue) / 1000
        if let media = player.media, media.length.intValue > 0 {
            duration = Double(media.length.intValue) / 1000
        }
        if position > maxPosition { maxPosition = position }
        if position != lastPositionSample {
            lastPositionSample = position
            lastAdvanceAt = Date()
        }
        // libvlc's state can sit on .buffering while frames are flowing;
        // trust position movement over the raw state.
        let stalled = Date().timeIntervalSince(lastAdvanceAt) > 1.0
        isBuffering = !hasError && (state == .opening || (state == .buffering && stalled))
        isPlaying = !userPaused && state != .ended && state != .error
            && (state == .playing || !stalled || state == .buffering)
        if state == .ended { hasEnded = true }
        postReloadMaintenance(state: state)
        let sampleAudio = player.currentAudioTrackIndex
        let sampleSub = player.currentVideoSubTitleIndex
        if sampleAudio != lastSampleAudio || sampleSub != lastSampleSub || state != lastSampleState {
            logEvent("sample state=\(state.rawValue) audio=\(sampleAudio) sub=\(sampleSub) pos=\(Int(position))")
            lastSampleAudio = sampleAudio
            lastSampleSub = sampleSub
            lastSampleState = state
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
        // Resume enforcement: libvlc sometimes drops the start-time option
        // while the ES list is still settling; re-seek a few times early on.
        if startSeconds > 5, resumeAttempts < 3, state == .playing,
           Date().timeIntervalSince(loadDate) < 25,
           position < startSeconds - 3, !subtitleTracks.isEmpty {
            resumeAttempts += 1
            seek(to: startSeconds)
        }
    }

    /// Best known position for session reporting: a direct read wins over a
    /// possibly stale published value, and the value never rewinds.
    func directPosition() -> Double {
        max(Double(player.time.intValue) / 1000, maxPosition)
    }

    private func refreshTracks() {
        let audio = Self.trackList(names: player.audioTrackNames, indexes: player.audioTrackIndexes)
        if audio.count != audioTracks.count { audioTracks = audio }
        let subs = Self.trackList(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes)
        if subs.count != subtitleTracks.count { subtitleTracks = subs }
        // While a reload is in flight the readbacks are transient garbage;
        // keep the user's checkmark where they put it.
        let reloadInFlight = reloadTarget != nil || player.state == .opening
        if !reloadInFlight {
            if selectedAudioID != player.currentAudioTrackIndex {
                selectedAudioID = player.currentAudioTrackIndex
            }
            if selectedSubtitleID != player.currentVideoSubTitleIndex {
                selectedSubtitleID = player.currentVideoSubTitleIndex
            }
        }
        if !didAutoSelectAudio {
            let real = audioTracks.filter { $0.id >= 0 }
            if !real.isEmpty {
                didAutoSelectAudio = true
                desiredAudioOrdinal = desiredAudioOrdinal.flatMap { $0 < real.count ? $0 : nil }
                    ?? preferredAudioOrdinal.flatMap { $0 < real.count ? $0 : nil }
                    ?? (player.currentAudioTrackIndex < 0 ? 0 : nil)
                if let ordinal = desiredAudioOrdinal,
                   player.currentAudioTrackIndex != real[ordinal].id {
                    // One-time set inside the initial settling window; this
                    // is the only in-place track change that is safe.
                    player.currentAudioTrackIndex = real[ordinal].id
                    selectedAudioID = real[ordinal].id
                }
            }
        }
        if !didAutoSelectSubtitle, subtitleTracks.count > 1 {
            didAutoSelectSubtitle = true
            let real = subtitleTracks.filter { $0.id >= 0 }
            if desiredSubtitleOff {
                // Subtitles stay off for this player.
            } else if let ordinal = desiredSubtitleOrdinal, ordinal < real.count {
                if player.currentVideoSubTitleIndex != real[ordinal].id {
                    player.currentVideoSubTitleIndex = real[ordinal].id
                    selectedSubtitleID = real[ordinal].id
                }
            } else if player.currentVideoSubTitleIndex < 0, Prefs.subtitlePreference != .off {
                let pick = Self.subtitlePick(real) ?? real.first
                if let pick {
                    desiredSubtitleOrdinal = real.firstIndex(where: { $0.id == pick.id })
                    player.currentVideoSubTitleIndex = pick.id
                    selectedSubtitleID = pick.id
                }
            }
        }
    }

    /// The one-time entry subtitle pick, following the configured
    /// preference (VLCKit exposes track names only, so matching is by
    /// name, like the original Simplified-first rule).
    private static func subtitlePick(_ real: [(id: Int32, name: String)]) -> (id: Int32, name: String)? {
        switch Prefs.subtitlePreference {
        case .zhHans:
            return real.first(where: { $0.name.contains("简") }) ?? real.first(where: { $0.name.contains("中") })
        case .zhHant:
            return real.first(where: { $0.name.contains("繁") }) ?? real.first(where: { $0.name.contains("中") })
        case .en:
            return real.first(where: { $0.name.contains("英") || $0.name.localizedCaseInsensitiveContains("english") })
        case .off:
            return nil
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
        if player.isPlaying { player.pause(); userPaused = true } else { player.play(); userPaused = false }
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
        let real = audioTracks.filter { $0.id >= 0 }
        desiredAudioOrdinal = real.firstIndex(where: { $0.id == id })
        selectedAudioID = id
        logEvent("selectAudio id=\(id) ordinal=\(desiredAudioOrdinal ?? -1)")
        scheduleReload()
    }

    func selectSubtitle(_ id: Int32) {
        selectedSubtitleID = id
        if id < 0 {
            // Turning subtitles off needs no decoder; in-place is safe.
            desiredSubtitleOff = true
            desiredSubtitleOrdinal = nil
            player.currentVideoSubTitleIndex = -1
            return
        }
        desiredSubtitleOff = false
        let real = subtitleTracks.filter { $0.id >= 0 }
        desiredSubtitleOrdinal = real.firstIndex(where: { $0.id == id })
        logEvent("selectSubtitle id=\(id) ordinal=\(desiredSubtitleOrdinal ?? -1)")
        scheduleReload()
    }

    /// Mid-playback ES switches kill libvlc's audio/SPU pipelines for the
    /// rest of the session (builds 12-13: switched tracks stay silent /
    /// invisible, even switching back). The state that always works is a
    /// fresh input with the tracks preselected, so a manual switch reloads
    /// the stream at the current position with track-id options baked in.
    private func scheduleReload() {
        selectionCounter += 1
        let token = selectionCounter
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, token == self.selectionCounter else { return }
            self.reloadWithDesiredTracks()
        }
    }

    private func reloadWithDesiredTracks() {
        guard let url = currentURL else { return }
        let target = directPosition()
        reloadTarget = target
        reloadSeekAttempts = 0
        let media = VLCMedia(url: url)
        media.addOption("network-caching=15000")
        if target > 5 {
            media.addOption("start-time=\(Int(target))")
        }
        // Resolve the desired tracks from the CURRENT track lists by
        // ordinal (container order is stable even if ES ids drift).
        let realAudio = audioTracks.filter { $0.id >= 0 }
        if let ordinal = desiredAudioOrdinal, ordinal < realAudio.count {
            media.addOption("audio-track-id=\(realAudio[ordinal].id)")
        }
        let realSubs = subtitleTracks.filter { $0.id >= 0 }
        if !desiredSubtitleOff, let ordinal = desiredSubtitleOrdinal, ordinal < realSubs.count {
            media.addOption("sub-track-id=\(realSubs[ordinal].id)")
        }
        // Reusing one VLCMediaPlayer across set-media restarts leaves its
        // audio/SPU outputs wedged for good (builds 13-15: a switch that
        // lands silent also kills subtitles, nothing recovers). A fresh
        // player instance is the exact state a player entry creates, and
        // entry always works - so a track switch recreates the player.
        logEvent("reload target=\(Int(target)) audioOrdinal=\(desiredAudioOrdinal ?? -1) subOrdinal=\(desiredSubtitleOrdinal ?? -1) subOff=\(desiredSubtitleOff)")
        let old = player
        old.delegate = nil
        old.stop()
        let fresh = VLCMediaPlayer()
        fresh.delegate = self
        if let surfaceView { fresh.drawable = surfaceView }
        player = fresh
        fresh.media = media
        needsPostReloadApply = true
        didAutoSelectAudio = false
        didAutoSelectSubtitle = false
        logEvent("reloadRearmedSelection")
        fresh.play()
    }

    private func postReloadMaintenance(state: VLCMediaPlayerState) {
        guard state == .playing else { return }
        if needsPostReloadApply {
            needsPostReloadApply = false
            if rate != 1 { player.rate = rate }
        }
        if let target = reloadTarget {
            if abs(position - target) <= 3 {
                reloadTarget = nil
            } else if reloadSeekAttempts < 2, position > 0 {
                reloadSeekAttempts += 1
                seek(to: target)
            }
        }
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
    var onPlayNext: ((EmbyItem) -> Void)?

    @StateObject private var controller = VLCPlayerController()
    @State private var chromeVisible = true
    @State private var controlsLocked = false
    @State private var boostArmTask: Task<Void, Never>?
    @State private var hideTask: Task<Void, Never>?
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var gestureHint: String?
    @State private var diagText = ""
    @State private var showDiag = false
    @State private var dragMode: DragMode?
    @State private var dragStartPosition: Double = 0
    @State private var dragStartLevel: Double = 0
    @State private var boostSavedRate: Float?
    @GestureState private var boostPressing = false
    @State private var nextEpisode: EmbyItem?
    @State private var segments: [MediaSegment] = []
    @State private var activeSegment: MediaSegment?
    @State private var seasonEpisodes: [EmbyItem] = []
    @State private var showEpisodePicker = false
    @State private var sleepTask: Task<Void, Never>?

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
                    .glassEffect(.regular, in: Capsule())
                    .foregroundStyle(.white)
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
            .zIndex(10)
            .opacity(chromeVisible ? 1 : 0)
            .animation(.easeInOut(duration: 0.25), value: chromeVisible)
            .allowsHitTesting(chromeVisible)

            // Loading backdrop (see PlayerView): pretty glass from
            // the first second instead of glass over black.
            Group {
                if controller.duration == 0, let client = store.client() {
                    ItemImage(item: item, client: client, kind: wideImageKind(item))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .ignoresSafeArea()
                        .overlay(Color.black.opacity(0.25))
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.35), value: controller.duration == 0)
            .allowsHitTesting(false)

            if controller.isBuffering, !controller.hasError {
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
        .task {
            while !Task.isCancelled {
                controller.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .onAppear {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            controller.prepare(url: route.url, startSeconds: startSeconds, preferredAudioOrdinal: route.preferredAudioOrdinal)
            if Prefs.defaultRate != 1.0 { controller.setRate(Float(Prefs.defaultRate)) }
            scheduleHide()
            startSleepTimer()
            fetchNextEpisode()
            fetchSegments()
            if !Prefs.toastTitleOnPlay { chromeVisible = false }
        }
        .sheet(isPresented: $showDiag) { diagSheet }
        .onChange(of: controller.hasEnded) { _, ended in
            if ended, Prefs.autoPlayNext, let nextEpisode { onPlayNext?(nextEpisode) }
        }
        .onChange(of: controller.position) { _, position in
            updateActiveSegment(position: position)
        }
        .sheet(isPresented: $showEpisodePicker) { episodePicker }
        .onDisappear {
            hideTask?.cancel()
            sleepTask?.cancel()
            let client = store.client()
            let position = controller.directPosition()
            Task { await client?.reportStopped(itemID: item.Id, sourceID: route.sourceID, sessionID: route.sessionID, positionSeconds: position) }
            controller.player.stop()
        }
    }

    private var diagSheet: some View {
        NavigationStack {
            ScrollView {
                Text(diagText)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("VLC 诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("复制") { UIPasteboard.general.string = diagText }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { showDiag = false }
                }
            }
        }
    }

    // MARK: - reporting

    private func reportingLoop() async {
        guard let client = store.client() else { return }
        await client.reportStart(itemID: item.Id, sourceID: route.sourceID, sessionID: route.sessionID, positionSeconds: startSeconds)
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(10))
            guard controller.position > 0 else { continue }
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
                if controlsLocked {
                    Spacer()
                    Button { controlsLocked = false; pokeChrome() } label: {
                        Image(systemName: "lock.fill").font(.title3)
                    }
                } else {
                if Prefs.showTitleInPlayer {
                    Text(item.Name ?? "")
                        .font(.headline)
                        .lineLimit(1)
                }
                Spacer()
                trackMenus
                Button { controlsLocked = true; pokeChrome() } label: {
                    Image(systemName: "lock.open").font(.title3)
                }
                }
            }
            .padding(.horizontal)
            .padding(.top, 10)

            Spacer()

            if !controlsLocked {
            centerCluster

            Spacer()

            HStack(spacing: 10) {
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
                Text(Prefs.timeMode == .remaining
                     ? "-" + formatDuration(max(controller.duration - (scrubbing ? scrubValue : controller.position), 0))
                     : formatDuration(controller.duration))
                    .font(.caption.monospacedDigit())
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .glassEffect(.regular, in: Capsule())
            .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
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
                controller.seek(to: max(0, controller.position - Prefs.seekStepSeconds))
                pokeChrome()
            }
            clusterButton(icon: controller.isPlaying ? "pause.fill" : "play.fill", size: 78) {
                controller.togglePlay()
                pokeChrome()
            }
            clusterButton(icon: "goforward.\(Int(Prefs.seekStepSeconds))", size: 56) {
                controller.seek(to: min(controller.duration, controller.position + Prefs.seekStepSeconds))
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
            if Prefs.showDiagnosticsButton {
            Button {
                diagText = controller.diagnosticsDump()
                showDiag = true
            } label: {
                Image(systemName: "info.circle").font(.title3)
            }
            }
            if Prefs.showAudioButton, controller.audioTracks.count > 1 {
                Menu {
                    ForEach(Array(realAudioTracks.enumerated()), id: \.element.id) { ordinal, track in
                        Button {
                            controller.selectAudio(track.id)
                            if Prefs.rememberAudioChoice, ordinal < route.audioStreamIndexes.count {
                                Prefs.rememberAudio(index: route.audioStreamIndexes[ordinal], for: item.SeriesId ?? item.Id)
                            }
                        } label: {
                            Label(menuLabel(route.audioLabels, ordinal, fallback: track.name),
                                  systemImage: controller.selectedAudioID == track.id ? "checkmark" : "")
                        }
                    }
                } label: {
                    Image(systemName: "waveform").font(.title3)
                }
            }
            if Prefs.showSubtitleButton, controller.subtitleTracks.count > 1 {
                Menu {
                    Text("引擎：VLCKit（PGS 字幕）")
                    Button {
                        controller.selectSubtitle(-1)
                    } label: {
                        Label("关闭字幕", systemImage: controller.selectedSubtitleID < 0 ? "checkmark" : "")
                    }
                    ForEach(Array(realSubtitleTracks.enumerated()), id: \.element.id) { ordinal, track in
                        Button {
                            controller.selectSubtitle(track.id)
                        } label: {
                            Label(menuLabel(route.subtitleLabels, ordinal, fallback: track.name),
                                  systemImage: controller.selectedSubtitleID == track.id ? "checkmark" : "")
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

    private var realAudioTracks: [(id: Int32, name: String)] {
        controller.audioTracks.filter { $0.id >= 0 }
    }

    private var realSubtitleTracks: [(id: Int32, name: String)] {
        controller.subtitleTracks.filter { $0.id >= 0 }
    }

    private func menuLabel(_ labels: [String], _ ordinal: Int, fallback: String) -> String {
        labels.indices.contains(ordinal) && !labels[ordinal].isEmpty ? labels[ordinal] : fallback
    }

    // MARK: - gestures

    private var gestureLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                HStack(spacing: 0) {
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { controller.seekBy(-Prefs.seekStepSeconds); pokeChrome() } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { controller.togglePlay(); pokeChrome() } }
                    Color.clear.contentShape(Rectangle())
                        .onTapGesture(count: 2) { if !controlsLocked { controller.seekBy(Prefs.seekStepSeconds); pokeChrome() } }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in if !controlsLocked { handleDrag(value) } }
                    .onEnded { _ in if !controlsLocked { handleDragEnd() } }
            )
            .onTapGesture { toggleChrome() }
            .simultaneousGesture(boostGesture)
            .onChange(of: boostPressing) { _, pressing in
                // The gesture's value means "a finger is down", NOT
                // "the hold time was met" - it flips true at
                // touch-down, which is why taps flashed the boost
                // hint (builds 33-38). The arm timer is the real
                // gate: boost engages only after a continuous
                // 2-second press, by construction.
                boostArmTask?.cancel()
                if pressing {
                    boostArmTask = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2.0))
                        guard !Task.isCancelled else { return }
                        startBoost()
                    }
                } else {
                    endBoost()
                }
            }
    }

    // Press-and-hold boost via @GestureState: the state resets when
    // the gesture ends, fails or is cancelled, so the rate can never
    // stick (build 30's onEnded was skipped when a drag attempt
    // failed the press mid-way, leaving the boost on forever).
    private var boostGesture: some Gesture {
        LongPressGesture(minimumDuration: 2.0, maximumDistance: 12)
            .updating($boostPressing) { value, state, _ in state = value }
    }

    private func startBoost() {
        guard Prefs.longPressBoost, boostSavedRate == nil, controller.isPlaying, !controlsLocked else { return }
        boostSavedRate = controller.rate
        controller.setRate(Float(Prefs.boostRate))
        gestureHint = String(format: "%g× 快进中", Prefs.boostRate)
    }

    private func endBoost() {
        guard let saved = boostSavedRate else { return }
        boostSavedRate = nil
        controller.setRate(saved)
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
            controller.seek(to: segment.endSeconds + 0.3)
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
        }
    }

    private func startSleepTimer() {
        sleepTask?.cancel()
        let minutes = Prefs.sleepTimerMinutes
        guard minutes > 0 else { return }
        sleepTask = Task {
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled else { return }
            if controller.isPlaying { controller.togglePlay() }
        }
    }

    private func handleDrag(_ value: DragGesture.Value) {
        let dx = value.translation.width, dy = value.translation.height
        if dragMode == nil {
            if abs(dx) > abs(dy) {
                if Prefs.gestureScrub {
                    dragMode = .scrub
                    dragStartPosition = controller.position
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
                        : controller.volumeLevel
                }
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
        let delay = Prefs.chromeHideSeconds
        guard delay > 0 else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(delay))
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
