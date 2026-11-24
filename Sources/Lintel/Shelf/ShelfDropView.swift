import AppKit
import LintelCore

/// The island's drop target.
///
/// Drag and drop only reaches windows at or below the dragging-window level (500): the island's own
/// panels sit far above it (shielding level + 1, so they stay over full-screen apps) and are skipped
/// by every drag. So each island gets a **drop catcher**: a transparent, non-activating panel just
/// below the dragging level that covers exactly the island's current shape. It ignores the mouse
/// except while the left button is dragging, so clicks always reach the island (or pass through to
/// the windows below) and drops onto windows beneath the rest of the canvas keep working.
@MainActor
final class ShelfDropCatcher {
    private(set) weak var island: IslandController?
    private weak var islandPanel: NSPanel?
    private weak var hosting: NSView?
    private let panel: NSPanel
    private var closeObserver: NSObjectProtocol?
    private(set) var accepting = false

    /// One call from `IslandController.init`.
    @discardableResult
    static func install(in islandPanel: NSPanel, hosting: NSView, island: IslandController) -> ShelfDropCatcher {
        let catcher = ShelfDropCatcher(islandPanel: islandPanel, hosting: hosting, island: island)
        catchers[island.plan.screenUUID] = catcher
        return catcher
    }

    private init(islandPanel: NSPanel, hosting: NSView, island: IslandController) {
        self.island = island
        self.islandPanel = islandPanel
        self.hosting = hosting
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 1, height: 1), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.ignoresMouseEvents = true
        // Just below the drag image's level: the highest level drags still reach.
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.draggingWindow)) - 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.sharingType = .none
        let view = ShelfDropView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        view.autoresizingMask = [.width, .height]
        panel.contentView = view
        view.catcher = self
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: islandPanel,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        panel.orderOut(nil)
        panel.close()
        if let key = Self.catchers.first(where: { $0.value === self })?.key { Self.catchers[key] = nil }
    }

    /// The island's current shape (open card, or the hovered compact shape plus the top edge).
    var islandRect: CGRect? {
        guard let island else { return nil }
        let model = island.model
        let plan = island.plan
        if model.phase == .expanded { return plan.islandRect(size: model.expandedSize) }
        var rect = plan.islandRect(size: model.size(for: .elevated)).union(plan.islandRect(size: model.size(for: .idle)))
        if plan.hiddenWhenIdle { rect = rect.union(plan.hoverZone) }
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + 2)
    }

    /// Takes drags over the island while the left button is dragging; otherwise out of the way.
    func setAccepting(_ on: Bool) {
        let usable = on && island.map { $0.visibility != .hidden } == true
        if usable, let rect = islandRect {
            if panel.frame != rect { panel.setFrame(rect, display: false) }
            if !accepting {
                panel.ignoresMouseEvents = false
                panel.orderFrontRegardless()
            }
            accepting = true
        } else {
            if accepting {
                panel.ignoresMouseEvents = true
                panel.orderOut(nil)
            }
            accepting = false
        }
    }

    var frame: CGRect { panel.frame }

    // MARK: Registry

    private static var catchers: [String: ShelfDropCatcher] = [:]

    static var all: [ShelfDropCatcher] { Array(catchers.values) }

    static func catcher(for island: IslandController) -> ShelfDropCatcher? { catchers[island.plan.screenUUID] }

    /// The island whose content panel is `window`.
    static func island(owning window: NSWindow?) -> IslandController? {
        guard let window else { return nil }
        return catchers.values.first { $0.islandPanel === window }?.island
    }

    /// The island's SwiftUI view (anchor for the share picker).
    static func view(for island: IslandController) -> NSView? { catchers[island.plan.screenUUID]?.hosting }

    /// The screen an island is on.
    static func screen(for island: IslandController) -> NSScreen? {
        NSScreen.screens.first { $0.displayUUID == island.plan.screenUUID }
    }
}

/// The catcher's view: registered for everything the Shelf takes and forwarding the drag to it.
final class ShelfDropView: NSView {
    weak var catcher: ShelfDropCatcher?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(ShelfPasteboardReader.draggedTypes)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    private var island: IslandController? { catcher?.island }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let island, let shelf = ShelfFeature.shared else { return [] }
        return shelf.dragEntered(sender, island: island)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let island, let shelf = ShelfFeature.shared else { return [] }
        return shelf.dragUpdated(sender, island: island)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard let island else { return }
        ShelfFeature.shared?.dragExited(island: island)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { ShelfFeature.shared?.isEnabled == true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let island, let shelf = ShelfFeature.shared else { return false }
        return shelf.performDrop(sender, island: island)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        guard let island else { return }
        ShelfFeature.shared?.dragExited(island: island)
    }
}
