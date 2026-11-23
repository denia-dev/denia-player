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
