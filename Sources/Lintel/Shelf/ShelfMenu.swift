import AppKit
import LintelCore

/// The Shelf's entries in the island's context menu, built like the
/// calendar's region items: `AppDelegate` appends them to the island's `regionItems`.
@MainActor
enum ShelfMenu {
    /// Entries for a right-click on an island; the click hasn't opened the island yet when this runs.
    static func items(controller: IslandController, event: NSEvent) -> [NSMenuItem] {
        guard let shelf = ShelfFeature.shared, shelf.isEnabled else { return [] }
        let model = controller.model
        let height = event.window?.frame.height ?? IslandMetrics.canvasSize.height
        let point = CGPoint(x: event.locationInWindow.x, y: height - event.locationInWindow.y)
        switch model.phase {
        case .expanded:
            guard model.expandedContent == .shelf else { return [] }
            let target = shelf.tileFrames.first { $0.value.contains(point) }?.key
            return items(shelf: shelf, target: target, island: controller)
        case .idle, .elevated:
            // The compact indicator.
            return model.displayed == .live([.shelf]) ? items(shelf: shelf, target: nil, island: controller) : []
        }
    }

    /// The item's entries (when one was clicked), then the Shelf-wide ones.
    static func items(shelf: ShelfFeature, target: String?, island: IslandController? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let id = target, let item = shelf.item(id) {
            let header = NSMenuItem(title: ShelfNaming.truncated(item.name, limit: 42), action: nil, keyEquivalent: "")
            header.isEnabled = false
            items.append(header)
            let usable = item.state.isUsable
            items.append(entry("Open", enabled: usable) { shelf.open(id) })
            if item.kind.isFileBased {
                items.append(entry("Reveal in Finder", enabled: usable) { shelf.reveal(id) })
            }
            items.append(entry("Quick Look", enabled: usable) { shelf.toggleQuickLook(id) })
            // The system share picker (AirDrop, Mail, Messages, …) next to the tile; choosing a service
            // opens that service's own sheet. Lintel sends nothing itself.
            items.append(entry("Share…", enabled: usable && !shelf.shareItems(for: id).isEmpty) {
                shelf.showSharePicker(for: id, island: island)
            })
            items.append(entry("Copy", enabled: usable) { shelf.copyToPasteboard(id) })
            items.append(entry("Remove from Shelf", enabled: true) { shelf.remove([id]) })
        }
        let missing = shelf.items.filter { $0.state.isGone }.count
        guard !shelf.items.isEmpty else { return items }
        if !items.isEmpty { items.append(.separator()) }
        if missing > 0 {
            items.append(entry(missing == 1 ? "Remove Missing Item" : "Remove \(missing) Missing Items", enabled: true) { shelf.removeMissing() })
        }
        items.append(entry("Clear Shelf…", enabled: true) { shelf.confirmClearAll() })
        return items
    }

    /// Joins the calendar's region items and the Shelf's with a separator.
    static func joined(_ first: [NSMenuItem], _ second: [NSMenuItem]) -> [NSMenuItem] {
        guard !first.isEmpty, !second.isEmpty else { return first + second }
        return first + [.separator()] + second
    }

    private static func entry(_ title: String, enabled: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, key: "", handler: action)
        if !enabled {
            item.target = nil
            item.action = nil
            item.isEnabled = false
        }
        return item
    }
}

/// Shows the system share picker for a Shelf item. Lintel is never the
/// active app, so a click elsewhere doesn't close the picker by itself: while it shows, mouse-down
/// monitors close it on any click outside it. Lintel never chooses a service itself.
@MainActor
final class ShelfSharePresenter: NSObject, NSSharingServicePickerDelegate {
    private var picker: NSSharingServicePicker?
    private var monitors: [Any] = []
    var onLog: ((String) -> Void)?

    var isShown: Bool { picker != nil }

    func show(_ items: [Any], relativeTo rect: CGRect, of view: NSView) {
        close()
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        self.picker = picker
        picker.show(relativeTo: rect, of: view, preferredEdge: .minY)
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            // The picker's own window sits at the pop-up menu level.
            let inPicker = event.window?.level == .popUpMenu
            MainActor.assumeIsolated { if !inPicker { self?.close() } }
            return event
        }) { monitors.append(monitor) }
    }

    func close() {
        removeMonitors()
        let shown = picker
        picker = nil
        shown?.close()
    }

    private func removeMonitors() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    nonisolated func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) {
        // Never logs which service or person was chosen.
        let chose = service != nil
        MainActor.assumeIsolated {
            onLog?(chose ? "share: a service was chosen" : "share closed")
            removeMonitors()
            picker = nil
        }
    }
}
