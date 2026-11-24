import CoreGraphics

extension NotificationKind {
    /// Battery, audio-device and Focus alerts, drawn by the system-alert views.
    public var isSystemAlert: Bool {
        switch self {
        case .charging, .lowBattery, .lowPowerMode, .deviceConnected, .deviceLowBattery, .focus: return true
        case .volume, .brightness, .timeToLeave: return false
        }
    }

    /// Battery and device alerts use the HUD bar layout with room for a label or several levels;
    /// the Focus alert keeps the measured compact width.
    public var isWideAlert: Bool {
        switch self {
        case .charging, .lowBattery, .lowPowerMode, .deviceConnected, .deviceLowBattery: return true
        default: return false
        }
    }
}

extension PresentationMetrics {
    /// Side slot of the battery and device alerts: room for a 21 pt battery glyph and a 12 pt label
    /// such as "Low Battery", or the 40 pt device visual and three battery levels, clear of
    /// the notch. The HUD's 100 pt slot is 20 pt too narrow for those.
    public static let wideAlertSlotWidth: CGFloat = 120

    /// Width of each side slot for a notification.
    public static func notificationSlotWidth(for kind: NotificationKind) -> CGFloat {
        if kind.isHUD { return hudSlotWidth }
        return kind.isWideAlert ? wideAlertSlotWidth : alertSlotWidth
    }
}
