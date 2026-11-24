import AppKit
import CoreGraphics
import Foundation
import LintelCore

/// Checks for HUD settings, level steps and overshoot, media-key decoding and routing
/// (the event tap's decision path), brightness targeting, glyphs and labels, echo suppression,
/// feedback sound, BetterDisplay messages and HUD routing.
func runHUDChecks() {
    checkHUDSettings()
    checkLevelSteps()
    checkMediaKeyDecoding()
    checkMediaKeyRouting()
    checkBrightnessTargeting()
    checkGlyphsAndLabels()
    checkEchoAndFeedback()
    checkBarMetrics()
    checkBetterDisplay()
    checkHUDPlumbing()
}

private func checkHUDSettings() {
    MainActor.assumeIsolated {
        let suite = "lintel.checks.m3.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = SettingsStore(defaults: defaults, center: NotificationCenter())
        for kind in HUDKind.allCases {
            let keys = Keys.hud(kind)
            check(store[keys.enabled] == false, "\(kind) HUD off by default (enableVolume / enableBrightness false)")
            check(store[keys.style] == .white, "\(kind) style White by default")
            check(store[keys.speed] == .fast, "\(kind) speed Fast by default")
            check(store[keys.showPercentage] == false && store[keys.hideLabel] == false, "\(kind) percentage off, label shown")
            check(store[keys.duration] == 1.5, "\(kind) hold 1.5 s by default")
            check(keys.duration.name == Keys.duration(kind.notification).name, "\(kind) duration shares the alert duration key")
        }
        check(store[Keys.volumeLabelMode] == .device, "volume HUD shows the output device by default")
        check(store[Keys.brightnessTarget] == .automatic, "brightness keys follow the pointer's display by default")
        check(store[Keys.linkHUDAppearance] == false, "linked HUD looks off by default")
        check(store[Keys.accessibilityPrompted] == false, "Accessibility not yet prompted")
        check(store[Keys.displayServicesCapability] == true, "DisplayServices capability on unless switched off")
        store[Keys.volumeHUD.style] = .vivid
        store[Keys.brightnessHUD.speed] = .smooth
        check(defaults.string(forKey: "hud.volume.style") == "vivid" && store[Keys.volumeHUD.style] == .vivid, "style stored as raw value")
        check(store[Keys.brightnessHUD.speed] == .smooth, "speed round-trip")
        defaults.set("decibel", forKey: Keys.volumeHUD.style.name)
        check(store[Keys.volumeHUD.style] == .white, "unknown style falls back to the default")
        defaults.set("YES", forKey: Keys.volumeHUD.enabled.name)
        check(store[Keys.volumeHUD.enabled], "launch-argument style YES enables the HUD")
        defaults.removePersistentDomain(forName: suite)

        let names = Keys.hudKeyNames
        check(names.contains("hud.volume.enabled") && names.contains("hud.brightness.enabled")
              && names.contains("alerts.volume.duration") && names.contains("alerts.brightness.duration"),
              "HUD key names include switches and durations")
        check(names.allSatisfy { $0.contains(".") }, "HUD keys are namespaced")
        let appearance = Set(Keys.volumeHUD.appearanceKeyNames).intersection(Keys.brightnessHUD.appearanceKeyNames)
        check(appearance.isEmpty, "volume and brightness appearance keys are distinct")
    }
}

private func checkLevelSteps() {
    let step = LevelStep.normal
    check(step == 1.0 / 16 && LevelStep.fine == 1.0 / 64, "steps 1/16 and fine 1/64")
    var level = 0.0
    var presses = 0
    while level < 1, presses < 40 {
        level = LevelStepper.step(from: level, up: true, fine: false, hudVisible: false, isRepeat: false).value
        presses += 1
    }
    check(presses == 16 && level == 1, "16 presses from 0 reach 100 % (got \(presses))")
    check(LevelStepper.step(from: 0.12500001, up: true, fine: false, hudVisible: false, isRepeat: false).value == 0.1875,
          "volume 2/16 (+float noise) up → 3/16")
    check(LevelStepper.step(from: 0.12500001, up: false, fine: false, hudVisible: false, isRepeat: false).value == 0.0625,
          "volume 2/16 down → 1/16")
    check(LevelStepper.step(from: 0.13, up: true, fine: false, hudVisible: false, isRepeat: false).value == 0.1875,
          "off-grid level snaps to the next step up")
    check(LevelStepper.step(from: 0.13, up: false, fine: false, hudVisible: false, isRepeat: false).value == 0.125,
          "off-grid level snaps to the next step down")
    let up = LevelStepper.step(from: 0.8750002, up: true, fine: false, hudVisible: false, isRepeat: false)
    check(up.value == 0.9375 && up.overshoot == nil, "brightness 0.875 up → 0.9375")
    check(LevelStepper.step(from: up.value, up: false, fine: false, hudVisible: true, isRepeat: false).value == 0.875,
          "and down again → 0.875")
    check(LevelStepper.step(from: 0.5, up: true, fine: true, hudVisible: false, isRepeat: false).value == 0.5 + 1.0 / 64,
          "⌥⇧ fine step up = 1/64")
    check(LevelStepper.step(from: 0.5, up: false, fine: true, hudVisible: false, isRepeat: false).value == 0.5 - 1.0 / 64,
          "fine step down = 1/64")
    check(LevelStepper.step(from: 1.0 / 64, up: false, fine: false, hudVisible: false, isRepeat: false).value == 0,
          "a normal step down from below 1/16 reaches 0")

    // Overshoot (rubber band at the bounds; a single press overshoots while the HUD is open).
    let firstAtTop = LevelStepper.step(from: 1, up: true, fine: false, hudVisible: false, isRepeat: false)
    check(firstAtTop.value == 1 && firstAtTop.overshoot == nil, "first press at 100 % only shows the HUD")
    check(LevelStepper.step(from: 1, up: true, fine: false, hudVisible: true, isRepeat: false).overshoot == .maximum,
          "press at 100 % with the HUD open overshoots the top")
    check(LevelStepper.step(from: 1, up: true, fine: false, hudVisible: false, isRepeat: true).overshoot == .maximum,
          "held key at 100 % overshoots")
    check(LevelStepper.step(from: 0, up: false, fine: false, hudVisible: true, isRepeat: false).overshoot == .minimum,
          "press at 0 % with the HUD open overshoots the bottom")
    check(LevelStepper.step(from: 0, up: true, fine: false, hudVisible: true, isRepeat: false).overshoot == nil,
          "moving away from a bound never overshoots")
    check(LevelStepper.step(from: 0.9999, up: true, fine: false, hudVisible: true, isRepeat: false).value == 1,
          "values within float noise of a bound count as the bound")
    check(LevelStepper.step(from: .nan, up: true, fine: false, hudVisible: false, isRepeat: false).value == step,
          "an unreadable level starts from 0")
    check(LevelStepper.step(from: 1.3, up: false, fine: false, hudVisible: false, isRepeat: false).value == 0.9375,
          "out-of-range level is clamped first")
}

private func checkMediaKeyDecoding() {
    for key in MediaKey.allCases {
        for down in [true, false] {
            for isRepeat in [false, true] {
                let data1 = MediaKeyDecoder.data1(for: key, down: down, isRepeat: isRepeat)
                let event = MediaKeyDecoder.decode(eventType: 14, subtype: 8, data1: data1, flags: 0)
                check(event == MediaKeyEvent(key: key, isDown: down, isRepeat: isRepeat), "decode \(key.name) down=\(down) repeat=\(isRepeat)")
            }
        }
    }
    // Known layout: volume up key-down is 0x00000A00, mute key-up is 0x00070B00.
    check(MediaKeyDecoder.data1(for: .volumeUp, down: true) == 0x0000_0A00, "data1 layout for volume up")
    check(MediaKeyDecoder.data1(for: .mute, down: false) == 0x0007_0B00, "data1 layout for mute key-up")
    check(MediaKeyDecoder.decode(eventType: 14, subtype: 8, data1: 0x0010_0A00, flags: 0) == nil, "play key (16) is not taken")
    check(MediaKeyDecoder.decode(eventType: 14, subtype: 8, data1: 0x0015_0A00, flags: 0) == nil, "keyboard illumination is not taken")
    check(MediaKeyDecoder.decode(eventType: 14, subtype: 7, data1: 0x0000_0A00, flags: 0) == nil, "other subtypes ignored")
    check(MediaKeyDecoder.decode(eventType: 10, subtype: 8, data1: 0x0000_0A00, flags: 0) == nil, "non-system-defined events ignored")
    check(MediaKeyDecoder.decode(eventType: 14, subtype: 8, data1: 0x0000_0500, flags: 0) == nil, "unknown key state ignored")
    let flags = MediaKeyModifiers.cgAlternate | MediaKeyModifiers.cgShift
    let fine = MediaKeyDecoder.decode(eventType: 14, subtype: 8, data1: 0x0001_0A00, flags: flags)
    check(fine?.modifiers == [.option, .shift] && fine?.modifiers.isFineStep == true, "⌥⇧ decoded as a fine step")
    check(MediaKeyModifiers(cgFlags: MediaKeyModifiers.cgAlternate).opensSettings, "⌥ alone opens settings")
    check(!MediaKeyModifiers([.option, .shift]).opensSettings, "⌥⇧ doesn't open settings")
    let all: MediaKeyModifiers = [.shift, .control, .option, .command]
    check(MediaKeyModifiers(cgFlags: all.cgFlags) == all, "modifier flags round-trip")
    check(MediaKeyModifiers.cgAlternate == CGEventFlags.maskAlternate.rawValue && MediaKeyModifiers.cgShift == CGEventFlags.maskShift.rawValue
          && MediaKeyModifiers.cgControl == CGEventFlags.maskControl.rawValue, "modifier masks match CGEventFlags")

    // The tap's path: a system-defined NSEvent turned into a CGEvent and back keeps subtype and data1.
    MainActor.assumeIsolated {
        for key in MediaKey.allCases {
            let data1 = MediaKeyDecoder.data1(for: key, down: true)
            let ns = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [.option, .shift], timestamp: 0,
                                        windowNumber: 0, context: nil, subtype: MediaKeyDecoder.auxControlButtonsSubtype,
                                        data1: data1, data2: -1)
            guard let cg = ns?.cgEvent, let back = NSEvent(cgEvent: cg) else {
                check(false, "synthesized \(key.name) event converts to CGEvent and back")
                continue
            }
            check(cg.type.rawValue == MediaKeyDecoder.systemDefinedEventType, "\(key.name) CGEvent type is NX_SYSDEFINED")
            let decoded = MediaKeyDecoder.decode(eventType: cg.type.rawValue, subtype: Int16(back.subtype.rawValue),
                                                 data1: back.data1, flags: cg.flags.rawValue)
            check(decoded?.key == key && decoded?.isDown == true && decoded?.modifiers.isFineStep == true,
                  "\(key.name) decodes through the CGEvent round trip")
        }
    }
}

private func checkMediaKeyRouting() {
    var state = MediaKeyRoutingState()
    state.displays = [BrightnessDisplay(id: 1, uuid: "B", isBuiltIn: true, adjustable: true)]
    let up = MediaKeyEvent(key: .volumeUp, isDown: true)
    check(MediaKeyRouter.route(up, state: state, pointerDisplay: 1) == .pass, "volume key passes while the volume HUD is off")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true), state: state, pointerDisplay: 1) == .pass,
          "brightness key passes while the brightness HUD is off")
    state.volumeEnabled = true
    state.brightnessEnabled = true
    check(MediaKeyRouter.route(up, state: state, pointerDisplay: 1)
          == MediaKeyDecision(consume: true, action: .adjustVolume(up: true, fine: false, isRepeat: false)), "volume up taken and applied")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .volumeUp, isDown: false), state: state, pointerDisplay: 1)
          == MediaKeyDecision(consume: true, action: nil), "key-up of a taken key is taken without an action")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .volumeDown, isDown: true, isRepeat: true), state: state, pointerDisplay: 1).action
          == .adjustVolume(up: false, fine: false, isRepeat: true), "auto-repeat adjusts again")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .mute, isDown: true), state: state, pointerDisplay: 1).action == .toggleMute, "mute toggles")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .mute, isDown: true, isRepeat: true), state: state, pointerDisplay: 1)
          == MediaKeyDecision(consume: true, action: nil), "held mute doesn't toggle repeatedly")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .volumeUp, isDown: true, modifiers: [.option, .shift]), state: state, pointerDisplay: 1).action
          == .adjustVolume(up: true, fine: true, isRepeat: false), "⌥⇧ volume key takes a fine step")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .volumeDown, isDown: true, modifiers: [.option]), state: state, pointerDisplay: 1)
          == MediaKeyDecision(consume: true, action: .openSettings(.volume)), "⌥ + volume key opens the Volume settings")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessDown, isDown: true, modifiers: [.option]), state: state, pointerDisplay: 1).action
          == .openSettings(.brightness), "⌥ + brightness key opens the Brightness settings")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true), state: state, pointerDisplay: 1).action
          == .adjustBrightness(up: true, fine: false, isRepeat: false, display: 1), "brightness up adjusts the built-in display")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true, modifiers: [.command]), state: state, pointerDisplay: 1).consume,
          "other modifiers don't change routing")
    var fixed = state
    fixed.volumeAdjustable = false
    check(MediaKeyRouter.route(up, state: fixed, pointerDisplay: 1) == .pass, "output without adjustable volume: macOS keeps the key")
    var noControl = state
    noControl.displays = [BrightnessDisplay(id: 1, uuid: "B", isBuiltIn: true, adjustable: false)]
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true), state: noControl, pointerDisplay: 1) == .pass,
          "brightness keys pass when the display can't be adjusted (DisplayServices off or missing)")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true, modifiers: [.control]), state: state, pointerDisplay: 1) == .pass,
          "ctrl + brightness without an external display passes")
    var withExternal = state
    withExternal.displays.append(BrightnessDisplay(id: 2, uuid: "E", isBuiltIn: false, adjustable: false))
    withExternal.betterDisplayActive = true
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true), state: withExternal, pointerDisplay: 2) == .pass,
          "pointer on a BetterDisplay-managed display: the key goes to BetterDisplay (not handled twice)")
    check(MediaKeyRouter.route(MediaKeyEvent(key: .brightnessUp, isDown: true, modifiers: [.control]), state: withExternal, pointerDisplay: 2).action
          == .adjustBrightness(up: true, fine: false, isRepeat: false, display: 1), "ctrl alternates to the built-in display")
}

private func checkBrightnessTargeting() {
    let builtIn = BrightnessDisplay(id: 1, uuid: "B", isBuiltIn: true, adjustable: true)
    let studio = BrightnessDisplay(id: 2, uuid: "S", isBuiltIn: false, adjustable: true)
    let generic = BrightnessDisplay(id: 3, uuid: "G", isBuiltIn: false, adjustable: false)
    func target(_ mode: BrightnessTargetMode, _ displays: [BrightnessDisplay], pointer: UInt32?, bd: Bool = false, alt: Bool = false) -> UInt32? {
        BrightnessTargeting.target(mode: mode, displays: displays, pointerDisplay: pointer, betterDisplayActive: bd, alternate: alt)?.id
    }
    check(target(.automatic, [builtIn], pointer: 1) == 1, "automatic: built-in under the pointer")
    check(target(.automatic, [builtIn, studio], pointer: 2) == 2, "automatic: an adjustable external display under the pointer")
    check(target(.automatic, [builtIn, generic], pointer: 3) == 1, "automatic: unadjustable external without BetterDisplay → built-in")
    check(target(.automatic, [builtIn, generic], pointer: 3, bd: true) == 3, "automatic: BetterDisplay-managed display under the pointer")
    check(target(.automatic, [builtIn, studio], pointer: nil) == 1, "automatic without a pointer display → built-in")
    check(target(.builtIn, [builtIn, studio], pointer: 2) == 1, "built-in mode ignores the pointer")
    check(target(.external, [builtIn, studio], pointer: 1) == 2, "external mode picks the external display")
    check(target(.external, [builtIn], pointer: 1) == 1, "external mode without an external display falls back to built-in")
    check(target(.automatic, [builtIn, studio], pointer: 1, alt: true) == 2, "ctrl: built-in target alternates to external")
    check(target(.automatic, [builtIn, studio], pointer: 2, alt: true) == 1, "ctrl: external target alternates to built-in")
    check(target(.automatic, [builtIn], pointer: 1, alt: true) == nil, "ctrl with no external display has no target")
    check(target(.automatic, [studio], pointer: 2) == 2, "desktop Mac with a Studio Display")
    check(target(.automatic, [], pointer: nil) == nil, "no displays → no target")
}

private func checkGlyphsAndLabels() {
    check(HUDGlyphs.speaker(level: 0.0625, muted: false) == "speaker.fill", "1/16 shows the bare speaker")
    check(HUDGlyphs.speaker(level: 0.3, muted: false) == "speaker.wave.1.fill", "low level: one wave")
    check(HUDGlyphs.speaker(level: 0.6, muted: false) == "speaker.wave.2.fill", "mid level: two waves")
    check(HUDGlyphs.speaker(level: 1, muted: false) == "speaker.wave.3.fill", "high level: three waves")
    check(HUDGlyphs.speaker(level: 0.6, muted: true) == "speaker.slash.fill", "muted: slashed speaker")
    check(HUDGlyphs.speaker(level: 0, muted: false) == "speaker.slash.fill", "zero volume: slashed speaker")

    let speakers = OutputDeviceInfo(name: "MacBook Air Speakers", transport: .builtIn, dataSource: "ispk")
    let builtInResult = HUDGlyphs.volume(device: speakers, mode: .device, level: 0.0625, muted: false)
    check(builtInResult.label == "Sound" && builtInResult.symbol == "speaker.fill", "built-in speakers read \"Sound\" (test Mac)")
    let jack = OutputDeviceInfo(name: "External Headphones", transport: .builtIn, dataSource: "hdpn")
    check(HUDGlyphs.volume(device: jack, mode: .device, level: 0.5, muted: false) == ("headphones", "External Headphones"),
          "headphone jack shows headphones")
    let airpods = OutputDeviceInfo(name: "Sam’s AirPods Pro", transport: .bluetooth)
    check(HUDGlyphs.volume(device: airpods, mode: .device, level: 0.5, muted: false) == ("airpodspro", "AirPods Pro"),
          "AirPods Pro: model glyph and short name")
    check(HUDGlyphs.volume(device: airpods, mode: .symbol, level: 0.5, muted: false) == ("speaker.wave.2.fill", "Sound"),
          "Show symbol: generic speaker and \"Sound\"")
    check(HUDGlyphs.volume(device: airpods, mode: .device, level: 0.5, muted: true).symbol == "speaker.slash.fill",
          "muted device shows the slashed speaker")
    check(HUDGlyphs.deviceSymbol(OutputDeviceInfo(name: "AirPods Max", transport: .bluetooth)) == "airpodsmax", "AirPods Max glyph")
    check(HUDGlyphs.deviceSymbol(OutputDeviceInfo(name: "Kitchen HomePod mini", transport: .airPlay)) == "homepodmini.fill", "HomePod mini glyph")
    check(HUDGlyphs.deviceSymbol(OutputDeviceInfo(name: "Living Room", transport: .airPlay)) == "airplayaudio", "other AirPlay routes")
    check(HUDGlyphs.deviceSymbol(OutputDeviceInfo(name: "LG UltraFine", transport: .displayPort)) == "display", "display speakers")
    check(HUDGlyphs.deviceSymbol(OutputDeviceInfo(name: "Beats Studio Pro", transport: .bluetooth)) == "beats.headphones", "Beats glyph")
    check(HUDGlyphs.shortName("Alex's AirPods") == "AirPods" && HUDGlyphs.shortName("Studio Display") == "Studio Display",
          "owner prefix dropped only when present")
    check(HUDGlyphs.shortName("  ") == "Sound", "empty device name falls back to Sound")
    check(OutputTransport(fourCC: 0x626C_746E) == .builtIn && OutputTransport(fourCC: 0x626C_7565) == .bluetooth
          && OutputTransport(fourCC: 0x6169_7270) == .airPlay && OutputTransport(fourCC: 0x6864_6D69) == .hdmi
          && OutputTransport(fourCC: 0) == .unknown, "CoreAudio transport codes")
    MainActor.assumeIsolated {
        for symbol in HUDGlyphs.allSymbols {
            check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "SF Symbol \(symbol) exists on this macOS")
        }
        for symbol in ["tortoise.fill", "hare.fill", "bolt.fill", "hand.raised.fill"] {
            check(NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil, "settings symbol \(symbol) exists")
        }
    }
}

private func checkEchoAndFeedback() {
    var echo = EchoFilter()
    echo.recordWrite(0.5, now: 10)
    check(echo.isEcho(0.5, now: 10.2), "own write coming back within 0.45 s is an echo")
    check(echo.isEcho(0.501, now: 10.3), "echo tolerates float rounding")
    check(!echo.isEcho(0.6, now: 10.2), "a different value is a change made elsewhere")
    check(echo.isSettling(now: 10.4), "settling during the echo window")
    check(!echo.isEcho(0.5, now: 10.5) && !echo.isSettling(now: 10.5), "after 0.45 s the same value counts as external")
    echo.recordWrite(0.25, now: 20)
    echo.recordWrite(0.3125, now: 20.05)
    check(echo.isEcho(0.25, now: 20.1), "a stale echo of an earlier write is still recognised")

    check(VolumeFeedback.delay(feedbackEnabled: false, muted: false, changed: true, unmuted: false) == nil,
          "no feedback sound when the system preference is off")
    check(VolumeFeedback.delay(feedbackEnabled: true, muted: false, changed: true, unmuted: false) == 0, "feedback right after a change")
    check(VolumeFeedback.delay(feedbackEnabled: true, muted: false, changed: true, unmuted: true) == VolumeFeedback.unmuteDelay,
          "short delay after unmuting")
    check(VolumeFeedback.delay(feedbackEnabled: true, muted: true, changed: true, unmuted: false) == nil, "no feedback while muted")
    check(VolumeFeedback.delay(feedbackEnabled: true, muted: false, changed: false, unmuted: false) == nil, "no feedback without a change")
}

private func checkBarMetrics() {
    check(HUDBarMetrics.fillWidth(level: 0, trackWidth: 67.5) == 0, "empty track at 0 (and when muted)")
    check(HUDBarMetrics.fillWidth(level: 1.0 / 16, trackWidth: 67.5) == HUDBarMetrics.trackHeight,
          "1/16 draws a dot of the track's height")
    check(near(HUDBarMetrics.fillWidth(level: 0.5, trackWidth: 67.5), 33.75), "half level fills half the track")
    check(HUDBarMetrics.fillWidth(level: 1.4, trackWidth: 67.5) == 67.5, "level clamps to the track")
    check(HUDBarMetrics.percent(0.9375) == 94 && HUDBarMetrics.percent(0.0625) == 6 && HUDBarMetrics.percent(-1) == 0, "percentages")
    check(near(HUDBarMetrics.trackWidth, 67.5) && near(HUDBarMetrics.trackHeight, 4.4, 0.1), "track size fitted to the reference (67.5 × 4.4 pt)")
    check(HUDBarMetrics.overshootDuration == 1.0, "overshoot rubber band lasts about 1 s")
    check(HUDBarSpeed.fast.response < HUDBarSpeed.smooth.response && HUDBarSpeed.instant.response == 0, "speeds ordered, Instant has none")
    check(HUDBarSpeed.smooth.brightnessRamp > 0 && HUDBarSpeed.fast.brightnessRamp == 0, "only Smooth ramps the brightness")
}

private func checkBetterDisplay() {
    let on = BetterDisplayProtocol.requestJSON(integrate: true, requestID: "R1")
    let parsed = (try? JSONSerialization.jsonObject(with: Data(on.utf8))) as? [String: Any]
    let parameters = parsed?["parameters"] as? [String: String]
    check(parsed?["uuid"] as? String == "R1" && (parsed?["commands"] as? [String]) == ["set"], "request carries an id and a set command")
    check(parameters == ["osdIntegrationNotification": "on", "osdShowBasic": "off", "osdShowCustom": "off"],
          "integration request: notifications on, BetterDisplay's own OSDs off")
    check(BetterDisplayProtocol.requestParameters(integrate: false)
          == ["osdIntegrationNotification": "off", "osdShowBasic": "on", "osdShowCustom": "on"], "restore request gives the OSDs back")

    let brightness = BetterDisplayProtocol.parseOSD(
        object: #"{"systemIconID":"brightness","value":48,"maxValue":64,"displayID":4,"UUID":"ABC"}"#, userInfo: nil)
    check(brightness == .init(kind: .brightness, level: 0.75, displayID: 4, displayUUID: "ABC"), "brightness OSD event parsed")
    let volume = BetterDisplayProtocol.parseOSD(object: nil, userInfo: ["icon": "volume", "value": 0.25])
    check(volume?.kind == .volume && volume?.level == 0.25 && volume?.muted == false, "volume OSD from userInfo, 0…1 value")
    let muted = BetterDisplayProtocol.parseOSD(object: #"{"icon":"volumeMute","value":0,"maxValue":100}"#, userInfo: nil)
    check(muted?.kind == .volume && muted?.muted == true, "mute icon marks the volume as muted")
    check(BetterDisplayProtocol.parseOSD(object: #"{"icon":"volume","value":30}"#, userInfo: nil)?.level == 0.3,
          "value above 1 without a maximum is a percentage")
    check(BetterDisplayProtocol.parseOSD(object: #"{"icon":"rotation","value":1}"#, userInfo: nil) == nil, "unknown OSD icons ignored")
    check(BetterDisplayProtocol.parseOSD(object: #"{"icon":"brightness"}"#, userInfo: nil) == nil, "event without a value ignored")
    check(BetterDisplayProtocol.parseOSD(object: "not json", userInfo: nil) == nil, "malformed payload ignored")
}

private func checkHUDPlumbing() {
    check(HUDKind(notification: .volume) == .volume && HUDKind(notification: .brightness) == .brightness
          && HUDKind(notification: .focus) == nil, "HUD kinds map to the Sound / Display notifications")
    check(HUDKind.volume.notification.group == .sound && HUDKind.brightness.notification.group == .display,
          "HUDs belong to the Sound and Display filter groups")
    check(HUDKind.volume.defaultLabel == "Sound" && HUDKind.brightness.defaultLabel == "Display", "HUD labels")
    check(MediaKey(name: "brightnessup") == .brightnessUp && MediaKey(name: "eject") == nil, "media key names")

    check(HUDRouting.screens(target: "B", islands: ["A", "B"]) == ["B"], "HUD shows on the affected display's island")
    check(HUDRouting.screens(target: "C", islands: ["A", "B"]) == ["A", "B"], "affected display without an island: all islands")
    check(HUDRouting.screens(target: nil, islands: ["A"]) == ["A"], "no target: all islands")

    check(SwapPlan.between(.notification(.volume), .notification(.brightness)) == .morph, "volume → brightness HUD swaps in place")
    check(SwapPlan.between(.notification(.brightness), .notification(.focus)) == .contractThenGrow, "HUD → alert still goes via the notch")

    // Hold counted from when the notification is fully shown (grow in ≈ 370–800 ms, then hold 1.5 s).
    let fromLive = SwapTiming.notificationLeadIn(from: .live([.calendar]), to: .notification(.volume), expanded: false)
    check(near(fromLive, 0.79), "lead-in from a live activity: debounce + contract + grow settle ≈ 0.79 s (got \(fromLive))")
    check(fromLive + 1.5 >= 2.2 && fromLive + 1.5 <= 2.5, "collapse ≈ 2.3–2.4 s after the key (grown by ≈ 0.8 s, then ≈ 1.6 s)")
    check(near(SwapTiming.notificationLeadIn(from: .idle, to: .notification(.volume), expanded: false), 0.49), "lead-in from idle: grow only")
    check(SwapTiming.notificationLeadIn(from: .notification(.volume), to: .notification(.volume), expanded: false) == 0,
          "no lead-in for a HUD already showing")
    check(SwapTiming.notificationLeadIn(from: .notification(.volume), to: .notification(.brightness), expanded: false)
          == SwapTiming.debounce + SwapTiming.growSettle, "volume → brightness swaps in place")
    check(SwapTiming.notificationLeadIn(from: .live([.media]), to: .notification(.focus), expanded: true) > 0, "open card: strip lead-in")
    var leadEngine = ActivityEngine()
    check(leadEngine.post(.volume, duration: 0.79 + 1.5, now: 0) == .shown && near(leadEngine.nextDeadline ?? 0, 2.29), "fresh HUD holds lead-in + 1.5 s")
    check(leadEngine.post(.volume, duration: 1.5, now: 0.2) == .extended && near(leadEngine.nextDeadline ?? 0, 2.29),
          "a press during the lead-in doesn't shorten the hold")
    check(leadEngine.post(.volume, duration: 1.5, now: 1.5) == .extended && near(leadEngine.nextDeadline ?? 0, 3.0),
          "a later press extends the hold from the press")

    // Engine: HUD timing model and filters (hold 1.5 s, extend on repeat, Focus / lock switches).
    var engine = ActivityEngine()
    engine.setLive(.calendar, active: true, identity: "event", now: 0)
    check(engine.post(.volume, duration: 1.5, now: 1) == .shown && engine.compactPresentation == .notification(.volume),
          "a volume HUD replaces the live activity")
    check(engine.post(.volume, duration: 1.5, now: 2) == .extended && engine.nextDeadline == 3.5, "a second press extends the hold")
    check(engine.post(.brightness, duration: 1.5, now: 2.5) == .shown && engine.compactPresentation == .notification(.brightness),
          "brightness replaces volume")
    _ = engine.tick(now: 4.0)
    check(engine.compactPresentation == .live([.calendar]), "the live activity returns after the hold")
    engine.filters.allowedWhenFocused.remove(.sound)
    engine.updateContext { $0.focusActive = true }
    check(engine.post(.volume, duration: 1.5, now: 5) == .filtered && engine.post(.brightness, duration: 1.5, now: 5) == .shown,
          "Focus: Sound switched off, Display still allowed")
}
