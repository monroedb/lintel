import AppKit
import LintelCore

/// Media entries of the island's context menu: Play/Pause, Previous,
/// Next, Back/Forward (podcasts), Speed, Source, Copy Link and Show in ⟨App⟩.
@MainActor
enum NowPlayingMenu {
    /// Rates offered in the Speed submenu; the System source (MediaRemote adapter) takes whole
    /// numbers only.
    static func rates(for source: MediaProviderKind?) -> [Double] {
        source == .system ? [1, 2] : [0.5, 0.75, 1, 1.25, 1.5, 2]
    }

    static func items(center: NowPlayingCenter, settings: SettingsStore) -> [NSMenuItem] {
        guard let controller = center.controller, let track = center.track else { return [] }
        let info = track.info
        var items: [NSMenuItem] = []
        items.append(ClosureMenuItem(title: info.playing ? "Pause" : "Play", key: "") { center.togglePlayPause() })
        if track.capabilities.contains(.nextPrevious) {
            items.append(ClosureMenuItem(title: "Previous", key: "") { center.perform(.previous) })
            items.append(ClosureMenuItem(title: "Next", key: "") { center.perform(.next) })
        }
        if track.capabilities.contains(.skipInterval) || info.kind == .podcast {
            items.append(ClosureMenuItem(title: "Back 15 Seconds", key: "") { center.perform(.skip(by: -15)) })
            items.append(ClosureMenuItem(title: "Forward 15 Seconds", key: "") { center.perform(.skip(by: 15)) })
        }
        let source = controller.resolvedSource
        if track.capabilities.contains(.rate), source != nil {
            let speed = NSMenuItem(title: "Speed", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for rate in rates(for: source) {
                let item = ClosureMenuItem(title: rateTitle(rate), key: "") { center.perform(.setRate(rate)) }
                item.state = info.playing && abs(info.rate - rate) < 0.01 ? .on : .off
                submenu.addItem(item)
            }
            speed.submenu = submenu
            items.append(speed)
        }
        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        let sources = NSMenu()
        let automatic = settings[Keys.mediaAutomaticSource]
        let automaticItem = ClosureMenuItem(title: "Automatic", key: "") { controller.chooseSource(automatic: !automatic, manual: nil) }
        automaticItem.state = automatic ? .on : .off
        sources.addItem(automaticItem)
        sources.addItem(.separator())
        for choice in [MediaSourceChoice.music, .spotify, .system] {
            let item = ClosureMenuItem(title: choice.title, key: "") { controller.chooseSource(automatic: false, manual: choice) }
            item.state = !automatic && settings[Keys.mediaSource] == choice ? .on : .off
            sources.addItem(item)
        }
        sourceItem.submenu = sources
        items.append(sourceItem)
        if track.canCopyLink {
            items.append(ClosureMenuItem(title: "Copy Link", key: "") { center.copyLink() })
        }
        if let app = track.appName {
            items.append(ClosureMenuItem(title: "Show in \(app)", key: "") { center.showSourceApp() })
        }
        return items
    }

    static func rateTitle(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? String(Int(rate)) : String(format: "%g", rate)
        return "\(text)×"
    }
}
