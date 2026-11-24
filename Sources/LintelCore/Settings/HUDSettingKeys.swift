import Foundation

/// Settings of one HUD (Display and Sound tabs).
/// The hold duration lives with the other alert durations:
/// `Keys.duration(.volume)` / `Keys.duration(.brightness)` (default 1.5 s).
public struct HUDSettingKeys: Sendable {
    public let kind: HUDKind
    /// Master switch (**off** for both HUDs: they need Accessibility).
    public let enabled: SettingKey<Bool>
    public let style: SettingKey<HUDBarStyle>
    public let speed: SettingKey<HUDBarSpeed>
    public let showPercentage: SettingKey<Bool>
    public let hideLabel: SettingKey<Bool>

    public var duration: SettingKey<Double> { Keys.duration(kind.notification) }

    /// Names of the keys whose values make up `HUDAppearance` (mirrored when HUD looks are linked).
    public var appearanceKeyNames: [String] { [style.name, speed.name, showPercentage.name, hideLabel.name, duration.name] }
}

extension Keys {
    public static let volumeHUD = HUDSettingKeys(
        kind: .volume,
        enabled: SettingKey("hud.volume.enabled", default: false),
        style: SettingKey("hud.volume.style", default: .white),
        speed: SettingKey("hud.volume.speed", default: .fast),
        showPercentage: SettingKey("hud.volume.showPercentage", default: false),
        hideLabel: SettingKey("hud.volume.hideLabel", default: false)
    )

    public static let brightnessHUD = HUDSettingKeys(
        kind: .brightness,
        enabled: SettingKey("hud.brightness.enabled", default: false),
        style: SettingKey("hud.brightness.style", default: .white),
        speed: SettingKey("hud.brightness.speed", default: .fast),
        showPercentage: SettingKey("hud.brightness.showPercentage", default: false),
        hideLabel: SettingKey("hud.brightness.hideLabel", default: false)
    )

    public static func hud(_ kind: HUDKind) -> HUDSettingKeys { kind == .volume ? volumeHUD : brightnessHUD }

    /// Volume HUD: generic speaker symbol or the current output device (device).
    public static let volumeLabelMode = SettingKey<VolumeLabelMode>("hud.volume.labelMode", default: .device)
    /// Which display the brightness keys adjust (P3; automatic = the display under the pointer when it
    /// can be adjusted, else the built-in one).
    public static let brightnessTarget = SettingKey<BrightnessTargetMode>("hud.brightness.target", default: .automatic)
    /// "Link settings between HUDs" (offered). Off by default.
    public static let linkHUDAppearance = SettingKey<Bool>("hud.linkAppearance", default: false)

    /// Whether Lintel already asked macOS for Accessibility access (so the system prompt isn't repeated).
    public static let accessibilityPrompted = SettingKey<Bool>("permissions.accessibility.prompted", default: false)

    /// Private capability switch: built-in display brightness through DisplayServices.
    public static let displayServicesCapability = SettingKey<Bool>("capabilities.displayServices", default: true)

    /// Keys the HUD service reacts to.
    public static var hudKeyNames: Set<String> {
        var names: Set<String> = [volumeLabelMode.name, brightnessTarget.name, linkHUDAppearance.name,
                                  displayServicesCapability.name]
        for kind in HUDKind.allCases {
            let keys = hud(kind)
            names.insert(keys.enabled.name)
            names.formUnion(keys.appearanceKeyNames)
        }
        return names
    }
}

extension Keys {
    /// Designated requirement of the copy that ran last (diagnostics; see `SignatureContinuity`).
    public static let lastDesignatedRequirement = SettingKey<String?>("diagnostics.designatedRequirement", default: nil)
    /// Requirement of the earlier copy when the signature changed and Accessibility hasn't been granted
    /// to the new one yet (Settings explains why a switch that looks on doesn't apply). Cleared once
    /// Accessibility is granted.
    public static let signatureChangedFrom = SettingKey<String?>("permissions.signatureChangedFrom", default: nil)
}
