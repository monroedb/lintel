import Foundation

/// How a connected audio device is drawn in its alert ("3D models" vs
/// "Symbols"; Lintel draws its own animated rendition, no video assets).
public enum DeviceVisualStyle: String, SettingChoice {
    case rendered = "rendered"
    case symbol = "symbol"

    public var title: String {
        switch self {
        case .rendered: return "3D"
        case .symbol: return "Symbol"
        }
    }
}

/// Settings for the battery, audio-device and Focus alerts.
extension Keys {
    // MARK: Battery
    public static let batteryAlerts = SettingKey<Bool>("alerts.battery.enabled", default: true)
    public static let batteryLowPowerAlert = SettingKey<Bool>("alerts.battery.lowPowerMode", default: true)
    public static let batteryLowWarning = SettingKey<Bool>("alerts.battery.low", default: true)
    /// Percent (0–100).
    public static let batteryLowThreshold = SettingKey<Double>("alerts.battery.low.threshold", default: 10)
    public static let batteryLowSound = SettingKey<Bool>("alerts.battery.low.sound", default: true)
    public static let batteryHideLabel = SettingKey<Bool>("alerts.battery.hideLabel", default: false)
    public static let batteryHidePercentage = SettingKey<Bool>("alerts.battery.hidePercentage", default: false)

    // MARK: Audio devices
    public static let deviceAlerts = SettingKey<Bool>("alerts.devices.enabled", default: true)
    public static let deviceLowWarning = SettingKey<Bool>("alerts.devices.low", default: false)
    /// Percent (0–100).
    public static let deviceLowThreshold = SettingKey<Double>("alerts.devices.low.threshold", default: 20)
    public static let deviceLowSound = SettingKey<Bool>("alerts.devices.low.sound", default: false)
    public static let deviceVisualStyle = SettingKey<DeviceVisualStyle>("alerts.devices.visual", default: .rendered)
    /// Set once Lintel has shown the system's Bluetooth prompt (the prompt is only shown on request).
    public static let deviceBluetoothPrompted = SettingKey<Bool>("alerts.devices.bluetoothPrompted", default: false)

    // MARK: Focus
    public static let focusAlerts = SettingKey<Bool>("alerts.focus.enabled", default: true)
    public static let focusSleepSound = SettingKey<Bool>("alerts.focus.sleepSound", default: false)
    public static let focusReplacesWaveform = SettingKey<Bool>("alerts.focus.replaceWaveform", default: false)
    /// Mode identifier the waveform replacement is limited to; nil = any Focus.
    public static let focusReplacesWaveformMode = SettingKey<String?>("alerts.focus.replaceWaveform.mode", default: nil)
    /// Hides the "On" / "Off" text.
    public static let focusHideLabel = SettingKey<Bool>("alerts.focus.hideLabel", default: false)
    /// Reads which Focus is on (name, symbol, tint) from the system's Focus database. Needs Full Disk
    /// Access and relies on an undocumented format, so it is off by default.
    public static let focusModeDetails = SettingKey<Bool>("alerts.focus.modeDetails", default: false)

    // MARK: Optional capabilities (private or undocumented capabilities can be switched off)
    /// Battery levels of Bluetooth audio devices through undocumented IOBluetooth properties.
    public static let capabilityDeviceBattery = SettingKey<Bool>("capability.audioDeviceBattery", default: true)
}
