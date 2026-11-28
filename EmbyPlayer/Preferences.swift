import SwiftUI
import UIKit

/// UserDefaults-backed interface/player preferences. The settings
/// pages write the same keys through @AppStorage; the players read
/// these accessors when they appear, so a change applies to the next
/// playback session with no observation plumbing.
enum Prefs {
    private static let d = UserDefaults.standard

    enum PlayerOrientation: String { case landscape, auto, portrait }
    enum LandscapeSide: String { case auto, left, right }
    enum TimeMode: String { case total, remaining }

    static var playerOrientation: PlayerOrientation {
        PlayerOrientation(rawValue: d.string(forKey: "prefs.playerOrientation") ?? "") ?? .landscape
    }
    static var landscapeSide: LandscapeSide {
        LandscapeSide(rawValue: d.string(forKey: "prefs.landscapeSide") ?? "") ?? .auto
    }
    static var landscapeMask: UIInterfaceOrientationMask {
        switch landscapeSide {
        case .auto: return .landscape
        case .left: return .landscapeLeft
        case .right: return .landscapeRight
        }
    }
    /// Seconds before the player chrome auto-hides; 0 = never.
    static var chromeHideSeconds: Double {
        d.object(forKey: "prefs.chromeHideSeconds") == nil ? 5 : d.double(forKey: "prefs.chromeHideSeconds")
    }
    static var timeMode: TimeMode {
        TimeMode(rawValue: d.string(forKey: "prefs.timeMode") ?? "") ?? .total
    }
    static var independentBrightness: Bool { d.bool(forKey: "prefs.independentBrightness") }
    static var playerBrightness: Double {
        get { d.object(forKey: "prefs.playerBrightness") == nil ? 0.7 : d.double(forKey: "prefs.playerBrightness") }
        set { d.set(newValue, forKey: "prefs.playerBrightness") }
    }
    static var toastTitleOnPlay: Bool {
        d.object(forKey: "prefs.toastTitleOnPlay") == nil ? true : d.bool(forKey: "prefs.toastTitleOnPlay")
    }
    static var showTitleInPlayer: Bool {
        d.object(forKey: "prefs.showTitleInPlayer") == nil ? true : d.bool(forKey: "prefs.showTitleInPlayer")
    }
    static var showDiagnosticsButton: Bool {
        d.object(forKey: "prefs.showDiagnosticsButton") == nil ? true : d.bool(forKey: "prefs.showDiagnosticsButton")
    }
    static var showAudioButton: Bool {
        d.object(forKey: "prefs.showAudioButton") == nil ? true : d.bool(forKey: "prefs.showAudioButton")
    }
    static var showSubtitleButton: Bool {
        d.object(forKey: "prefs.showSubtitleButton") == nil ? true : d.bool(forKey: "prefs.showSubtitleButton")
    }
    /// Danmaku (self-hosted danmu_api service; address + token come
    /// from the cloud config, not from a user setting).
    static var danmakuEnabled: Bool {
        d.object(forKey: "prefs.danmakuEnabled") == nil ? true : d.bool(forKey: "prefs.danmakuEnabled")
    }
    static var danmakuFontSize: Int {
        d.object(forKey: "prefs.danmakuFontSize") == nil ? 36 : d.integer(forKey: "prefs.danmakuFontSize")
    }
    /// Seconds a scrolling comment takes to cross the screen.
    static var danmakuScrollSeconds: Double {
        d.object(forKey: "prefs.danmakuScrollSeconds") == nil ? 8 : d.double(forKey: "prefs.danmakuScrollSeconds")
    }
    /// Which part of the screen scrolling danmaku may occupy:
    /// oneRow (his favourite, 2026-11-27), quarter, half, full.
    static var danmakuArea: String {
        d.string(forKey: "prefs.danmakuArea") ?? "oneRow"
    }
    /// Seek distance of the centre-cluster and double-tap shortcuts.
    static var seekStepSeconds: Double {
        d.object(forKey: "prefs.seekStepSeconds") == nil ? 15 : d.double(forKey: "prefs.seekStepSeconds")
    }
    static var defaultRate: Double {
        d.object(forKey: "prefs.defaultRate") == nil ? 1.0 : d.double(forKey: "prefs.defaultRate")
    }
    static var gestureBrightness: Bool {
        d.object(forKey: "prefs.gestureBrightness") == nil ? true : d.bool(forKey: "prefs.gestureBrightness")
    }
    static var gestureVolume: Bool {
        d.object(forKey: "prefs.gestureVolume") == nil ? true : d.bool(forKey: "prefs.gestureVolume")
    }
    static var gestureScrub: Bool {
        d.object(forKey: "prefs.gestureScrub") == nil ? true : d.bool(forKey: "prefs.gestureScrub")
    }

    // Video (mpv configuration; applied when the player is created)
    static var pictureInPicture: Bool { d.bool(forKey: "prefs.pictureInPicture") }
    static var decodeMode: String { d.string(forKey: "prefs.decodeMode") ?? "hardware" }
    /// AI upscaling shaders (v1.77): "off" | "anime" (Anime4K) |
    /// "general" (FSRCNNX). Applied at player creation via
    /// MPVRenderingQuality.shaders; see PlayerView.upscaleShaderURLs.
    static var upscaleMode: String { d.string(forKey: "prefs.upscaleMode") ?? "off" }
    static var softwareThreads: Int {
        d.object(forKey: "prefs.softwareThreads") == nil ? 8 : d.integer(forKey: "prefs.softwareThreads")
    }
    static var dvP7Convert: Bool {
        d.object(forKey: "prefs.dvP7Convert") == nil ? true : d.bool(forKey: "prefs.dvP7Convert")
    }
    // SDR → HDR was tried in v1.67 (inverse-tone-mapping option)
    // and removed in v1.69: he saw no effect, and the MPVUI source
    // shows why — the kernel reserves the whole target-* output
    // colour family (MPVOptionOwnership), so an SDR stream is
    // always rendered to an SDR target and inverse mapping has
    // nothing to expand into. No toggle is kept for a no-op.

    // Audio / subtitle entry preferences (defaults reproduce the
    // behaviour builds 4-27 shipped with)
    enum SubtitlePreference: String { case zhHans, zhHant, en, off }
    /// Preferred audio language: "default" (first track), zh, en, ja, ko.
    static var audioLanguage: String { d.string(forKey: "prefs.audioLanguage") ?? "zh" }
    static var rememberAudioChoice: Bool {
        d.object(forKey: "prefs.rememberAudioChoice") == nil ? true : d.bool(forKey: "prefs.rememberAudioChoice")
    }
    static func rememberedAudioIndex(for key: String) -> Int? {
        (d.dictionary(forKey: "prefs.rememberedAudio") as? [String: Int])?[key]
    }
    static func rememberAudio(index: Int, for key: String) {
        var map = (d.dictionary(forKey: "prefs.rememberedAudio") as? [String: Int]) ?? [:]
        map[key] = index
        d.set(map, forKey: "prefs.rememberedAudio")
    }
    static var rememberSubtitleChoice: Bool {
        d.object(forKey: "prefs.rememberSubtitleChoice") == nil ? true : d.bool(forKey: "prefs.rememberSubtitleChoice")
    }
    static func rememberedSubtitleIndex(for key: String) -> Int? {
        (d.dictionary(forKey: "prefs.rememberedSubtitle") as? [String: Int])?[key]
    }
    static func rememberSubtitle(index: Int, for key: String) {
        var map = (d.dictionary(forKey: "prefs.rememberedSubtitle") as? [String: Int]) ?? [:]
        map[key] = index
        d.set(map, forKey: "prefs.rememberedSubtitle")
    }
    /// Per-series playback rate, remembered from the rate menu.
    static func rememberedRate(for key: String) -> Double? {
        (d.dictionary(forKey: "prefs.rememberedRate") as? [String: Double])?[key]
    }
    static func rememberRate(_ rate: Double, for key: String) {
        var map = (d.dictionary(forKey: "prefs.rememberedRate") as? [String: Double]) ?? [:]
        map[key] = rate
        d.set(map, forKey: "prefs.rememberedRate")
    }
    /// Per-series secondary subtitle (stream index, -1 = off).
    static func rememberedSecondarySubtitleIndex(for key: String) -> Int? {
        (d.dictionary(forKey: "prefs.rememberedSecondarySub") as? [String: Int])?[key]
    }
    static func rememberSecondarySubtitle(index: Int, for key: String) {
        var map = (d.dictionary(forKey: "prefs.rememberedSecondarySub") as? [String: Int]) ?? [:]
        map[key] = index
        d.set(map, forKey: "prefs.rememberedSecondarySub")
    }
    static var sleepTimerMinutes: Int { d.integer(forKey: "prefs.sleepTimerMinutes") }
    static var longPressBoost: Bool {
        d.object(forKey: "prefs.longPressBoost") == nil ? true : d.bool(forKey: "prefs.longPressBoost")
    }
    static var boostRate: Double {
        d.object(forKey: "prefs.boostRate") == nil ? 2.0 : d.double(forKey: "prefs.boostRate")
    }
    static var autoPlayNext: Bool {
        d.object(forKey: "prefs.autoPlayNext") == nil ? true : d.bool(forKey: "prefs.autoPlayNext")
    }
    static var subScale: Double {
        d.object(forKey: "prefs.subScale") == nil ? 1.0 : d.double(forKey: "prefs.subScale")
    }
    static var subDelay: Double { d.double(forKey: "prefs.subDelay") }
    static var skipSegments: Bool {
        d.object(forKey: "prefs.skipSegments") == nil ? true : d.bool(forKey: "prefs.skipSegments")
    }
    static var appLock: Bool { d.bool(forKey: "prefs.appLock") }
    static var posterColumns: Int {
        let stored = d.integer(forKey: "prefs.posterColumns")
        return stored == 0 ? 3 : stored
    }
    static var subtitlePreference: SubtitlePreference {
        SubtitlePreference(rawValue: d.string(forKey: "prefs.subtitlePreference") ?? "") ?? .zhHans
    }
    /// Dual subtitles: language auto-picked as the secondary track at
    /// playback start (mpv only). Defaults off.
    static var secondarySubtitlePreference: SubtitlePreference {
        SubtitlePreference(rawValue: d.string(forKey: "prefs.secondarySubtitle") ?? "") ?? .off
    }
    /// Skip intro/outro automatically instead of waiting for the button.
    static var autoSkipSegments: Bool { d.bool(forKey: "prefs.autoSkipSegments") }
    static var audioDelay: Double { d.double(forKey: "prefs.audioDelay") }
    /// "Listen mode": keep the audio playing when the app goes to the
    /// background instead of auto-pausing (mpv player).
    static var backgroundAudio: Bool { d.bool(forKey: "prefs.backgroundAudio") }
    // Player top info strip (OSD): clock / battery / fps+resolution.
    static var osdShowClock: Bool { d.bool(forKey: "prefs.osdClock") }
    static var osdShowBattery: Bool { d.bool(forKey: "prefs.osdBattery") }
    static var osdShowStats: Bool { d.bool(forKey: "prefs.osdStats") }

    // AI subtitle translation (OpenAI-compatible chat completions API;
    // the key itself lives in the Keychain, not UserDefaults)
    static var aiEndpoint: String { d.string(forKey: "prefs.aiEndpoint") ?? "https://api.deepseek.com" }
    static var aiModel: String { d.string(forKey: "prefs.aiModel") ?? "deepseek-chat" }
    static var aiTargetLang: String { d.string(forKey: "prefs.aiTargetLang") ?? "zh-Hans" }
    static var aiTargetName: String {
        switch aiTargetLang {
        case "zh-Hant": return "Traditional Chinese"
        case "en": return "English"
        case "ja": return "Japanese"
        case "ko": return "Korean"
        default: return "Simplified Chinese"
        }
    }

    // Subtitle styling (build 92, SenPlayer parity; mpv text subtitles)
    /// "white" | "yellow" | "cyan" | "green"
    static var subColorName: String { d.string(forKey: "prefs.subColor") ?? "white" }
    /// "outline" | "box" | "none"
    static var subBorderStyle: String { d.string(forKey: "prefs.subBorder") ?? "outline" }
    static var subMarginY: Int {
        d.object(forKey: "prefs.subMarginY") == nil ? 20 : d.integer(forKey: "prefs.subMarginY")
    }

    // Appearance (build 92): "system" | "light" | "dark"
    static var appearance: String { d.string(forKey: "prefs.appearance") ?? "system" }

    // Forward cache window for the mpv player (build 92; was a
    // hardcoded 120 s in makePlayer).
    static var cacheSeconds: Int {
        d.object(forKey: "prefs.cacheSeconds") == nil ? 120 : d.integer(forKey: "prefs.cacheSeconds")
    }

    // Downloads (build 92)
    static var downloadMaxConcurrent: Int {
        d.object(forKey: "prefs.downloadMaxConcurrent") == nil ? 2 : d.integer(forKey: "prefs.downloadMaxConcurrent")
    }
    static var downloadWiFiOnly: Bool { d.bool(forKey: "prefs.downloadWiFiOnly") }

    // Home modules + start tab
    static var showHomeResume: Bool {
        d.object(forKey: "prefs.showHomeResume") == nil ? true : d.bool(forKey: "prefs.showHomeResume")
    }
    static var showHomeLibraries: Bool {
        d.object(forKey: "prefs.showHomeLibraries") == nil ? true : d.bool(forKey: "prefs.showHomeLibraries")
    }
    // prefs.showHomeLatest was removed in v1.73 with the section
    // itself (his call: 最新添加删掉).
    /// 0-4 = that tab; -1 = whichever tab was used last.
    static var startTab: Int {
        d.object(forKey: "prefs.startTab") == nil ? 0 : d.integer(forKey: "prefs.startTab")
    }
}

// MARK: - Shared settings-page building blocks (SenPlayer-style cards)

private func prefsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 0) { content() }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24))
}

private func prefsSectionLabel(_ title: String) -> some View {
    Text(title)
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.leading, 20)
}

private var prefsDivider: some View {
    Divider().padding(.leading, 20)
}

private func prefsLinkRow(_ title: String, icon: String, color: Color, route: Route) -> some View {
    NavigationLink(value: route) {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [color, color.opacity(0.68)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 30, height: 30)
                .overlay(Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(.white))
                .shadow(color: color.opacity(0.28), radius: 3, x: 0, y: 1.5)
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

private func prefsToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
    Toggle(title, isOn: isOn)
        .padding(.horizontal, 20)
        .frame(minHeight: 54)
}

/// One option inside a prefsMenuRow menu, with a checkmark on
/// the currently selected value (his 2026-11-27 report: the
/// menus gave no indication of which option was active).
@ViewBuilder
private func optButton(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        if selected {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }
}

private func prefsMenuRow<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
    Menu {
        content()
    } label: {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .contentShape(Rectangle())
    }
    // 全局 tint 是蓝色，Menu 标签会被它染成蓝色、值更是淡蓝（太浅）；
    // 这里把菜单行钉回主色，标题黑、值深灰。
    .tint(.primary)
}

// MARK: - 界面偏好

struct InterfacePrefsView: View {
    @AppStorage("prefs.playerOrientation") private var orientation = "landscape"
    @AppStorage("prefs.landscapeSide") private var landscapeSide = "auto"
    @AppStorage("prefs.chromeHideSeconds") private var hideSeconds = 5.0
    @AppStorage("prefs.timeMode") private var timeMode = "total"
    @AppStorage("prefs.independentBrightness") private var independentBrightness = false
    @AppStorage("prefs.toastTitleOnPlay") private var toastTitle = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsLinkRow("OSD 信息显示", icon: "text.bubble.fill", color: .purple, route: .osdPrefs)
                    Divider().padding(.leading, 62)
                    prefsLinkRow("自定义播放器按钮", icon: "button.programmable", color: .indigo, route: .buttonPrefs)
                }

                prefsSectionLabel("亮度").padding(.top, 8)
                prefsCard {
                    prefsToggleRow("播放器独立亮度", isOn: $independentBrightness)
                }

                prefsSectionLabel("控制栏").padding(.top, 8)
                prefsCard {
                    prefsMenuRow("进度条时间模式", value: timeMode == "remaining" ? "剩余时间" : "总时长") {
                        optButton("总时长", timeMode == "total") { timeMode = "total" }
                        optButton("剩余时间", timeMode == "remaining") { timeMode = "remaining" }
                    }
                    prefsDivider
                    prefsMenuRow("自动隐藏", value: hideSeconds == 0 ? "永不" : "\(Int(hideSeconds)) 秒") {
                        optButton("3 秒", hideSeconds == 3) { hideSeconds = 3 }
                        optButton("5 秒", hideSeconds == 5) { hideSeconds = 5 }
                        optButton("8 秒", hideSeconds == 8) { hideSeconds = 8 }
                        optButton("永不", hideSeconds == 0) { hideSeconds = 0 }
                    }
                }

                prefsSectionLabel("屏幕方向").padding(.top, 8)
                prefsCard {
                    prefsMenuRow("进入播放器屏幕方向", value: orientationLabel) {
                        optButton("强制横屏", orientation == "landscape") { orientation = "landscape" }
                        optButton("跟随设备", orientation == "auto") { orientation = "auto" }
                        optButton("强制竖屏", orientation == "portrait") { orientation = "portrait" }
                    }
                    prefsDivider
                    prefsMenuRow("设备横屏方向", value: sideLabel) {
                        optButton("自动", landscapeSide == "auto") { landscapeSide = "auto" }
                        optButton("左横屏", landscapeSide == "left") { landscapeSide = "left" }
                        optButton("右横屏", landscapeSide == "right") { landscapeSide = "right" }
                    }
                }

                prefsSectionLabel("提示信息").padding(.top, 8)
                prefsCard {
                    prefsToggleRow("开始播放提示标题", isOn: $toastTitle)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("界面偏好")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var orientationLabel: String {
        switch orientation {
        case "auto": return "跟随设备"
        case "portrait": return "强制竖屏"
        default: return "强制横屏"
        }
    }

    private var sideLabel: String {
        switch landscapeSide {
        case "left": return "左横屏"
        case "right": return "右横屏"
        default: return "自动"
        }
    }
}

// MARK: - OSD 信息显示

struct OSDPrefsView: View {
    @AppStorage("prefs.showTitleInPlayer") private var showTitle = true
    @AppStorage("prefs.showDiagnosticsButton") private var showDiagnostics = true
    @AppStorage("prefs.osdClock") private var osdClock = false
    @AppStorage("prefs.osdBattery") private var osdBattery = false
    @AppStorage("prefs.osdStats") private var osdStats = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("显示标题", isOn: $showTitle)
                    prefsDivider
                    prefsToggleRow("显示诊断按钮", isOn: $showDiagnostics)
                }
                prefsCard {
                    prefsToggleRow("顶部信息条：时间", isOn: $osdClock)
                    prefsDivider
                    prefsToggleRow("顶部信息条：电量", isOn: $osdBattery)
                    prefsDivider
                    prefsToggleRow("顶部信息条：帧率与分辨率", isOn: $osdStats)
                }
                Text("顶部信息条在播放画面上方常驻显示（mpv 播放器），控制条收起时也在。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                Text("在播放器控制栏顶部显示的标题与诊断入口。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("OSD 信息显示")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 自定义播放器按钮

struct ButtonPrefsView: View {
    @AppStorage("prefs.showAudioButton") private var showAudio = true
    @AppStorage("prefs.showSubtitleButton") private var showSubtitle = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("音轨按钮", isOn: $showAudio)
                    prefsDivider
                    prefsToggleRow("字幕按钮", isOn: $showSubtitle)
                }
                Text("关闭后，对应按钮不再出现在播放器控制栏里；倍速按钮始终保留。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("自定义播放器按钮")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 播放设置

struct PlaybackPrefsView: View {
    @AppStorage("prefs.seekStepSeconds") private var seekStep = 15.0
    @AppStorage("prefs.defaultRate") private var defaultRate = 1.0
    @AppStorage("prefs.sleepTimerMinutes") private var sleepMinutes = 0
    @AppStorage("prefs.autoPlayNext") private var autoPlayNext = true
    @AppStorage("prefs.skipSegments") private var skipSegments = true
    @AppStorage("prefs.autoSkipSegments") private var autoSkipSegments = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("快进 / 快退秒数", value: "\(Int(seekStep)) 秒") {
                        optButton("10 秒", seekStep == 10) { seekStep = 10 }
                        optButton("15 秒", seekStep == 15) { seekStep = 15 }
                        optButton("30 秒", seekStep == 30) { seekStep = 30 }
                    }
                    prefsDivider
                    prefsMenuRow("默认播放速度", value: rateLabel) {
                        optButton("0.75×", defaultRate == 0.75) { defaultRate = 0.75 }
                        optButton("1×", defaultRate == 1.0) { defaultRate = 1.0 }
                        optButton("1.25×", defaultRate == 1.25) { defaultRate = 1.25 }
                        optButton("1.5×", defaultRate == 1.5) { defaultRate = 1.5 }
                        optButton("2×", defaultRate == 2.0) { defaultRate = 2.0 }
                    }
                    prefsDivider
                    prefsMenuRow("睡眠定时", value: sleepMinutes == 0 ? "关闭" : "\(sleepMinutes) 分钟") {
                        optButton("关闭", sleepMinutes == 0) { sleepMinutes = 0 }
                        optButton("15 分钟", sleepMinutes == 15) { sleepMinutes = 15 }
                        optButton("30 分钟", sleepMinutes == 30) { sleepMinutes = 30 }
                        optButton("45 分钟", sleepMinutes == 45) { sleepMinutes = 45 }
                        optButton("60 分钟", sleepMinutes == 60) { sleepMinutes = 60 }
                    }
                    prefsDivider
                    prefsToggleRow("自动播放下一集", isOn: $autoPlayNext)
                    prefsDivider
                    prefsToggleRow("跳过片头片尾按钮", isOn: $skipSegments)
                    prefsDivider
                    prefsToggleRow("自动跳过片头片尾", isOn: $autoSkipSegments)
                }
                Text("快进 / 快退秒数同时作用于播放器中央按钮与双击快进；默认播放速度在每次打开播放器时生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("播放设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var rateLabel: String {
        defaultRate == 1.0 ? "1×" : String(format: "%g×", defaultRate)
    }
}

// MARK: - 播放手势

struct GesturePrefsView: View {
    @AppStorage("prefs.gestureBrightness") private var brightness = true
    @AppStorage("prefs.gestureVolume") private var volume = true
    @AppStorage("prefs.gestureScrub") private var scrub = true
    @AppStorage("prefs.longPressBoost") private var boost = true
    @AppStorage("prefs.boostRate") private var boostRate = 2.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("亮度手势（左半屏上下滑）", isOn: $brightness)
                    prefsDivider
                    prefsToggleRow("音量手势（右半屏上下滑）", isOn: $volume)
                    prefsDivider
                    prefsToggleRow("进度手势（左右滑）", isOn: $scrub)
                    prefsDivider
                    prefsToggleRow("长按倍速播放", isOn: $boost)
                    prefsDivider
                    prefsMenuRow("长按倍速", value: String(format: "%g×", boostRate)) {
                        optButton("1.5×", boostRate == 1.5) { boostRate = 1.5 }
                        optButton("2×", boostRate == 2.0) { boostRate = 2.0 }
                        optButton("3×", boostRate == 3.0) { boostRate = 3.0 }
                    }
                }
                Text("长按倍速播放：播放中长按画面不放，以设定倍速快进，松手恢复原速度。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
                Text("单击画面显示 / 隐藏控制栏、双击快进快退不受这些开关影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("播放手势")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 视频设置

struct VideoPrefsView: View {
    @AppStorage("prefs.pictureInPicture") private var pictureInPicture = false
    @AppStorage("prefs.decodeMode") private var decodeMode = "hardware"
    @AppStorage("prefs.softwareThreads") private var threads = 8
    @AppStorage("prefs.dvP7Convert") private var p7Convert = true
    @AppStorage("prefs.cacheSeconds") private var cacheSeconds = 120
    @AppStorage("prefs.upscaleMode") private var upscaleMode = "off"
    @AppStorage("diag.upscaleLast") private var upscaleDiag = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("系统画中画（MPV）", isOn: $pictureInPicture)
                    Text("下次打开视频时生效。播放后点小窗按钮即可离开 App 继续观看。PGS 影片可在 VLC 更多菜单切换至 MPV。开启应用锁时不可用。")
                        .font(.footnote).foregroundStyle(.secondary)
                    prefsDivider
                    prefsMenuRow("首选解码模式", value: decodeLabel) {
                        optButton("自动", decodeMode == "auto") { decodeMode = "auto" }
                        optButton("硬解码 (HW/GPU)", decodeMode == "hardware") { decodeMode = "hardware" }
                        optButton("软解码", decodeMode == "software") { decodeMode = "software" }
                    }
                    prefsDivider
                    prefsMenuRow("软件解码线程", value: "\(threads)") {
                        optButton("2", threads == 2) { threads = 2 }
                        optButton("4", threads == 4) { threads = 4 }
                        optButton("8", threads == 8) { threads = 8 }
                        optButton("16", threads == 16) { threads = 16 }
                    }
                    prefsDivider
                    prefsMenuRow("预读缓存", value: "\(cacheSeconds) 秒") {
                        optButton("60 秒", cacheSeconds == 60) { cacheSeconds = 60 }
                        optButton("120 秒", cacheSeconds == 120) { cacheSeconds = 120 }
                        optButton("180 秒", cacheSeconds == 180) { cacheSeconds = 180 }
                        optButton("300 秒", cacheSeconds == 300) { cacheSeconds = 300 }
                    }
                }
                Text("硬解码：高效省电，基本不发热，能否硬解取决于设备与系统。软解码：兼容性强，但播放大文件容易发热且耗电量高。除非无法正常播放，否则不要使用软解码。预读缓存越大越抗网络抖动，也越占内存；下次打开视频时生效。以上设置作用于 mpv 引擎；VLCKit 引擎（PGS 字幕片源）使用其内置解码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                prefsCard {
                    prefsToggleRow("杜比 P7 转杜比 P8.1", isOn: $p7Convert)
                }
                Text("开启后，杜比视界 Profile 7 片源会转成 P8.1 兼容播放（与 SenPlayer 同名开关行为一致）；关闭则按严格模式处理，个别片源可能无法播放。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                prefsCard {
                    prefsMenuRow("画质增强（AI 超分）", value: upscaleLabel) {
                        optButton("关闭", upscaleMode == "off") { upscaleMode = "off" }
                        optButton("动漫增强（Anime4K）", upscaleMode == "anime") { upscaleMode = "anime" }
                        optButton("通用增强（FSRCNNX）", upscaleMode == "general") { upscaleMode = "general" }
                    }
                }
                Text("播放时用 GPU 着色器实时放大增强：动漫选 Anime4K（修复线条＋2 倍放大），真人影视选 FSRCNNX。在播放器「…」菜单里切换即时生效；仅 mpv 引擎，杜比视界影片不生效。开启超分时画中画让位（着色器在画中画输出通道上会被内核跳过）。会增加发热，片源本身已是 4K 时提升不大。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                if !upscaleDiag.isEmpty {
                    Text("上次打开视频时：\(upscaleDiag)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }

            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("视频设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var decodeLabel: String {
        switch decodeMode {
        case "auto": return "自动"
        case "software": return "软解码"
        default: return "硬解码 (HW/GPU)"
        }
    }

    private var upscaleLabel: String {
        switch upscaleMode {
        case "anime": return "动漫增强（Anime4K）"
        case "general": return "通用增强（FSRCNNX）"
        default: return "关闭"
        }
    }
}

// MARK: - 音频设置

struct AudioPrefsView: View {
    @AppStorage("prefs.rememberAudioChoice") private var rememberChoice = true
    @AppStorage("prefs.audioLanguage") private var audioLanguage = "zh"
    @AppStorage("prefs.audioDelay") private var audioDelay = 0.0
    @AppStorage("prefs.backgroundAudio") private var backgroundAudio = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("记住所选音轨", isOn: $rememberChoice)
                    prefsDivider
                    prefsMenuRow("音频首选语言", value: languageLabel) {
                        optButton("默认", audioLanguage == "default") { audioLanguage = "default" }
                        optButton("中文", audioLanguage == "zh") { audioLanguage = "zh" }
                        optButton("英文", audioLanguage == "en") { audioLanguage = "en" }
                        optButton("日语", audioLanguage == "ja") { audioLanguage = "ja" }
                        optButton("韩语", audioLanguage == "ko") { audioLanguage = "ko" }
                    }
                    prefsDivider
                    prefsMenuRow("音频延迟", value: audioDelayLabel) {
                        optButton("延后 2 秒", audioDelay == 2.0) { audioDelay = 2.0 }
                        optButton("延后 1 秒", audioDelay == 1.0) { audioDelay = 1.0 }
                        optButton("延后 0.5 秒", audioDelay == 0.5) { audioDelay = 0.5 }
                        optButton("无延迟", audioDelay == 0) { audioDelay = 0 }
                        optButton("提前 0.5 秒", audioDelay == -0.5) { audioDelay = -0.5 }
                        optButton("提前 1 秒", audioDelay == -1.0) { audioDelay = -1.0 }
                        optButton("提前 2 秒", audioDelay == -2.0) { audioDelay = -2.0 }
                    }
                }
                prefsCard {
                    prefsToggleRow("后台音频播放（听视频）", isOn: $backgroundAudio)
                }
                Text("后台音频播放：开启后 mpv 播放器切到后台或锁屏时不暂停，继续放声音；画中画开启时仍走画中画。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                Text("记住所选音轨：在播放器里手动切换的音轨会按剧记住，同一部剧的其它集自动沿用，优先级高于首选语言。首选语言：在没有记住的音轨时，打开视频自动选该语言的音轨，并避开 TrueHD；「默认」即片源的第一条音轨。两个引擎（mpv / VLCKit）都遵循。音频延迟仅 mpv 播放器生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("音频设置")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var languageLabel: String {
        switch audioLanguage {
        case "default": return "默认"
        case "en": return "英文"
        case "ja": return "日语"
        case "ko": return "韩语"
        default: return "中文"
        }
    }

    private var audioDelayLabel: String {
        if audioDelay > 0 { return "延后 \(audioDelay.formatted()) 秒" }
        if audioDelay < 0 { return "提前 \((-audioDelay).formatted()) 秒" }
        return "无延迟"
    }
}

// MARK: - 字幕设置

struct SubtitlePrefsView: View {
    @AppStorage("prefs.subtitlePreference") private var subtitlePreference = "zhHans"
    @AppStorage("prefs.rememberSubtitleChoice") private var rememberSubtitleChoice = true
    @AppStorage("prefs.subScale") private var subScale = 1.0
    @AppStorage("prefs.subDelay") private var subDelay = 0.0
    @AppStorage("prefs.subColor") private var subColor = "white"
    @AppStorage("prefs.subBorder") private var subBorder = "outline"
    @AppStorage("prefs.subMarginY") private var subMarginY = 20
    @AppStorage("prefs.secondarySubtitle") private var secondarySubtitle = "off"
    @AppStorage("prefs.danmakuEnabled") private var danmakuEnabled = true
    @AppStorage("prefs.danmakuFontSize") private var danmakuFontSize = 36
    @AppStorage("prefs.danmakuScrollSeconds") private var danmakuScrollSeconds = 8.0
    @AppStorage("prefs.danmakuArea") private var danmakuArea = "oneRow"
    @State private var assrtToken = ""
    @State private var osApiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("默认字幕", value: subtitleLabel) {
                        optButton("简体中文", subtitlePreference == "zhHans") { subtitlePreference = "zhHans" }
                        optButton("繁体中文", subtitlePreference == "zhHant") { subtitlePreference = "zhHant" }
                        optButton("英文", subtitlePreference == "en") { subtitlePreference = "en" }
                        optButton("关闭", subtitlePreference == "off") { subtitlePreference = "off" }
                    }
                    prefsDivider
                    prefsMenuRow("副字幕", value: secondarySubtitleLabel) {
                        optButton("关闭", secondarySubtitle == "off") { secondarySubtitle = "off" }
                        optButton("简体中文", secondarySubtitle == "zhHans") { secondarySubtitle = "zhHans" }
                        optButton("繁体中文", secondarySubtitle == "zhHant") { secondarySubtitle = "zhHant" }
                        optButton("英文", secondarySubtitle == "en") { secondarySubtitle = "en" }
                    }
                }
                Text("副字幕：再挂一条其它语言的字幕同时显示（双字幕），开播时自动选轨；仅 mpv 播放器支持，播放器字幕菜单里也能临时选。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                prefsSectionLabel("在线字幕").padding(.top, 8)
                prefsCard {
                    HStack {
                        Text("ASSRT Token").font(.system(size: 15))
                        Spacer(minLength: 12)
                        SecureField("留空用公共额度", text: $assrtToken)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 190)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
                Text("在线字幕来自 ASSRT（assrt.net）：播放时在字幕菜单选「搜索在线字幕」，按片名搜到后点一条即下载挂上（仅 mpv 播放器）。公共额度是开源播放器共用的 token，繁忙时会限流；想稳定可在 assrt.net 免费注册自己的 token 填在这里。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                prefsCard {
                    HStack {
                        Text("OpenSubtitles Key").font(.system(size: 15))
                        Spacer(minLength: 12)
                        SecureField("需要自己申请", text: $osApiKey)
                            .multilineTextAlignment(.trailing)
                            .font(.system(size: 15))
                            .foregroundStyle(.primary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .frame(maxWidth: 190)
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                }
                Text("第二个字幕源 OpenSubtitles（opensubtitles.com）：它没有公共额度，必须用自己的 API Key——在它网站免费注册、到 API 页面申请一个消费者 Key 填在这里，搜索框顶部可切换字幕源。免费账号每天有下载次数上限。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                prefsSectionLabel("弹幕").padding(.top, 8)
                prefsCard {
                    prefsToggleRow("弹幕", isOn: $danmakuEnabled)
                    prefsDivider
                    prefsMenuRow("弹幕字号", value: danmakuFontLabel) {
                        optButton("小", danmakuFontSize == 30) { danmakuFontSize = 30 }
                        optButton("中", danmakuFontSize == 36) { danmakuFontSize = 36 }
                        optButton("大", danmakuFontSize == 44) { danmakuFontSize = 44 }
                    }
                    prefsDivider
                    prefsMenuRow("滚动速度", value: danmakuSpeedLabel) {
                        optButton("慢", danmakuScrollSeconds == 10.0) { danmakuScrollSeconds = 10.0 }
                        optButton("标准", danmakuScrollSeconds == 8.0) { danmakuScrollSeconds = 8.0 }
                        optButton("快", danmakuScrollSeconds == 6.5) { danmakuScrollSeconds = 6.5 }
                    }
                    prefsDivider
                    prefsMenuRow("显示区域", value: danmakuAreaLabel) {
                        optButton("仅顶部一行", danmakuArea == "oneRow") { danmakuArea = "oneRow" }
                        optButton("顶部 1/4", danmakuArea == "quarter") { danmakuArea = "quarter" }
                        optButton("顶部半屏", danmakuArea == "half") { danmakuArea = "half" }
                        optButton("全屏", danmakuArea == "full") { danmakuArea = "full" }
                    }
                }
                Text("弹幕来自自建的聚合弹幕服务、按片名自动匹配，由应用直接绘制，可与双字幕同时使用；仅 mpv 播放器支持。字号、速度与区域改了之后，下次打开视频生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
                prefsCard {
                    prefsToggleRow("记住每部剧的字幕选择", isOn: $rememberSubtitleChoice)
                }
                prefsCard {
                    prefsMenuRow("字幕大小", value: subScaleLabel) {
                        optButton("较小", subScale == 0.8) { subScale = 0.8 }
                        optButton("标准", subScale == 1.0) { subScale = 1.0 }
                        optButton("较大", subScale == 1.25) { subScale = 1.25 }
                        optButton("特大", subScale == 1.5) { subScale = 1.5 }
                    }
                    prefsDivider
                    prefsMenuRow("字幕延迟", value: subDelayLabel) {
                        optButton("延后 2 秒", subDelay == 2.0) { subDelay = 2.0 }
                        optButton("延后 1 秒", subDelay == 1.0) { subDelay = 1.0 }
                        optButton("延后 0.5 秒", subDelay == 0.5) { subDelay = 0.5 }
                        optButton("无延迟", subDelay == 0) { subDelay = 0 }
                        optButton("提前 0.5 秒", subDelay == -0.5) { subDelay = -0.5 }
                        optButton("提前 1 秒", subDelay == -1.0) { subDelay = -1.0 }
                        optButton("提前 2 秒", subDelay == -2.0) { subDelay = -2.0 }
                    }
                }
                prefsSectionLabel("样式").padding(.top, 8)
                prefsCard {
                    prefsMenuRow("字幕颜色", value: subColorLabel) {
                        optButton("白色", subColor == "white") { subColor = "white" }
                        optButton("黄色", subColor == "yellow") { subColor = "yellow" }
                        optButton("青色", subColor == "cyan") { subColor = "cyan" }
                        optButton("绿色", subColor == "green") { subColor = "green" }
                    }
                    prefsDivider
                    prefsMenuRow("字幕描边", value: subBorderLabel) {
                        optButton("描边", subBorder == "outline") { subBorder = "outline" }
                        optButton("背景框", subBorder == "box") { subBorder = "box" }
                        optButton("无", subBorder == "none") { subBorder = "none" }
                    }
                    prefsDivider
                    prefsMenuRow("字幕位置", value: subMarginLabel) {
                        optButton("紧贴底部", subMarginY == 8) { subMarginY = 8 }
                        optButton("标准", subMarginY == 20) { subMarginY = 20 }
                        optButton("抬高", subMarginY == 36) { subMarginY = 36 }
                    }
                }
                Text("打开视频时自动挑选的字幕（内嵌与外挂字幕都算）；没有匹配的字幕时回退到片源默认字幕。选「关闭」则不自动开启字幕，仍可在播放器里手动选择。字幕大小、延迟与样式在打开视频时应用，对 mpv 引擎的文字字幕生效；PGS 位图字幕（VLCKit）不受影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("字幕设置")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            assrtToken = KeychainStore.get("assrtToken") ?? ""
            osApiKey = KeychainStore.get("osApiKey") ?? ""
        }
        .onChange(of: assrtToken) { _, newValue in
            KeychainStore.set("assrtToken", newValue)
        }
        .onChange(of: osApiKey) { _, newValue in
            KeychainStore.set("osApiKey", newValue)
        }
    }

    private var subScaleLabel: String {
        switch subScale {
        case 0.8: return "较小"
        case 1.25: return "较大"
        case 1.5: return "特大"
        default: return "标准"
        }
    }

    private var subDelayLabel: String {
        if subDelay == 0 { return "无" }
        return subDelay > 0 ? String(format: "延后 %g 秒", subDelay) : String(format: "提前 %g 秒", -subDelay)
    }

    private var subColorLabel: String {
        switch subColor {
        case "yellow": return "黄色"
        case "cyan": return "青色"
        case "green": return "绿色"
        default: return "白色"
        }
    }

    private var subBorderLabel: String {
        switch subBorder {
        case "box": return "背景框"
        case "none": return "无"
        default: return "描边"
        }
    }

    private var subMarginLabel: String {
        switch subMarginY {
        case 8: return "紧贴底部"
        case 36: return "抬高"
        default: return "标准"
        }
    }

    private var subtitleLabel: String {
        switch subtitlePreference {
        case "zhHant": return "繁体中文"
        case "en": return "英文"
        case "off": return "关闭"
        default: return "简体中文"
        }
    }

    private var secondarySubtitleLabel: String {
        switch secondarySubtitle {
        case "zhHans": return "简体中文"
        case "zhHant": return "繁体中文"
        case "en": return "英文"
        default: return "关闭"
        }
    }

    private var danmakuFontLabel: String {
        switch danmakuFontSize {
        case 30: return "小"
        case 44: return "大"
        default: return "中"
        }
    }

    private var danmakuSpeedLabel: String {
        switch danmakuScrollSeconds {
        case 10.0: return "慢"
        case 6.5: return "快"
        default: return "标准"
        }
    }

    private var danmakuAreaLabel: String {
        switch danmakuArea {
        case "quarter": return "顶部 1/4"
        case "half": return "顶部半屏"
        case "full": return "全屏"
        default: return "仅顶部一行"
        }
    }
}

// MARK: - 应用偏好

struct AppPrefsView: View {
    @AppStorage("prefs.startTab") private var startTab = 0
    @AppStorage("prefs.appearance") private var appearance = "system"

    private let tabNames = ["首页", "资源库", "记录", "设置", "搜索"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("启动时打开", value: startTab == -1 ? "上次使用" : tabNames[startTab]) {
                        ForEach(tabNames.indices, id: \.self) { index in
                            Button(tabNames[index]) { startTab = index }
                        }
                        optButton("上次使用", startTab == -1) { startTab = -1 }
                    }
                }

                prefsSectionLabel("外观").padding(.top, 8)
                prefsCard {
                    prefsMenuRow("外观模式", value: appearanceLabel) {
                        optButton("跟随系统", appearance == "system") { appearance = "system" }
                        optButton("浅色", appearance == "light") { appearance = "light" }
                        optButton("深色", appearance == "dark") { appearance = "dark" }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("应用偏好")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var appearanceLabel: String {
        switch appearance {
        case "light": return "浅色"
        case "dark": return "深色"
        default: return "跟随系统"
        }
    }
}

// MARK: - 模块配置（首页区块）

struct ModulePrefsView: View {
    @AppStorage("prefs.showHomeResume") private var showResume = true
    @AppStorage("prefs.showHomeLibraries") private var showLibraries = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("继续观看", isOn: $showResume)
                    prefsDivider
                    prefsToggleRow("我的媒体库", isOn: $showLibraries)
                }
                Text("控制首页各区块的显示；顶部推荐轮播不受影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("模块配置")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - 隐私保护

struct PrivacyPrefsView: View {
    @AppStorage("prefs.appLock") private var appLock = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("应用锁", isOn: $appLock)
                }
                Text("打开 App、从后台回到前台时，用 Face ID 或设备密码解锁。设备没设密码时不会上锁。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("隐私保护")
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - 缓存管理

struct CachePrefsView: View {
    @State private var usageText = "计算中…"
    @State private var cleared = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    HStack {
                        Text("图片缓存")
                        Spacer()
                        Text(usageText).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 54)
                }
                prefsCard {
                    Button(role: .destructive) {
                        ImageMemoryCache.shared.clearAll()
                        URLCache.shared.removeAllCachedResponses()
                        cleared = true
                        refreshUsage()
                    } label: {
                        HStack { Spacer(); Text("清除图片缓存"); Spacer() }
                            .padding(.horizontal, 20)
                            .frame(minHeight: 54)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if cleared {
                    Text("已清除，下次打开页面时会重新加载图片。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("缓存管理")
        .navigationBarTitleDisplayMode(.inline)
        .task { refreshUsage() }
    }

    private func refreshUsage() {
        // The real image store is ImageDiskCache; URLCache only holds
        // incidental URLSession responses. Report both so the number
        // matches what clearing actually frees.
        let bytes = ImageMemoryCache.diskCacheBytes()
            + Int64(URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage)
        usageText = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}


// MARK: - 下载设置

struct DownloadsPrefsView: View {
    @AppStorage("prefs.downloadMaxConcurrent") private var maxConcurrent = 2
    @AppStorage("prefs.downloadWiFiOnly") private var wiFiOnly = false
    @ObservedObject private var manager = DownloadsManager.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("同时下载数", value: "\(maxConcurrent) 个") {
                        optButton("1 个", maxConcurrent == 1) { maxConcurrent = 1 }
                        optButton("2 个", maxConcurrent == 2) { maxConcurrent = 2 }
                        optButton("3 个", maxConcurrent == 3) { maxConcurrent = 3 }
                    }
                    prefsDivider
                    prefsToggleRow("仅 Wi-Fi 下载", isOn: $wiFiOnly)
                }
                Text("超过同时下载数的任务排队等待，前面的下完自动开始；仅 Wi-Fi 下载开启时，蜂窝网络下新任务等回到 Wi-Fi 才开始，已经在下的不受影响。对新开始的任务生效。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)

                prefsSectionLabel("存储").padding(.top, 8)
                prefsCard {
                    HStack {
                        Text("已下载内容")
                        Spacer()
                        Text("\(manager.records.count) 项 · \(ByteCountFormatter.string(fromByteCount: manager.downloadedBytes, countStyle: .file))")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 20)
                    .frame(minHeight: 54)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("下载设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 列表配置

struct ListPrefsView: View {
    @AppStorage("prefs.posterColumns") private var posterColumns = 3

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("海报列数", value: "\(posterColumns) 列") {
                        optButton("2 列（大图）", posterColumns == 2) { posterColumns = 2 }
                        optButton("3 列（标准）", posterColumns == 3) { posterColumns = 3 }
                        optButton("4 列（紧凑）", posterColumns == 4) { posterColumns = 4 }
                    }
                }
                Text("作用于资源库与收藏的海报网格。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("列表配置")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - AI 字幕翻译设置

struct AITranslatePrefsView: View {
    @AppStorage("prefs.aiEndpoint") private var endpoint = "https://api.deepseek.com"
    @AppStorage("prefs.aiModel") private var model = "deepseek-chat"
    @AppStorage("prefs.aiTargetLang") private var targetLang = "zh-Hans"
    @State private var apiKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    fieldRow("接口地址") {
                        TextField("https://api.deepseek.com", text: $endpoint)
                    }
                    prefsDivider
                    fieldRow("API Key") {
                        SecureField("粘贴你的 key", text: $apiKey)
                    }
                    prefsDivider
                    fieldRow("模型") {
                        TextField("deepseek-chat", text: $model)
                    }
                    prefsDivider
                    prefsMenuRow("翻译成", value: targetLabel) {
                        optButton("简体中文", targetLang == "zh-Hans") { targetLang = "zh-Hans" }
                        optButton("繁体中文", targetLang == "zh-Hant") { targetLang = "zh-Hant" }
                        optButton("英文", targetLang == "en") { targetLang = "en" }
                        optButton("日语", targetLang == "ja") { targetLang = "ja" }
                        optButton("韩语", targetLang == "ko") { targetLang = "ko" }
                    }
                }
                Text("接口按 OpenAI 兼容格式调用（DeepSeek、OpenAI、硅基流动等都能用），地址填到域名即可，不用带 /chat/completions。费用由接口方按量收取，DeepSeek 翻一集动画大约几分钱。API Key 只存本机钥匙串。用法：播放时打开字幕菜单 →「AI 翻译」。仅文字字幕可译，PGS 图片字幕不行；仅 mpv 播放器可用。译好的字幕会缓存在本机，同一集再看不重复收费。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("AI 字幕翻译")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { apiKey = KeychainStore.get("aiTranslateKey") ?? "" }
        .onChange(of: apiKey) { _, newValue in KeychainStore.set("aiTranslateKey", newValue) }
    }

    private func fieldRow<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        HStack {
            Text(title).font(.system(size: 15))
            Spacer(minLength: 12)
            field()
                .multilineTextAlignment(.trailing)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .frame(maxWidth: 230)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 44)
    }

    private var targetLabel: String {
        switch targetLang {
        case "zh-Hant": return "繁体中文"
        case "en": return "英文"
        case "ja": return "日语"
        case "ko": return "韩语"
        default: return "简体中文"
        }
    }
}
