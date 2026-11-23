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
    static var decodeMode: String { d.string(forKey: "prefs.decodeMode") ?? "hardware" }
    static var softwareThreads: Int {
        d.object(forKey: "prefs.softwareThreads") == nil ? 8 : d.integer(forKey: "prefs.softwareThreads")
    }
    static var dvP7Convert: Bool {
        d.object(forKey: "prefs.dvP7Convert") == nil ? true : d.bool(forKey: "prefs.dvP7Convert")
    }

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

    // Home modules + start tab
    static var showHomeResume: Bool {
        d.object(forKey: "prefs.showHomeResume") == nil ? true : d.bool(forKey: "prefs.showHomeResume")
    }
    static var showHomeLibraries: Bool {
        d.object(forKey: "prefs.showHomeLibraries") == nil ? true : d.bool(forKey: "prefs.showHomeLibraries")
    }
    static var showHomeLatest: Bool {
        d.object(forKey: "prefs.showHomeLatest") == nil ? true : d.bool(forKey: "prefs.showHomeLatest")
    }
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

private func prefsLinkRow(_ title: String, route: Route) -> some View {
    NavigationLink(value: route) {
        HStack {
            Text(title)
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
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

private func prefsMenuRow<Content: View>(_ title: String, value: String, @ViewBuilder content: () -> Content) -> some View {
    Menu {
        content()
    } label: {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            Text(value).foregroundStyle(.secondary)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 20)
        .frame(height: 54)
        .contentShape(Rectangle())
    }
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
                    prefsLinkRow("OSD 信息显示", route: .osdPrefs)
                    prefsDivider
                    prefsLinkRow("自定义播放器按钮", route: .buttonPrefs)
                }

                prefsSectionLabel("亮度").padding(.top, 8)
                prefsCard {
                    prefsToggleRow("播放器独立亮度", isOn: $independentBrightness)
                }

                prefsSectionLabel("控制栏").padding(.top, 8)
                prefsCard {
                    prefsMenuRow("进度条时间模式", value: timeMode == "remaining" ? "剩余时间" : "总时长") {
                        Button("总时长") { timeMode = "total" }
                        Button("剩余时间") { timeMode = "remaining" }
                    }
                    prefsDivider
                    prefsMenuRow("自动隐藏", value: hideSeconds == 0 ? "永不" : "\(Int(hideSeconds)) 秒") {
                        Button("3 秒") { hideSeconds = 3 }
                        Button("5 秒") { hideSeconds = 5 }
                        Button("8 秒") { hideSeconds = 8 }
                        Button("永不") { hideSeconds = 0 }
                    }
                }

                prefsSectionLabel("屏幕方向").padding(.top, 8)
                prefsCard {
                    prefsMenuRow("进入播放器屏幕方向", value: orientationLabel) {
                        Button("强制横屏") { orientation = "landscape" }
                        Button("跟随设备") { orientation = "auto" }
                        Button("强制竖屏") { orientation = "portrait" }
                    }
                    prefsDivider
                    prefsMenuRow("设备横屏方向", value: sideLabel) {
                        Button("自动") { landscapeSide = "auto" }
                        Button("左横屏") { landscapeSide = "left" }
                        Button("右横屏") { landscapeSide = "right" }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("显示标题", isOn: $showTitle)
                    prefsDivider
                    prefsToggleRow("显示诊断按钮", isOn: $showDiagnostics)
                }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("快进 / 快退秒数", value: "\(Int(seekStep)) 秒") {
                        Button("10 秒") { seekStep = 10 }
                        Button("15 秒") { seekStep = 15 }
                        Button("30 秒") { seekStep = 30 }
                    }
                    prefsDivider
                    prefsMenuRow("默认播放速度", value: rateLabel) {
                        Button("0.75×") { defaultRate = 0.75 }
                        Button("1×") { defaultRate = 1.0 }
                        Button("1.25×") { defaultRate = 1.25 }
                        Button("1.5×") { defaultRate = 1.5 }
                        Button("2×") { defaultRate = 2.0 }
                    }
                    prefsDivider
                    prefsMenuRow("睡眠定时", value: sleepMinutes == 0 ? "关闭" : "\(sleepMinutes) 分钟") {
                        Button("关闭") { sleepMinutes = 0 }
                        Button("15 分钟") { sleepMinutes = 15 }
                        Button("30 分钟") { sleepMinutes = 30 }
                        Button("45 分钟") { sleepMinutes = 45 }
                        Button("60 分钟") { sleepMinutes = 60 }
                    }
                    prefsDivider
                    prefsToggleRow("自动播放下一集", isOn: $autoPlayNext)
                    prefsDivider
                    prefsToggleRow("跳过片头片尾按钮", isOn: $skipSegments)
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
                        Button("1.5×") { boostRate = 1.5 }
                        Button("2×") { boostRate = 2.0 }
                        Button("3×") { boostRate = 3.0 }
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
    @AppStorage("prefs.decodeMode") private var decodeMode = "hardware"
    @AppStorage("prefs.softwareThreads") private var threads = 8
    @AppStorage("prefs.dvP7Convert") private var p7Convert = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("首选解码模式", value: decodeLabel) {
                        Button("自动") { decodeMode = "auto" }
                        Button("硬解码 (HW/GPU)") { decodeMode = "hardware" }
                        Button("软解码") { decodeMode = "software" }
                    }
                    prefsDivider
                    prefsMenuRow("软件解码线程", value: "\(threads)") {
                        Button("2") { threads = 2 }
                        Button("4") { threads = 4 }
                        Button("8") { threads = 8 }
                        Button("16") { threads = 16 }
                    }
                }
                Text("硬解码：高效省电，基本不发热，能否硬解取决于设备与系统。软解码：兼容性强，但播放大文件容易发热且耗电量高。除非无法正常播放，否则不要使用软解码。以上设置作用于 mpv 引擎；VLCKit 引擎（PGS 字幕片源）使用其内置解码。")
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
}

// MARK: - 音频设置

struct AudioPrefsView: View {
    @AppStorage("prefs.rememberAudioChoice") private var rememberChoice = true
    @AppStorage("prefs.audioLanguage") private var audioLanguage = "zh"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("记住所选音轨", isOn: $rememberChoice)
                    prefsDivider
                    prefsMenuRow("音频首选语言", value: languageLabel) {
                        Button("默认") { audioLanguage = "default" }
                        Button("中文") { audioLanguage = "zh" }
                        Button("英文") { audioLanguage = "en" }
                        Button("日语") { audioLanguage = "ja" }
                        Button("韩语") { audioLanguage = "ko" }
                    }
                }
                Text("记住所选音轨：在播放器里手动切换的音轨会按剧记住，同一部剧的其它集自动沿用，优先级高于首选语言。首选语言：在没有记住的音轨时，打开视频自动选该语言的音轨，并避开 TrueHD；「默认」即片源的第一条音轨。两个引擎（mpv / VLCKit）都遵循。")
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
}

// MARK: - 字幕设置

struct SubtitlePrefsView: View {
    @AppStorage("prefs.subtitlePreference") private var subtitlePreference = "zhHans"
    @AppStorage("prefs.subScale") private var subScale = 1.0
    @AppStorage("prefs.subDelay") private var subDelay = 0.0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("默认字幕", value: subtitleLabel) {
                        Button("简体中文") { subtitlePreference = "zhHans" }
                        Button("繁体中文") { subtitlePreference = "zhHant" }
                        Button("英文") { subtitlePreference = "en" }
                        Button("关闭") { subtitlePreference = "off" }
                    }
                }
                prefsCard {
                    prefsMenuRow("字幕大小", value: subScaleLabel) {
                        Button("较小") { subScale = 0.8 }
                        Button("标准") { subScale = 1.0 }
                        Button("较大") { subScale = 1.25 }
                        Button("特大") { subScale = 1.5 }
                    }
                    prefsDivider
                    prefsMenuRow("字幕延迟", value: subDelayLabel) {
                        Button("延后 2 秒") { subDelay = 2.0 }
                        Button("延后 1 秒") { subDelay = 1.0 }
                        Button("延后 0.5 秒") { subDelay = 0.5 }
                        Button("无延迟") { subDelay = 0 }
                        Button("提前 0.5 秒") { subDelay = -0.5 }
                        Button("提前 1 秒") { subDelay = -1.0 }
                        Button("提前 2 秒") { subDelay = -2.0 }
                    }
                }
                Text("打开视频时自动挑选的字幕（内嵌与外挂字幕都算）；没有匹配的字幕时回退到片源默认字幕。选「关闭」则不自动开启字幕，仍可在播放器里手动选择。字幕大小与延迟在打开视频时应用，对 mpv 引擎的文字字幕生效；PGS 位图字幕（VLCKit）不受影响。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("字幕设置")
        .navigationBarTitleDisplayMode(.inline)
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

    private var subtitleLabel: String {
        switch subtitlePreference {
        case "zhHant": return "繁体中文"
        case "en": return "英文"
        case "off": return "关闭"
        default: return "简体中文"
        }
    }
}

// MARK: - 应用偏好

struct AppPrefsView: View {
    @AppStorage("prefs.startTab") private var startTab = 0

    private let tabNames = ["首页", "资源库", "记录", "设置", "搜索"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsMenuRow("启动时打开", value: startTab == -1 ? "上次使用" : tabNames[startTab]) {
                        ForEach(tabNames.indices, id: \.self) { index in
                            Button(tabNames[index]) { startTab = index }
                        }
                        Button("上次使用") { startTab = -1 }
                    }
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("应用偏好")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 模块配置（首页区块）

struct ModulePrefsView: View {
    @AppStorage("prefs.showHomeResume") private var showResume = true
    @AppStorage("prefs.showHomeLibraries") private var showLibraries = true
    @AppStorage("prefs.showHomeLatest") private var showLatest = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                prefsCard {
                    prefsToggleRow("继续观看", isOn: $showResume)
                    prefsDivider
                    prefsToggleRow("我的媒体库", isOn: $showLibraries)
                    prefsDivider
                    prefsToggleRow("最新添加", isOn: $showLatest)
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
        let bytes = URLCache.shared.currentDiskUsage + URLCache.shared.currentMemoryUsage
        usageText = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
                        Button("2 列（大图）") { posterColumns = 2 }
                        Button("3 列（标准）") { posterColumns = 3 }
                        Button("4 列（紧凑）") { posterColumns = 4 }
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
