import AppKit
import LintelCore
import Observation
import UniformTypeIdentifiers

/// What the island's compact indicator shows. The identity changes
/// with every drop, so a new drop brings a dismissed indicator back.
struct ShelfSnapshot: Equatable {
    var identity: String
    var count: Int
}

/// A file drag over an island (one at a time).
struct ShelfDropState: Equatable {
    var screen: String
    var count: Int
    var targeted: Bool
}

/// The Shelf: items, the index on disk, drops, actions,
/// references to originals, keyboard focus and Quick Look. One per app; views reach it through
/// `shared`.
@MainActor
@Observable
final class ShelfFeature {
    static var shared: ShelfFeature?

    /// Newest first.
    private(set) var items: [ShelfItem] = []
    private(set) var drop: ShelfDropState?
    private(set) var hoveredID: String?
    private(set) var page = 0
    /// Items of the latest drop (copper ring for 1.6 s).
    private(set) var highlighted: Set<String> = []
    private(set) var clearArmed = false
    /// Shown under the header and in Settings ("Couldn't save the Shelf").
    private(set) var problem: String?
    private(set) var thumbnails: [String: NSImage] = [:]
    private(set) var storedBytes: Int64?

    @ObservationIgnored let settings: SettingsStore
    @ObservationIgnored let hub: ActivityHub
    @ObservationIgnored let paths: ShelfPaths
    @ObservationIgnored let locations: ShelfLocations
    @ObservationIgnored weak var coordinator: DisplayCoordinator?
    @ObservationIgnored let keyboard = ShelfKeyboardFocus()
    @ObservationIgnored let quickLook = ShelfQuickLook()
    /// Tile frames in the island's view coordinates (top-left origin), for menus and Quick Look.
    @ObservationIgnored var tileFrames: [String: CGRect] = [:]
    @ObservationIgnored private(set) var actionLog: [String] = []
    @ObservationIgnored private(set) var drops = 0
    @ObservationIgnored private(set) var readOnly = false
    @ObservationIgnored private(set) var saves = 0
    @ObservationIgnored private(set) var validations = 0
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var clearConfirmation = ShelfClearConfirmation()
    @ObservationIgnored private var clearTask: Task<Void, Never>?
    @ObservationIgnored private var highlightTask: Task<Void, Never>?
    @ObservationIgnored private var focusTask: Task<Void, Never>?
    @ObservationIgnored private var receivers: [String: NSFilePromiseReceiver] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var monitors: [Any] = []
    /// The user typed something else: the keyboard stays with the frontmost app until the pointer
    /// leaves the island.
    @ObservationIgnored private(set) var gaveBackKeyboard = false
    @ObservationIgnored let share = ShelfSharePresenter()
    /// A drag that started on the Shelf is in progress.
    @ObservationIgnored var outgoingDrag = false
    /// Tile hover events seen.
    @ObservationIgnored var hoverEvents = 0
    @ObservationIgnored private var catcherReset: Task<Void, Never>?
    /// Island models whose phase and page the keyboard focus follows.
    @ObservationIgnored private var trackedModels: Set<ObjectIdentifier> = []

    init(settings: SettingsStore, hub: ActivityHub, paths: ShelfPaths = .standard) {
        self.settings = settings
        self.hub = hub
        self.paths = paths
        locations = ShelfLocations(home: NSHomeDirectory(),
                                   temporaryRoots: ["/private/var/folders", "/var/folders", "/private/tmp", "/tmp", NSTemporaryDirectory()])
        Self.shared = self
        load()
        publish()
    }

    var isEnabled: Bool { settings[Keys.shelfEnabled] }
    var storageMode: ShelfStorageMode { settings[Keys.shelfStorage] }

    func item(_ id: String) -> ShelfItem? { items.first { $0.id == id } }

    func start(coordinator: DisplayCoordinator) {
        self.coordinator = coordinator
        keyboard.onKey = { [weak self] key in self?.handleKey(key) }
        quickLook.feature = self
        observers.append(NotificationCenter.default.addObserver(forName: .lintelSettingDidChange, object: nil, queue: .main) { [weak self] note in
            let key = note.userInfo?["key"] as? String ?? "*"
            MainActor.assumeIsolated { self?.settingDidChange(key) }
        })
        // Another app came to the front (one the Shelf opened, or the user's click): its keystrokes
        // must reach it, so the Shelf gives the keyboard back until the pointer leaves the island.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                                          object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let other = app?.processIdentifier != ProcessInfo.processInfo.processIdentifier
            MainActor.assumeIsolated { if other { self?.giveBackKeyboard() } }
        })
        // Keyboard focus follows the pointer over an open Shelf page.
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeyboardFocus() }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.updateKeyboardFocus() }
            return event
        }) { monitors.append(monitor) }
        // The drop catchers take drags only while the left button is dragging.
        let drags: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: drags, handler: { [weak self] event in
            let dragging = event.type == .leftMouseDragged
            MainActor.assumeIsolated { self?.leftButton(dragging: dragging) }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: drags, handler: { [weak self] event in
            let dragging = event.type == .leftMouseDragged
            MainActor.assumeIsolated { self?.leftButton(dragging: dragging) }
            return event
        }) { monitors.append(monitor) }
        validate(includeProtected: false)
    }

    // MARK: Settings

    private func settingDidChange(_ key: String) {
        guard key == "*" || key.hasPrefix(Keys.shelfKeyPrefix) else { return }
        coordinator?.controllers.values.forEach { $0.applyActivitySettings() }
        if !isEnabled {
            drop = nil
            quickLook.close()
            updateKeyboardFocus()
        }
        publish()
    }

    /// Updates the hub (compact indicator) after every change.
    func publish() {
        let show = isEnabled && settings[Keys.shelfIndicator] && !items.isEmpty
        hub.setShelf(show ? ShelfSnapshot(identity: "drop-\(drops)", count: items.count) : nil)
    }

    // MARK: Index

    private func load() {
        guard let data = try? Data(contentsOf: paths.index) else { return }
        switch ShelfIndex.load(data) {
        case .loaded(let index):
            drops = index.drops
            var leftovers: [URL] = []
            items = index.items.map { item in
                var item = item
                if item.state == .pending {
                    // Copying or receiving when Lintel quit: the partial files go.
                    item.state = .failed
                    leftovers.append(paths.itemFolder(id: item.id))
                }
                return item
            }
            for item in items where item.hasThumbnail {
                thumbnails[item.id] = NSImage(contentsOf: paths.thumbnail(id: item.id))
            }
            sweepOrphans(keeping: Set(items.map(\.id)))
            if !leftovers.isEmpty {
                let root = paths.root
                Task { _ = await ShelfFileWork.delete(leftovers, storageRoot: root) }
                scheduleSave()
            }
        case .newer(let version):
            readOnly = true
            problem = "This Shelf was saved by a newer version of Lintel, so changes here aren't saved."
            shelfLog.error("Shelf index has a newer format (\(version)); not overwritten")
        case .corrupt:
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = paths.root.appendingPathComponent("Shelf.corrupt-\(stamp).json")
            try? FileManager.default.moveItem(at: paths.index, to: aside)
            shelfLog.error("Unreadable Shelf index moved aside; the Shelf starts empty")
        }
    }

    private var index: ShelfIndex { ShelfIndex(drops: drops, items: items) }

    /// Item folders and thumbnails that no item owns (left by a crash or a forced quit mid-drop) go.
    private func sweepOrphans(keeping ids: Set<String>) {
        let manager = FileManager.default
        let owned = Set(ids.map { ShelfNaming.safeFileName($0) })
        var orphans: [URL] = []
        if let folders = try? manager.contentsOfDirectory(at: paths.items, includingPropertiesForKeys: nil) {
            orphans += folders.filter { !owned.contains($0.lastPathComponent) }
        }
        if let thumbnails = try? manager.contentsOfDirectory(at: paths.thumbnails, includingPropertiesForKeys: nil) {
            orphans += thumbnails.filter { !owned.contains($0.deletingPathExtension().lastPathComponent) }
        }
        guard !orphans.isEmpty else { return }
        shelfLog.notice("Removing \(orphans.count) leftover Shelf files")
        let root = paths.root
        Task { _ = await ShelfFileWork.delete(orphans, storageRoot: root) }
    }

    private func scheduleSave() {
        guard !readOnly else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self else { return }
            guard let data = try? ShelfIndex.encoder().encode(self.index) else { return }
            let error = await ShelfFileWork.write(data, to: self.paths.index)
            self.saves += 1
            self.problem = error == nil ? nil : "Couldn't save the Shelf"
            if let error { shelfLog.error("Couldn't save the Shelf: \(error, privacy: .public)") }
        }
    }

    /// Writes pending changes at once (quit).
    func saveNow() {
        guard !readOnly, saveTask != nil else { return }
        saveTask?.cancel()
        saveTask = nil
        guard let data = try? ShelfIndex.encoder().encode(index) else { return }
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        try? data.write(to: paths.index, options: .atomic)
    }

    // MARK: Dropping

    /// While the left button drags (anything, anywhere), every island's catcher covers its island and
    /// takes drags; half a second after the button is released they step aside again. A drag that
    /// isn't a drag session (moving a window, selecting text) is unaffected: its events stay with the
    /// window that got the mouse-down.
    private func leftButton(dragging: Bool) {
        if dragging {
            guard isEnabled, !outgoingDrag else { return }
            catcherReset?.cancel()
            catcherReset = nil
            for catcher in ShelfDropCatcher.all { catcher.setAccepting(true) }
        } else if ShelfDropCatcher.all.contains(where: \.accepting), catcherReset == nil {
            catcherReset = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { return }
                for catcher in ShelfDropCatcher.all { catcher.setAccepting(false) }
                self?.catcherReset = nil
            }
        }
    }

    func dragEntered(_ info: NSDraggingInfo, island: IslandController) -> NSDragOperation {
        guard isEnabled, island.visibility != .hidden, !hub.locked else { return [] }
        if info.draggingSource is ShelfTileMouseView { return [] }
        let types = Set(info.draggingPasteboard.types?.map(\.rawValue) ?? [])
        guard ShelfImportPlanner.accepts(types: types) else { return [] }
        let operation = Self.operation(for: info.draggingSourceOperationMask)
        guard operation != [] else { return [] }
        let count = max(1, info.draggingPasteboard.pasteboardItems?.count ?? info.numberOfValidItemsForDrop)
        drop = ShelfDropState(screen: island.plan.screenUUID, count: count, targeted: true)
        island.activity.mutate { $0.focusShelfForDrop() }
        island.performOpen()
        // The catcher grows with the island to the open card.
        ShelfDropCatcher.catcher(for: island)?.setAccepting(true)
        return operation
    }

    func dragUpdated(_ info: NSDraggingInfo, island: IslandController) -> NSDragOperation {
        guard let drop, drop.screen == island.plan.screenUUID else { return dragEntered(info, island: island) }
        if !drop.targeted { self.drop?.targeted = true }
        return Self.operation(for: info.draggingSourceOperationMask)
    }

    /// The Shelf copies or links what it's given; it never answers with a move, which could make the
    /// source delete its original.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        if mask.contains(.copy) { return .copy }
        if mask.contains(.generic) { return .generic }
        if mask.contains(.link) { return .link }
        return []
    }

    func dragExited(island: IslandController) {
        if drop?.screen == island.plan.screenUUID { drop = nil }
    }

    func performDrop(_ info: NSDraggingInfo, island: IslandController) -> Bool {
        defer { drop = nil }
        guard drop != nil || dragEntered(info, island: island) != [] else { return false }
        let taken = importPasteboard(info.draggingPasteboard)
        island.activity.mutate { $0.focusShelfForDrop() }
        if taken > 0 { island.haptics.perform(.levelChange) }
        updateKeyboardFocus()
        return taken > 0
    }

    // MARK: Adding

    /// Reads a drop (or a named pasteboard) and adds what the Shelf can keep. Returns how many items
    /// were taken.
    @discardableResult
    func importPasteboard(_ pasteboard: NSPasteboard) -> Int {
        add(ShelfPasteboardReader.read(pasteboard, locations: locations))
    }

    @discardableResult
    func add(_ incoming: [ShelfIncoming], mode override: ShelfStorageMode? = nil) -> Int {
        guard isEnabled, !incoming.isEmpty else { return 0 }
        let now = Date()
        let mode = override ?? storageMode
        var batch: [ShelfItem] = []
        var followups: [String: ShelfFollowup] = [:]
        for thing in incoming {
            guard let (item, followup) = makeItem(thing, mode: mode, now: now) else { continue }
            batch.append(item)
            followups[item.id] = followup
        }
        guard !batch.isEmpty else { return 0 }
        let result = ShelfOrdering.inserting(batch, into: items, now: now)
        items = result.items
        drops += 1
        for id in result.front {
            if let followup = followups[id] { run(followup, for: id) }
        }
        page = 0
        highlight(Set(result.front))
        clearConfirmation.reset()
        clearArmed = false
        log("add \(batch.map(\.kind.rawValue).joined(separator: ","))")
        scheduleSave()
        publish()
        return batch.count
    }

    private func makeItem(_ thing: ShelfIncoming, mode: ShelfStorageMode, now: Date) -> (ShelfItem, ShelfFollowup)? {
        let id = UUID().uuidString
        switch thing {
        case .file(let url):
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .typeIdentifierKey, .fileSizeKey, .contentModificationDateKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            let path = url.standardizedFileURL.path
            let isFolder = values.isDirectory == true && values.isPackage != true
            let type = values.typeIdentifier
            let kind: ShelfItemKind = isFolder ? .folder : (type.flatMap(UTType.init)?.conforms(to: .image) == true ? .image : .file)
            let name = url.lastPathComponent
            let size = values.fileSize.map(Int64.init)
            if mode == .reference, !locations.isTemporary(path), let bookmark = try? url.bookmarkData() {
                let item = ShelfItem(id: id, kind: kind, name: name, typeIdentifier: type, byteSize: size, added: now,
                                     storage: .reference(bookmark: bookmark, path: path),
                                     fingerprint: ShelfOrdering.fingerprint(referencePath: path),
                                     isProtected: locations.isProtected(path), modified: values.contentModificationDate)
                return (item, .thumbnail(url))
            }
            let stored = ShelfNaming.safeFileName(name)
            let item = ShelfItem(id: id, kind: kind, name: name, typeIdentifier: type, byteSize: size, added: now,
                                 storage: .stored(relativePath: ShelfStoragePolicy.itemFolder(id: id) + "/" + stored, originalPath: path),
                                 state: .pending, modified: values.contentModificationDate)
            return (item, .copy(url, name: stored))
        case .promise(let receiver, let sourceURL):
            let suggested = receiver.fileNames.first.map { ShelfNaming.safeFileName($0) } ?? "Received file"
            let types = receiver.fileTypes
            let isImage = types.contains { UTType($0)?.conforms(to: .image) == true }
            let item = ShelfItem(id: id, kind: isImage ? .image : .file, name: suggested, typeIdentifier: types.first, added: now,
                                 storage: .stored(relativePath: ShelfStoragePolicy.itemFolder(id: id) + "/" + suggested, originalPath: nil),
                                 state: .pending, fingerprint: Self.webSource(sourceURL).map(ShelfOrdering.fingerprint(source:)),
                                 sourceURL: sourceURL)
            return (item, .promise(receiver))
        case .image(let data, let fileExtension, let sourceURL):
            let name = ShelfNaming.imageFileName(sourceURL: sourceURL, fileExtension: fileExtension, date: now)
            let item = ShelfItem(id: id, kind: .image, name: name, typeIdentifier: UTType(filenameExtension: fileExtension)?.identifier,
                                 byteSize: Int64(data.count), added: now,
                                 storage: .stored(relativePath: ShelfStoragePolicy.itemFolder(id: id) + "/" + name, originalPath: nil),
                                 state: .pending, fingerprint: Self.webSource(sourceURL).map(ShelfOrdering.fingerprint(source:)),
                                 sourceURL: sourceURL)
            return (item, .data(data, name: name))
        case .link(let url, let title):
            let name = ShelfNaming.linkTitle(url: url, title: title)
            let file = ShelfNaming.safeFileName(name, fallback: "Link") + ".webloc"
            let item = ShelfItem(id: id, kind: .link, name: name, typeIdentifier: "com.apple.web-internet-location", added: now,
                                 storage: .stored(relativePath: ShelfStoragePolicy.itemFolder(id: id) + "/" + file, originalPath: nil),
                                 link: ShelfLink(url: url, title: title), fingerprint: ShelfOrdering.fingerprint(link: url))
            return (item, .link(url, name: file))
        case .text(let text):
            let name = ShelfNaming.textTitle(text)
            let file = ShelfNaming.safeFileName(name, fallback: "Text") + ".txt"
            let item = ShelfItem(id: id, kind: .text, name: name, typeIdentifier: UTType.plainText.identifier,
                                 byteSize: Int64(text.utf8.count), added: now,
                                 storage: .stored(relativePath: ShelfStoragePolicy.itemFolder(id: id) + "/" + file, originalPath: nil),
                                 textPreview: ShelfNaming.textPreview(text), fingerprint: ShelfOrdering.fingerprint(text: text))
            return (item, .text(text, name: file))
        }
    }

    /// A source address that identifies a received picture (web and file addresses, not page text).
    static func webSource(_ url: String?) -> String? {
        guard let url, let scheme = URL(string: url)?.scheme?.lowercased(), ["http", "https", "file"].contains(scheme) else { return nil }
        return url
    }

    private func run(_ followup: ShelfFollowup, for id: String) {
        let folder = paths.itemFolder(id: id)
        switch followup {
        case .thumbnail(let url):
            makeThumbnail(id: id, from: url)
        case .copy(let source, let name):
            Task {
                let result = await ShelfFileWork.copy(source, into: folder, name: name)
                self.finishStoring(id: id, result: result)
            }
        case .data(let data, let name):
            Task {
                let result = await ShelfFileWork.store(data, in: folder, name: name)
                self.finishStoring(id: id, result: result)
            }
        case .text(let text, let name):
            Task { _ = await ShelfFileWork.store(Data(text.utf8), in: folder, name: name) }
        case .link(let url, let name):
            let plist = (try? PropertyListSerialization.data(fromPropertyList: ["URL": url], format: .xml, options: 0)) ?? Data()
            Task { _ = await ShelfFileWork.store(plist, in: folder, name: name) }
        case .promise(let receiver):
            receive(receiver, id: id, into: folder)
        }
    }

    /// Browser and app file promises arrive later; the tile shows a spinner meanwhile.
    private func receive(_ receiver: NSFilePromiseReceiver, id: String, into folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        receivers[id] = receiver
        // @Sendable: AppKit calls the reader on the operation queue, off the main thread.
        receiver.receivePromisedFiles(atDestination: folder, options: [:], operationQueue: Self.promiseQueue) { @Sendable url, error in
            let path = url.path
            let message = error?.localizedDescription
            Task { @MainActor in ShelfFeature.shared?.promiseReceived(id: id, path: path, error: message) }
        }
    }

    private static let promiseQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.sashagilliard.lintel.shelf.promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    private func promiseReceived(id: String, path: String, error: String?) {
        receivers[id] = nil
        guard let error else {
            finishStoring(id: id, result: .success(URL(fileURLWithPath: path)))
            return
        }
        shelfLog.error("A promised file didn't arrive: \(error, privacy: .public)")
        finishStoring(id: id, result: .failure(ShelfFileError(NSError(domain: "Shelf", code: 1, userInfo: [NSLocalizedDescriptionKey: error]))))
    }

    private func finishStoring(id: String, result: Result<URL, ShelfFileError>) {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            // Removed meanwhile: what arrived goes too.
            let root = paths.root, folder = paths.itemFolder(id: id)
            Task { _ = await ShelfFileWork.delete([folder], storageRoot: root) }
            return
        }
        switch result {
        case .success(let url):
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .typeIdentifierKey, .fileSizeKey])
            var item = items[index]
            item.storage = .stored(relativePath: paths.relative(url) ?? ShelfStoragePolicy.itemFolder(id: id) + "/" + url.lastPathComponent,
                                   originalPath: item.originalPath)
            item.state = .available
            if item.originalPath == nil, item.kind != .text, item.kind != .link { item.name = url.lastPathComponent }
            if let type = values?.typeIdentifier { item.typeIdentifier = type }
            if values?.isDirectory == true, values?.isPackage != true {
                item.kind = .folder
            } else if item.kind != .folder {
                item.kind = item.typeIdentifier.flatMap(UTType.init)?.conforms(to: .image) == true ? .image : .file
            }
            if let size = values?.fileSize { item.byteSize = Int64(size) }
            items[index] = item
            makeThumbnail(id: id, from: url)
        case .failure(let error):
            items[index].state = .failed
            shelfLog.error("Couldn't store a Shelf item: \(error.message, privacy: .public)")
            let root = paths.root, folder = paths.itemFolder(id: id)
            Task { _ = await ShelfFileWork.delete([folder], storageRoot: root) }
        }
        scheduleSave()
    }

    private func makeThumbnail(id: String, from url: URL) {
        let output = paths.thumbnail(id: id)
        Task {
            var made = await ShelfFileWork.thumbnail(of: url, to: output)
            if !made {
                // No preview: the file's Finder icon (made here, on the main actor).
                var rect = CGRect(x: 0, y: 0, width: 104, height: 104)
                if let icon = NSWorkspace.shared.icon(forFile: url.path).cgImage(forProposedRect: &rect, context: nil, hints: nil) {
                    made = await ShelfFileWork.writeThumbnail(icon, to: output)
                }
            }
            self.thumbnailMade(id: id, made: made)
        }
    }

    private func thumbnailMade(id: String, made: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].hasThumbnail = made
        thumbnails[id] = made ? NSImage(contentsOf: paths.thumbnail(id: id)) : nil
        scheduleSave()
    }

    private func highlight(_ ids: Set<String>) {
        highlighted = ids
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            self?.highlighted = []
        }
    }

    // MARK: Removing

    func remove(_ ids: Set<String>) {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        var urls: [URL] = []
        for item in removed {
            // Lintel's own files only: the item's folder (copies, received files, clips) and its
            // thumbnail. A reference's original is never touched.
            if case .stored = item.storage { urls.append(paths.itemFolder(id: item.id)) }
            urls.append(paths.thumbnail(id: item.id))
            thumbnails[item.id] = nil
            tileFrames[item.id] = nil
            receivers[item.id] = nil
        }
        let root = paths.root
        Task { _ = await ShelfFileWork.delete(urls, storageRoot: root) }
        if let hoveredID, ids.contains(hoveredID) { self.hoveredID = nil }
        page = ShelfPaging.clamped(page, count: items.count)
        highlighted.subtract(ids)
        log("remove \(removed.count)")
        quickLook.itemsChanged()
        scheduleSave()
        publish()
        updateKeyboardFocus()
    }

    /// "Clear Shelf…" in the island menu: text clips, links, received files and copies exist only on the
    /// Shelf, so it asks first (the page's Clear All asks with its second click).
    func confirmClearAll() {
        guard !items.isEmpty else { return }
        let previous = NSWorkspace.shared.frontmostApplication
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Clear the Shelf?"
        alert.informativeText = "\(ShelfNaming.itemsLabel(items.count)) will be removed. Stored copies, text clips and links are deleted; originals stay where they are."
        alert.addButton(withTitle: "Clear Shelf")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        log("clear \(confirmed ? "confirmed" : "cancelled")")
        if confirmed { clearAll() }
        if let previous, previous != .current { previous.activate() }
    }

    func clearAll() {
        clearConfirmation.reset()
        clearArmed = false
        remove(Set(items.map(\.id)))
    }

    func removeMissing() {
        remove(Set(items.filter { $0.state.isGone }.map(\.id)))
    }

    /// "Clear All" in the page: the first click asks, a second within 3 s clears.
    func tapClearAll() {
        if clearConfirmation.tap(now: ProcessInfo.processInfo.systemUptime) {
            clearAll()
            return
        }
        clearArmed = true
        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShelfClearConfirmation.window))
            guard !Task.isCancelled, let self else { return }
            self.clearConfirmation.reset()
            self.clearArmed = false
        }
    }

    // MARK: References

    /// Resolves references in the background (protected folders only when asked, before an action)
    /// and checks that stored files still exist.
    func validate(includeProtected: Bool, only ids: Set<String>? = nil) {
        var requests: [ShelfFileWork.ResolveRequest] = []
        var stored: [(String, URL)] = []
        for item in items where item.state != .pending && (ids?.contains(item.id) ?? true) {
            switch item.storage {
            case .reference(let bookmark, let path):
                if item.isProtected && !includeProtected { continue }
                requests.append(.init(id: item.id, bookmark: bookmark, path: path))
            case .stored(let relative, _):
                stored.append((item.id, paths.url(relative: relative)))
            }
        }
        guard !requests.isEmpty || !stored.isEmpty else { return }
        validations += 1
        Task {
            let results = await ShelfFileWork.resolve(requests)
            var existing: [String: Bool] = [:]
            for (id, url) in stored { existing[id] = await ShelfFileWork.exists(url) }
            self.apply(results, stored: existing)
        }
    }

    private func apply(_ results: [ShelfResolveResult], stored: [String: Bool]) {
        var changed = false
        for result in results {
            guard let index = items.firstIndex(where: { $0.id == result.id }),
                  case .reference(let bookmark, let path) = items[index].storage else { continue }
            if update(index: index, with: result, bookmark: bookmark, path: path) { changed = true }
        }
        for (id, exists) in stored {
            guard let index = items.firstIndex(where: { $0.id == id }), items[index].state != .pending,
                  items[index].state != .failed else { continue }
            let state: ShelfItemState = exists ? .available : .missing
            if items[index].state != state {
                items[index].state = state
                changed = true
            }
        }
        if changed {
            scheduleSave()
            quickLook.itemsChanged()
        }
    }

    /// Applies one resolution; returns whether the item changed.
    private func update(index: Int, with result: ShelfResolveResult, bookmark: Data, path: String) -> Bool {
        let before = items[index]
        var item = before
        item.state = ShelfValidation.state(for: result.resolution, lastPath: path, locations: locations,
                                           volumeMounted: { FileManager.default.fileExists(atPath: $0) })
        if case .resolved(let newPath) = result.resolution {
            item.storage = .reference(bookmark: result.bookmark ?? bookmark, path: newPath)
            if let name = result.name { item.name = name }
            item.fingerprint = ShelfOrdering.fingerprint(referencePath: newPath)
            item.isProtected = locations.isProtected(newPath)
            if item.state == .available, let modified = result.modified, modified != before.modified {
                item.modified = modified
                makeThumbnail(id: item.id, from: URL(fileURLWithPath: newPath))
            }
        }
        guard item != before else { return false }
        items[index] = item
        return true
    }

    /// The item's file, resolved now (actions). Updates the item's state; nil when it can't be used.
    func fileURL(for id: String) -> URL? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items[index]
        switch item.storage {
        case .stored(let relative, _):
            let url = paths.url(relative: relative)
            guard item.state != .pending, item.state != .failed else { return nil }
            let exists = FileManager.default.fileExists(atPath: url.path)
            if !exists, item.state != .missing { items[index].state = .missing; scheduleSave() }
            if exists, item.state == .missing { items[index].state = .available; scheduleSave() }
            return exists ? url : nil
        case .reference(let bookmark, let path):
            var stale = false
            var resolution: ShelfResolution = .notFound
            var resolvedURL: URL?
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                do {
                    if try url.checkResourceIsReachable() {
                        resolution = .resolved(path: url.standardizedFileURL.path)
                        resolvedURL = url
                    }
                } catch {
                    if ShelfFileError(error).isPermission { resolution = .noPermission }
                }
            } else if FileManager.default.fileExists(atPath: path) {
                resolution = .resolved(path: path)
                resolvedURL = URL(fileURLWithPath: path)
            }
            var result = ShelfResolveResult(id: id, resolution: resolution)
            if let resolvedURL {
                let values = try? resolvedURL.resourceValues(forKeys: [.nameKey, .contentModificationDateKey])
                result.name = values?.name
                result.modified = values?.contentModificationDate
                if stale || resolvedURL.standardizedFileURL.path != path { result.bookmark = try? resolvedURL.bookmarkData() }
            }
            if update(index: index, with: result, bookmark: bookmark, path: path) { scheduleSave() }
            return items[index].state.isUsable ? resolvedURL : nil
        }
    }

    /// The Shelf page appeared: references outside protected folders are checked again.
    func pageAppeared() {
        validate(includeProtected: false)
    }

    // MARK: Actions

    func open(_ id: String) {
        guard let item = item(id) else { return }
        giveBackKeyboard() // the opened app gets the keyboard
        if item.kind == .link, let link = item.link, let url = URL(string: link.url) {
            perform("open \(link.url)") { NSWorkspace.shared.open(url) }
            return
        }
        guard let url = fileURL(for: id) else {
            log("open refused (\(self.item(id)?.state.rawValue ?? "gone"))")
            return
        }
        perform("open \(url.path)") { NSWorkspace.shared.open(url) }
    }

    func reveal(_ id: String) {
        guard item(id)?.kind.isFileBased == true, let url = fileURL(for: id) else { return }
        giveBackKeyboard()
        perform("reveal \(url.path)") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    func copyToPasteboard(_ id: String) {
        guard let item = item(id), let writer = pasteboardWriter(for: item) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var writers: [NSPasteboardWriting] = [writer]
        if item.kind == .image, let url = fileURL(for: id), let image = NSImage(contentsOf: url) { writers = [url as NSURL, image] }
        pasteboard.writeObjects(writers)
        log("copy \(item.kind.rawValue)")
    }

    /// What dragging, copying and sharing hand to other apps.
    func pasteboardWriter(for item: ShelfItem) -> NSPasteboardWriting? {
        switch item.kind {
        case .link:
            guard let link = item.link else { return nil }
            let writer = NSPasteboardItem()
            writer.setString(link.url, forType: .URL)
            writer.setString(link.url, forType: .string)
            writer.setString(item.name, forType: NSPasteboard.PasteboardType(ShelfTypes.urlName))
            return writer
        case .text:
            guard let text = fullText(of: item) else { return nil }
            return text as NSString
        case .file, .folder, .image:
            return fileURL(for: item.id).map { $0 as NSURL }
        }
    }

    /// Drag image: the thumbnail, else the file type's icon or a glyph.
    func dragImage(for item: ShelfItem) -> NSImage {
        if let thumbnail = thumbnails[item.id] { return thumbnail }
        switch item.kind {
        case .link: return NSImage(systemSymbolName: "link", accessibilityDescription: item.name) ?? NSImage()
        case .text: return NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: item.name) ?? NSImage()
        case .file, .folder, .image:
            let type = item.kind == .folder ? UTType.folder : (item.typeIdentifier.flatMap(UTType.init) ?? .data)
            return NSWorkspace.shared.icon(for: type)
        }
    }

    func fullText(of item: ShelfItem) -> String? {
        guard item.kind == .text, case .stored(let relative, _) = item.storage else { return nil }
        return (try? String(contentsOf: paths.url(relative: relative), encoding: .utf8)) ?? item.textPreview
    }

    /// What Share offers for an item: the file, the text or the URL.
    func shareItems(for id: String) -> [Any] {
        guard let item = item(id), item.state.isUsable else { return [] }
        switch item.kind {
        case .link: return item.link.flatMap { URL(string: $0.url) }.map { [$0] } ?? []
        case .text: return fullText(of: item).map { [$0] } ?? []
        case .file, .folder, .image: return fileURL(for: id).map { [$0] } ?? []
        }
    }

    /// Shows the system share picker (AirDrop, Mail, Messages, …) next to the item's tile; choosing a
    /// service opens that service's own sheet. Lintel sends nothing itself.
    func showSharePicker(for id: String, island: IslandController? = nil) {
        let things = shareItems(for: id)
        guard !things.isEmpty, let island = island ?? focusedIsland ?? coordinator?.controllers.values.first,
              let view = ShelfDropCatcher.view(for: island) else { return }
        // Tile frames are top-left in the island's (flipped) SwiftUI view.
        let topLeft = tileFrames[id] ?? CGRect(x: view.bounds.midX - 20, y: 40, width: 40, height: 20)
        let frame = view.isFlipped ? topLeft
            : CGRect(x: topLeft.minX, y: view.bounds.height - topLeft.maxY, width: topLeft.width, height: topLeft.height)
        share.onLog = { [weak self] line in self?.log(line) }
        share.show(things, relativeTo: frame, of: view)
        log("share picker shown")
    }

    /// Location of the file Quick Look shows for an item (text clips and links: their stored file).
    func previewURL(for id: String) -> URL? {
        guard let item = item(id) else { return nil }
        switch item.kind {
        case .link, .text:
            guard case .stored(let relative, _) = item.storage else { return nil }
            let url = paths.url(relative: relative)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        case .file, .folder, .image:
            return fileURL(for: id)
        }
    }

    func toggleQuickLook(_ id: String? = nil) {
        if quickLook.isOpen {
            quickLook.close()
            return
        }
        let ids = items.filter { $0.state.isUsable }.map(\.id)
        guard let start = id ?? hoveredID ?? ids.first, ids.contains(start) else { return }
        // The key panel holds the keyboard while the preview shows (Space, arrows, Escape).
        let island = focusedIsland
        if !keyboard.isHeld { setKeyboard(true, near: island) }
        quickLook.show(ids: ids, start: start, on: (island ?? coordinator?.controllers.values.first).flatMap { ShelfDropCatcher.screen(for: $0) })
        log("quicklook \(item(start)?.kind.rawValue ?? "")")
        updateKeyboardFocus()
    }

    private func perform(_ description: String, _ action: () -> Void) {
        log(description)
        action()
    }

    func log(_ line: String) {
        actionLog.append(String(format: "%.3f ", ProcessInfo.processInfo.systemUptime) + line)
        if actionLog.count > 40 { actionLog.removeFirst(actionLog.count - 40) }
    }

    // MARK: Pages and hover

    func showPage(_ newPage: Int) {
        page = ShelfPaging.clamped(newPage, count: items.count)
    }

    func hover(_ id: String, inside: Bool) {
        if inside {
            hoveredID = id
        } else if hoveredID == id {
            hoveredID = nil
        }
        updateKeyboardFocus()
    }

    func setHover(_ id: String?) {
        hoveredID = id
        if let id, let index = items.firstIndex(where: { $0.id == id }) { page = ShelfPaging.page(of: index) }
    }

    // MARK: Keyboard

    /// The island open on the Shelf page with the pointer inside, if any.
    var focusedIsland: IslandController? {
        coordinator?.controllers.values.first {
            $0.model.phase == .expanded && $0.model.expandedContent == .shelf && $0.pointerInside
        }
    }

    /// Follows each island's phase and page, so the keyboard focus also changes when the island opens
    /// or closes without the pointer moving (hover delay, swipes, alerts).
    private func trackIslands() {
        for island in coordinator?.controllers.values ?? [:].values {
            let model = island.model
            let key = ObjectIdentifier(model)
            guard !trackedModels.contains(key) else { continue }
            trackedModels.insert(key)
            withObservationTracking {
                _ = model.phase
                _ = model.expandedContent
            } onChange: { [weak self] in
                // @Sendable: Observation calls this from whatever changed the model; hop to the main actor.
                Task { @MainActor [weak self] in
                    self?.trackedModels.remove(key)
                    self?.updateKeyboardFocus()
                }
            }
        }
    }

    func updateKeyboardFocus() {
        trackIslands()
        let island = focusedIsland
        if island == nil { gaveBackKeyboard = false }
        let wants = isEnabled && ShelfKeyboard.wantsFocus(pageOpen: island != nil, itemCount: items.count, pointerInside: island != nil,
                                                          quickLookOpen: quickLook.isOpen, gaveBack: gaveBackKeyboard)
        if wants != keyboard.isHeld { setKeyboard(wants, near: island) }
        if wants, focusTask == nil {
            // While the Shelf holds the keyboard, re-check it 10 times a second (the island can close
            // without the pointer moving: a swipe, Escape, an alert).
            focusTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, !Task.isCancelled else { return }
                    self.updateKeyboardFocus()
                    if !self.keyboard.isHeld { break }
                }
                self?.focusTask = nil
            }
        }
    }

    private func setKeyboard(_ held: Bool, near island: IslandController?) {
        keyboard.set(held, screen: (island ?? coordinator?.controllers.values.first).flatMap { ShelfDropCatcher.screen(for: $0) })
    }

    /// Hands the keyboard back to the frontmost app until the pointer leaves the island (Quick Look
    /// keeps it while open).
    func giveBackKeyboard() {
        guard keyboard.isHeld || focusedIsland != nil else { return }
        gaveBackKeyboard = true
        updateKeyboardFocus()
    }

    func handleKey(_ key: ShelfKey) {
        let visible = items.filter { $0.state.isUsable || $0.state == .pending }.map(\.id)
        switch ShelfKeyboard.action(for: key, quickLookOpen: quickLook.isOpen) {
        case .toggleQuickLook:
            toggleQuickLook()
        case .previous, .next:
            let delta = key == .left ? -1 : 1
            if quickLook.isOpen {
                quickLook.move(by: delta)
            } else if let next = ShelfKeyboard.move(from: hoveredID, by: delta, in: items.map(\.id)) {
                setHover(next)
            }
        case .open:
            if let id = hoveredID ?? visible.first { open(id) }
        case .copy:
            if let id = hoveredID ?? visible.first { copyToPasteboard(id) }
        case .closeQuickLook:
            quickLook.close()
        case .closeIsland:
            focusedIsland?.performClose()
        case .giveBackKeyboard:
            gaveBackKeyboard = true
        }
        log("key \(key)")
        updateKeyboardFocus()
    }

    // MARK: Settings helpers

    func refreshStoredSize() {
        let root = paths.root
        Task {
            let size = await ShelfFileWork.folderSize(root)
            self.storedBytes = size
        }
    }

    func revealStorageFolder() {
        try? FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        perform("reveal \(paths.root.path)") { NSWorkspace.shared.activateFileViewerSelecting([paths.root]) }
    }
}

/// Work that finishes an item after it was added.
enum ShelfFollowup {
    case thumbnail(URL)
    case copy(URL, name: String)
    case data(Data, name: String)
    case text(String, name: String)
    case link(String, name: String)
    case promise(NSFilePromiseReceiver)
}
