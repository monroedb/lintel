import AppKit
import LintelCore
import SwiftUI

/// Tile geometry shared by the SwiftUI tile and its AppKit mouse layer.
enum ShelfTileMetrics {
    static let width: CGFloat = 58
    static let height: CGFloat = 84
    static let spacing: CGFloat = 5.75
    static let thumbnail: CGFloat = 52
    static let rowTop: CGFloat = 42
    /// The × button: a 16 pt circle on the thumbnail's top-right corner.
    static let removeSize: CGFloat = 16
    static var removeCenter: CGPoint { CGPoint(x: (width + thumbnail) / 2 - 3, y: 3) }
    static var removeHitRect: CGRect {
        CGRect(x: removeCenter.x - 10, y: removeCenter.y - 10, width: 20, height: 20)
    }
}

/// Mouse handling for a tile (or, with `ids == nil`, the header: drags every item). AppKit gives the
/// Shelf a real drag source with a copy-only operation, multi-item drags and a thumbnail drag image;
/// right and middle clicks go on to the island so its menu and cycling work as everywhere else.
final class ShelfTileMouseView: NSView, NSDraggingSource {
    var itemID: String?
    /// The row behind the tiles: only turns pages with the mouse wheel and passes clicks on.
    var isRow = false
    private var hoverArea: NSTrackingArea?
    private var downPoint: CGPoint?
    private var dragged = false
    private var pressedRemove = false
    private var hovered = false
    private var lastPageTurn: TimeInterval = 0

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The open card's views stay in the island's view tree (transparent) while it is compact; the
    /// Shelf's mouse layer only acts while the island is open on the Shelf page, so it never takes a
    /// click meant for the compact island.
    private var islandShowsShelf: Bool {
        guard let island = ShelfDropCatcher.island(owning: window) else { return false }
        return island.model.phase == .expanded && island.model.expandedContent == .shelf
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        islandShowsShelf ? super.hitTest(point) : nil
    }

    /// One tracking area that follows the visible rect, installed when the view joins its window
    /// (SwiftUI lays the card out while it is still transparent, so AppKit may not ask again).
    private func installTracking() {
        // Other areas may exist (AppKit adds one for the tooltip); only ours matters here.
        if let hoverArea, trackingAreas.contains(hoverArea) { return }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        installTracking()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installTracking()
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered()
    }

    /// Also on moves inside: an entry can be missed when the island opens under a still pointer.
    override func mouseMoved(with event: NSEvent) {
        if !hovered { setHovered() }
    }

    private func setHovered() {
        guard !isRow else { return }
        ShelfFeature.shared?.hoverEvents += 1
        guard islandShowsShelf else { return }
        hovered = true
        if let itemID { ShelfFeature.shared?.hover(itemID, inside: true) }
    }

    override func mouseExited(with event: NSEvent) {
        guard !isRow else { return }
        hovered = false
        if let itemID { ShelfFeature.shared?.hover(itemID, inside: false) }
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRow else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        downPoint = point
        dragged = false
        // The × only counts while it is shown (the tile is hovered).
        pressedRemove = hovered && itemID != nil && ShelfTileMetrics.removeHitRect.contains(point)
        if !hovered { setHovered() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isRow, let downPoint, !dragged, !pressedRemove else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 else { return }
        dragged = true
        startDrag(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { downPoint = nil; pressedRemove = false }
        guard downPoint != nil, !dragged, let shelf = ShelfFeature.shared else { return }
        let point = convert(event.locationInWindow, from: nil)
        if pressedRemove {
            if let itemID, ShelfTileMetrics.removeHitRect.contains(point) { shelf.remove([itemID]) }
            return
        }
        guard let itemID, bounds.contains(point) else { return }
        shelf.open(itemID)
    }

    override func rightMouseDown(with event: NSEvent) { islandHost?.rightMouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { islandHost?.otherMouseDown(with: event) }

    /// A mouse wheel turns pages; trackpad scrolls stay the island's swipes.
    override func scrollWheel(with event: NSEvent) {
        guard !event.hasPreciseScrollingDeltas, let shelf = ShelfFeature.shared else {
            super.scrollWheel(with: event)
            return
        }
        // One notch turns one page; a fast spin turns at most one page per 0.25 s.
        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        guard abs(delta) >= 0.5, event.timestamp - lastPageTurn > 0.25 else { return }
        lastPageTurn = event.timestamp
        shelf.showPage(shelf.page + (delta < 0 ? 1 : -1))
    }

    private var islandHost: NSView? {
        var view = superview
        while let current = view {
            if current is IslandHostingView { return current }
            view = current.superview
        }
        return nil
    }

    // MARK: Dragging out

    private func startDrag(with event: NSEvent) {
        guard let shelf = ShelfFeature.shared else { return }
        let items = itemID.map { id in shelf.items.filter { $0.id == id } } ?? shelf.items
        var dragging: [NSDraggingItem] = []
        let origin = convert(event.locationInWindow, from: nil)
        for (offset, item) in items.enumerated() where item.state.isUsable {
            guard let writer = shelf.pasteboardWriter(for: item) else { continue }
            let draggingItem = NSDraggingItem(pasteboardWriter: writer)
            let image = shelf.dragImage(for: item)
            let size = CGSize(width: ShelfTileMetrics.thumbnail, height: ShelfTileMetrics.thumbnail)
            let shift = CGFloat(min(offset, 4)) * 6
            draggingItem.setDraggingFrame(CGRect(x: origin.x - size.width / 2 + shift, y: origin.y - size.height / 2 + shift,
                                                 width: size.width, height: size.height), contents: image)
            dragging.append(draggingItem)
        }
        guard !dragging.isEmpty else {
            shelf.log("drag refused")
            return
        }
        shelf.outgoingDrag = true
        let session = beginDraggingSession(with: dragging, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
        shelf.log("drag out \(dragging.count)")
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy only: a drag from the Shelf never moves the original (inside Lintel: nothing).
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        ShelfFeature.shared?.outgoingDrag = false
        ShelfFeature.shared?.log("drag ended \(operation.rawValue)")
    }
}

/// SwiftUI wrapper for the tile's mouse layer.
struct ShelfTileMouseArea: NSViewRepresentable {
    let itemID: String?
    var help = ""
    var isRow = false

    func makeNSView(context: Context) -> ShelfTileMouseView {
        let view = ShelfTileMouseView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ShelfTileMouseView, context: Context) {
        view.itemID = itemID
        view.isRow = isRow
        view.toolTip = help.isEmpty ? nil : help
    }
}
