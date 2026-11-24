import CoreGraphics
import Foundation

/// Timer settings. Names use the `timer.` prefix.
extension Keys {
    /// Master switch: the timer page, the menu items and the links.
    public static let timerEnabled = SettingKey<Bool>("timer.enabled", default: true)
    public static let timerSound = SettingKey<Bool>("timer.sound", default: true)
    /// "Keep ringing until dismissed" (every 3 s, at most 2 min); off: one ring, the alert stays 10 s.
    public static let timerRepeatAlert = SettingKey<Bool>("timer.repeatAlert", default: true)
    /// Open the island to the timer page when a timer ends.
    public static let timerOpenOnFinish = SettingKey<Bool>("timer.openOnFinish", default: true)
    /// Prefill of the custom-duration window (the last custom duration started), seconds.
    public static let timerLastCustomSeconds = SettingKey<Double>("timer.custom.lastSeconds", default: 1200)
    /// The stored timer (`TimerSnapshot` as JSON); not shown in Settings.
    public static let timerState = SettingKey<String?>("timer.state", default: nil)
    /// What the open island shows to set a timer.
    public static let timerPickerStyle = SettingKey<TimerPickerStyle>("timer.picker.style", default: .ruler)
    /// Quick presets: the ruler's pills and the menus' preset items.
    public static let timerPresets = SettingKey<TimerQuickPresets>("timer.presets", default: .standard)
    /// The last duration started from the picker; the ruler opens there.
    public static let timerRulerLastMinutes = SettingKey<Int>("timer.ruler.lastMinutes", default: TimerRulerScale.defaultMinutes)

    /// Prefix of the keys above.
    public static let timerKeyPrefix = "timer."
}

extension PresentationMetrics {
    /// Compact slot per side while a timer is live: `59:59` in 13 pt rounded semibold is 38.9 pt
    /// wide, which fits beside the notch with the usual 16 pt edge inset (309 × 34.5 pt drawn on a
    /// 185 pt notch).
    public static let timerSlotWidth: CGFloat = 62
}
