import CoreGraphics
import Foundation
import LintelCore

/// Checks for the Shelf: models and the index, ordering and
/// duplicates, paging, naming, import planning, locations and deletion safety, resolution states,
/// keyboard rules, Clear All, settings keys and the activity-engine contract.
@MainActor
func runShelfChecks() {
    checkShelfIndex()
    checkShelfOrdering()
    checkShelfPaging()
    checkShelfNaming()
    checkShelfPlanner()
    checkShelfLocations()
    checkShelfValidation()
    checkShelfKeyboard()
    checkShelfSettings()
    checkShelfEngineContract()
}

// MARK: - Fixtures

private let day = Date(timeIntervalSince1970: 1_795_000_000)

private func shelfItem(_ id: String, kind: ShelfItemKind = .file, path: String? = nil, fingerprint: String? = nil,
                       state: ShelfItemState = .available) -> ShelfItem {
    let storage: ShelfItemStorage = path.map { .reference(bookmark: Data([1, 2, 3]), path: $0) }
        ?? .stored(relativePath: "Items/\(id)/\(id).txt", originalPath: nil)
    return ShelfItem(id: id, kind: kind, name: id, added: day, storage: storage, state: state,
                     fingerprint: fingerprint ?? path.map(ShelfOrdering.fingerprint(referencePath:)))
}

// MARK: - Index

@MainActor
private func checkShelfIndex() {
    let items = [
        ShelfItem(id: "a", kind: .file, name: "Report.pdf", typeIdentifier: "com.adobe.pdf", byteSize: 1234, added: day,
                  storage: .reference(bookmark: Data([0xDE, 0xAD]), path: "/Users/u/Work/Report.pdf"),
                  fingerprint: ShelfOrdering.fingerprint(referencePath: "/Users/u/Work/Report.pdf"), hasThumbnail: true,
                  isProtected: false, modified: day),
        ShelfItem(id: "b", kind: .folder, name: "Photos", added: day,
                  storage: .stored(relativePath: "Items/b/Photos", originalPath: "/Users/u/Photos"), state: .pending),
        ShelfItem(id: "c", kind: .link, name: "Example", added: day, storage: .stored(relativePath: "Items/c/Example.webloc", originalPath: nil),
                  link: ShelfLink(url: "https://example.com/a", title: "Example"), fingerprint: ShelfOrdering.fingerprint(link: "https://example.com/a")),
        ShelfItem(id: "d", kind: .text, name: "Hello", added: day, storage: .stored(relativePath: "Items/d/Hello.txt", originalPath: nil),
                  textPreview: "Hello there", fingerprint: ShelfOrdering.fingerprint(text: "Hello there"), sourceURL: nil),
    ]
    let index = ShelfIndex(drops: 7, items: items)
    let data = try? ShelfIndex.encoder().encode(index)
    check(data != nil, "index encodes")
    if let data {
        check(ShelfIndex.load(data) == .loaded(index), "index round-trips through JSON (all storage kinds, dates, bookmarks)")
        let text = String(decoding: data, as: UTF8.self)
        check(text.contains("\"version\" : 1") && text.contains("2026-"), "index is versioned JSON with ISO-8601 dates")
        // Unknown fields from a later minor change are ignored.
        if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            object["futureField"] = ["x": 1]
            if let extended = try? JSONSerialization.data(withJSONObject: object) {
                check(ShelfIndex.load(extended) == .loaded(index), "unknown top-level fields are ignored")
            }
        }
    }
    check(ShelfIndex.load(Data("{\"version\": 9, \"items\": [{\"kind\": \"hologram\"}]}".utf8)) == .newer(version: 9),
          "an index from a newer Lintel is recognised (not decoded, never overwritten)")
    check(ShelfIndex.load(Data("not json".utf8)) == .corrupt, "garbage is corrupt")
    check(ShelfIndex.load(Data("{\"version\": 1, \"items\": 3}".utf8)) == .corrupt, "a malformed index is corrupt")
    check(ShelfIndex().items.isEmpty && ShelfIndex().version == ShelfIndex.currentVersion, "empty index defaults")

    check(ShelfItemState.available.isUsable && !ShelfItemState.pending.isUsable && !ShelfItemState.missing.isUsable,
          "only available items can be used")
    check(Set(ShelfItemState.allCases.filter(\.isGone)) == [.missing, .inTrash, .failed],
          "Remove Missing Items takes missing, trashed and failed items (not unmounted or no-access ones)")
    check(ShelfItemState.available.label() == nil && ShelfItemState.unavailable.label(volume: "Backup") == "Backup isn't connected",
          "state labels")
    check(ShelfItemKind.image.isFileBased && ShelfItemKind.folder.isFileBased && !ShelfItemKind.link.isFileBased,
          "file-based kinds")
    check(items[0].originalPath == "/Users/u/Work/Report.pdf" && items[1].originalPath == "/Users/u/Photos" && items[2].originalPath == nil,
          "original paths of references and copies")
    let onVolume = shelfItem("v", path: "/Volumes/Backup/Film.mov")
    check(onVolume.volumeName == "Backup" && items[0].volumeName == nil, "volume name of items on other volumes")
}

// MARK: - Ordering and duplicates

@MainActor
private func checkShelfOrdering() {
    let later = day.addingTimeInterval(60)
    let existing = [shelfItem("old1", path: "/a/1"), shelfItem("old2", path: "/a/2")]
    var result = ShelfOrdering.inserting([shelfItem("n1", path: "/b/1"), shelfItem("n2", path: "/b/2")], into: existing, now: later)
    check(result.items.map(\.id) == ["n1", "n2", "old1", "old2"], "a drop goes in front, keeping its own order (newest first)")
    check(result.front == ["n1", "n2"] && result.items[0].added == later, "new items get the drop's date")

    result = ShelfOrdering.inserting([shelfItem("dup", path: "/a/2")], into: existing, now: later)
    check(result.items.map(\.id) == ["old2", "old1"], "a reference to a file already on the Shelf moves that item to the front")
    check(result.front == ["old2"] && result.items[0].added == later, "the moved item keeps its id and gets a fresh date")

    result = ShelfOrdering.inserting([shelfItem("x1", path: "/c/1"), shelfItem("x2", path: "/c/1")], into: [], now: later)
    check(result.items.map(\.id) == ["x1"], "the same file twice in one drop is kept once")

    let missing = [shelfItem("gone", path: "/a/9", state: .missing)]
    result = ShelfOrdering.inserting([shelfItem("again", path: "/a/9")], into: missing, now: later)
    check(result.items.map(\.id) == ["again", "gone"], "a missing item isn't a duplicate: dropping the file again adds it")

    let copies = [ShelfItem(id: "c1", kind: .file, name: "f", added: day, storage: .stored(relativePath: "Items/c1/f", originalPath: "/a/f"))]
    let copy2 = ShelfItem(id: "c2", kind: .file, name: "f", added: day, storage: .stored(relativePath: "Items/c2/f", originalPath: "/a/f"))
    result = ShelfOrdering.inserting([copy2], into: copies, now: later)
    check(result.items.map(\.id) == ["c2", "c1"], "copies are snapshots: the same original copied again is a new item")

    let link = shelfItem("l1", kind: .link, fingerprint: ShelfOrdering.fingerprint(link: "https://example.com"))
    let sameLink = shelfItem("l2", kind: .link, fingerprint: ShelfOrdering.fingerprint(link: " https://example.com\n"))
    result = ShelfOrdering.inserting([sameLink], into: [shelfItem("z", path: "/z"), link], now: later)
    check(result.items.map(\.id) == ["l1", "z"], "identical links are kept once")
    let text = shelfItem("t1", kind: .text, fingerprint: ShelfOrdering.fingerprint(text: "Hello"))
    result = ShelfOrdering.inserting([shelfItem("t2", kind: .text, fingerprint: ShelfOrdering.fingerprint(text: "Hello"))], into: [text], now: later)
    check(result.items.map(\.id) == ["t1"], "identical text clips are kept once")
    check(ShelfOrdering.fingerprint(text: "Hello") != ShelfOrdering.fingerprint(text: "hello"), "text fingerprints are case-sensitive")
    check(ShelfOrdering.fingerprint(referencePath: "/a/b/../c") == "path:/a/c", "reference fingerprints use standardised paths")
    let picture = shelfItem("p1", kind: .image, fingerprint: ShelfOrdering.fingerprint(source: "https://example.com/a.png"))
    result = ShelfOrdering.inserting([shelfItem("p2", kind: .image, fingerprint: ShelfOrdering.fingerprint(source: "https://example.com/a.png "))],
                                     into: [picture], now: later)
    check(result.items.map(\.id) == ["p1"], "the same browser picture dragged again is kept once (by its source address)")

    check(ShelfHash.fnv1a64("") == "cbf29ce484222325" && ShelfHash.fnv1a64("a") == "af63dc4c8601ec8c", "FNV-1a 64 reference values")
}

// MARK: - Paging

@MainActor
private func checkShelfPaging() {
    check(ShelfPaging(count: 0, page: 0).pageCount == 1 && ShelfPaging(count: 0, page: 0).range.isEmpty, "empty Shelf: one empty page")
    check(ShelfPaging(count: 5, page: 0).pageCount == 1 && ShelfPaging(count: 5, page: 0).range == 0..<5, "five items fit one page")
    check(ShelfPaging(count: 6, page: 0).pageCount == 2 && ShelfPaging(count: 6, page: 1).range == 5..<6, "the sixth item starts page 2")
    check(ShelfPaging(count: 12, page: 1).range == 5..<10 && ShelfPaging(count: 12, page: 2).range == 10..<12, "pages of 5")
    check(ShelfPaging(count: 12, page: 9).page == 2 && ShelfPaging(count: 12, page: -3).page == 0, "pages are clamped")
    check(ShelfPaging.clamped(2, count: 10) == 1, "removing items moves back to the last page")
    let middle = ShelfPaging(count: 12, page: 1)
    check(middle.hasPrevious && middle.hasNext && !ShelfPaging(count: 12, page: 0).hasPrevious && !ShelfPaging(count: 12, page: 2).hasNext,
          "chevrons enabled only where there is a page")
    check(ShelfPaging.page(of: 0) == 0 && ShelfPaging.page(of: 4) == 0 && ShelfPaging.page(of: 5) == 1 && ShelfPaging.page(of: 11) == 2,
          "page of an item")
}

// MARK: - Naming

@MainActor
private func checkShelfNaming() {
    check(ShelfNaming.textTitle("\n\n   Shopping   list:\n- milk") == "Shopping list:", "text title: first non-empty line, spaces collapsed")
    check(ShelfNaming.textTitle(String(repeating: "a", count: 60)) == String(repeating: "a", count: 39) + "…", "text title ≤ 40 characters")
    check(ShelfNaming.textTitle(" \n\t ") == "Text", "blank text has a fallback title")
    check(ShelfNaming.textPreview(String(repeating: "x", count: 500)).count == 280 && ShelfNaming.textPreview("short") == "short",
          "text preview keeps 280 characters")
    check(ShelfNaming.linkTitle(url: "https://www.example.com/docs/a", title: "  Example   Docs ") == "Example Docs", "link title from its title")
    check(ShelfNaming.linkTitle(url: "https://www.example.com/docs/a", title: nil) == "example.com/docs/a", "link title from host and path")
    check(ShelfNaming.linkTitle(url: "https://example.com/", title: "") == "example.com", "root path dropped")
    check(ShelfNaming.host(of: "https://www.lintel.app/x") == "lintel.app" && ShelfNaming.host(of: "nonsense") == nil, "host without www")
    check(ShelfNaming.imageFileName(sourceURL: "https://cdn.example.com/img/Sunset%20Sky.jpg?w=200", fileExtension: "png", date: day)
          == "Sunset Sky.jpg", "image data named after the source URL's image file")
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = TimeZone(identifier: "UTC")!
    check(ShelfNaming.imageFileName(sourceURL: "https://example.com/page", fileExtension: "png", date: day, calendar: utc)
          == "Image 2026-11-18 at 11.06.40.png", "image data without a file name gets a dated name (got \(ShelfNaming.imageFileName(sourceURL: "https://example.com/page", fileExtension: "png", date: day, calendar: utc)))")
    check(ShelfNaming.safeFileName("a/b:c") == "a-b-c", "slashes and colons replaced")
    check(ShelfNaming.safeFileName("..hidden") == "hidden" && ShelfNaming.safeFileName("..") == "Item" && ShelfNaming.safeFileName("") == "Item",
          "no leading dots, never empty")
    check(ShelfNaming.safeFileName("line\nbreak\u{0}") == "line break", "control characters removed")
    let long = ShelfNaming.safeFileName(String(repeating: "é", count: 150) + ".pdf")
    check(long.utf8.count <= 200 && long.hasSuffix(".pdf"), "names are cut to 200 bytes, keeping the extension")
    check(ShelfNaming.countLabel(7) == "7" && ShelfNaming.countLabel(100) == "99+", "indicator count, 99+ above 99")
    check(ShelfNaming.itemsLabel(1) == "1 item" && ShelfNaming.itemsLabel(3) == "3 items", "item counts")
    check(ShelfNaming.truncated("abcdef", limit: 4) == "abc…" && ShelfNaming.truncated("abc", limit: 4) == "abc", "truncation")
}

// MARK: - Import planning

@MainActor
private func checkShelfPlanner() {
    let file = ShelfDraggedItem(types: ["public.file-url", "public.url", "public.utf8-plain-text"], filePath: "/a/b.pdf",
                                url: "file:///a/b.pdf", text: "/a/b.pdf")
    check(ShelfImportPlanner.plan(for: file) == .file(path: "/a/b.pdf"), "a file URL wins")
    let browserImage = ShelfDraggedItem(types: ["public.tiff", "public.url", "com.apple.NSFilePromiseItemMetaData"],
                                        url: "https://example.com/a.jpg", promise: true)
    check(ShelfImportPlanner.plan(for: browserImage) == .promise, "a browser image with a promise is received as a file")
    var noReceiver = browserImage
    noReceiver.promise = false
    check(ShelfImportPlanner.plan(for: noReceiver) == .imageData(type: "public.tiff", fileExtension: "png"),
          "without a promise receiver the image data counts (TIFF stored as PNG)")
    // Regression (crash 2026-11-22 17:19): promises are received only from the drag pasteboard during
    // a drop; a pasteboard that only promises a file (no receiver) is skipped, never received.
    let promiseOnly = ShelfDraggedItem(types: ["com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-url"], promise: false)
    check(ShelfImportPlanner.plan(for: promiseOnly) == .skip, "a promise without its receiver is skipped (never received outside a drop)")
    let pngAndTiff = ShelfDraggedItem(types: ["public.tiff", "public.png"])
    check(ShelfImportPlanner.plan(for: pngAndTiff) == .imageData(type: "public.png", fileExtension: "png"), "PNG preferred over TIFF")
    let link = ShelfDraggedItem(types: ["public.url", "public.url-name", "public.utf8-plain-text"], url: "https://example.com/x",
                                urlTitle: "Example", text: "https://example.com/x")
    check(ShelfImportPlanner.plan(for: link) == .link(url: "https://example.com/x", title: "Example"), "a link keeps its title")
    let script = ShelfDraggedItem(types: ["public.url", "public.utf8-plain-text"], url: "javascript:alert(1)", text: "javascript:alert(1)")
    check(ShelfImportPlanner.plan(for: script) == .text("javascript:alert(1)"), "script URLs never become links")
    let urlText = ShelfDraggedItem(types: ["public.utf8-plain-text"], text: "  https://lintel.example/page?a=1 \n")
    check(ShelfImportPlanner.plan(for: urlText) == .link(url: "https://lintel.example/page?a=1", title: nil), "a text that is one link becomes a link")
    let prose = ShelfDraggedItem(types: ["public.utf8-plain-text"], text: "see https://example.com for more")
    check(ShelfImportPlanner.plan(for: prose) == .text("see https://example.com for more"), "text with a link inside stays text")
    check(ShelfImportPlanner.plan(for: ShelfDraggedItem(types: ["public.utf8-plain-text"], text: " \n ")) == .skip, "blank text is skipped")
    check(ShelfImportPlanner.plan(for: ShelfDraggedItem(types: ["com.apple.color"])) == .skip, "a colour is skipped")

    check(ShelfImportPlanner.accepts(types: ["public.file-url"]) && ShelfImportPlanner.accepts(types: ["public.url"])
          && ShelfImportPlanner.accepts(types: ["public.utf8-plain-text"]) && ShelfImportPlanner.accepts(types: ["public.tiff"])
          && ShelfImportPlanner.accepts(types: ["com.apple.NSFilePromiseItemMetaData"]), "accepted drags: files, links, text, images, promises")
    check(!ShelfImportPlanner.accepts(types: ["com.apple.color", "dyn.xyz"]), "a colour drag gets no drop zone")
    check(!ShelfImportPlanner.accepts(types: ["public.file-url", ShelfTypes.ownDrag]), "the Shelf's own drags aren't taken back")

    check(ShelfImportPlanner.isAcceptableLink("https://example.com") && ShelfImportPlanner.isAcceptableLink("mailto:a@example.com")
          && ShelfImportPlanner.isAcceptableLink("ftp://files.example.com/x"), "web, mail and ftp links")
    check(!ShelfImportPlanner.isAcceptableLink("javascript:void(0)") && !ShelfImportPlanner.isAcceptableLink("data:text/html,hi")
          && !ShelfImportPlanner.isAcceptableLink("file:///etc/hosts") && !ShelfImportPlanner.isAcceptableLink("about:blank")
          && !ShelfImportPlanner.isAcceptableLink("blob:https://x/1"), "script, data, file, about and blob URLs refused")
    check(!ShelfImportPlanner.isAcceptableLink("localhost:8080") && !ShelfImportPlanner.isAcceptableLink("two words")
          && !ShelfImportPlanner.isAcceptableLink("https://e.com/" + String(repeating: "a", count: 9000)), "not links: no scheme, spaces, over 8 KB")
    check(ShelfImportPlanner.link(fromText: "http://example.com") == "http://example.com" && ShelfImportPlanner.link(fromText: "ftp://x.com") == nil,
          "only http(s) text becomes a link")
}

// MARK: - Locations and deletion safety

@MainActor
private func checkShelfLocations() {
    let places = ShelfLocations(home: "/Users/u", temporaryRoots: ["/private/var/folders", "/tmp", "/Users/u/Library/Caches/T"])
    check(places.isProtected("/Users/u/Downloads/a.zip") && places.isProtected("/Users/u/Documents") && places.isProtected("/Users/u/Desktop/x/y"),
          "Desktop, Documents and Downloads are protected")
    check(places.isProtected("/Users/u/Library/Mobile Documents/com~apple~CloudDocs/a") && places.isProtected("/Users/u/Library/CloudStorage/Box/a")
          && places.isProtected("/Volumes/USB/a.mov"), "iCloud Drive, cloud storage and other volumes are protected")
    check(!places.isProtected("/Users/u/Pictures/a.png") && !places.isProtected("/Users/u/Downloads2/a") && !places.isProtected("/tmp/x"),
          "other folders aren't (prefixes compare whole components)")
    check(places.isTemporary("/private/var/folders/ab/T/x.png") && places.isTemporary("/tmp/drag.jpg")
          && places.isTemporary("/Users/u/Library/Caches/T/a") && !places.isTemporary("/Users/u/tmp/a"), "temporary folders")
    check(places.isInTrash("/Users/u/.Trash/a.pdf") && places.isInTrash("/Volumes/USB/.Trashes/501/a.pdf")
          && !places.isInTrash("/Users/u/Trash/a.pdf") && !places.isInTrash("/Users/u/.Trashy/a"), "Trash folders")
    check(ShelfLocations.volumeRoot(of: "/Volumes/My Disk/a/b") == "/Volumes/My Disk" && ShelfLocations.volumeRoot(of: "/Users/u/a") == nil
          && ShelfLocations.volumeRoot(of: "/Volumes") == nil, "volume roots")
    check(ShelfLocations.isInside("/a/b", folder: "/a/b") && ShelfLocations.isInside("/a/b/c", folder: "/a/b/")
          && !ShelfLocations.isInside("/a/bc", folder: "/a/b"), "inside compares path components")
    check(ShelfLocations.normalized("/private/tmp//x/./y/../z/") == "/tmp/x/z" && ShelfLocations.normalized("/private/var/folders/a") == "/var/folders/a"
          && ShelfLocations.normalized("/privateer/tmp") == "/privateer/tmp" && ShelfLocations.normalized("/../..") == "/",
          "paths are normalised lexically (/private/tmp is /tmp), without asking the file system")
    check(places.isTemporary("/private/tmp/work/scratch/a.txt") && ShelfLocations.isInside("/private/var/folders/x", folder: "/var/folders"),
          "/private and its short forms are the same folders")

    let root = "/Users/u/Library/Application Support/Lintel/Shelf"
    check(ShelfStoragePolicy.canDelete(root + "/Items/1", storageRoot: root) && ShelfStoragePolicy.canDelete(root + "/Thumbnails/1.png", storageRoot: root),
          "Lintel deletes inside its Shelf folder")
    check(!ShelfStoragePolicy.canDelete(root, storageRoot: root) && !ShelfStoragePolicy.canDelete("/Users/u/Documents/a", storageRoot: root)
          && !ShelfStoragePolicy.canDelete(root + "2/Items/1", storageRoot: root) && !ShelfStoragePolicy.canDelete("/", storageRoot: "/")
          && !ShelfStoragePolicy.canDelete(root + "/Items/../../../../Documents", storageRoot: root),
          "never the folder itself, anything outside it, a sibling with the same prefix, or a path climbing out")
    check(ShelfStoragePolicy.itemFolder(id: "ABC-1") == "Items/ABC-1" && ShelfStoragePolicy.itemFolder(id: "../x") == "Items/-x",
          "item folders are one safe path component")
}

// MARK: - Resolving references

@MainActor
private func checkShelfValidation() {
    let places = ShelfLocations(home: "/Users/u")
    func state(_ resolution: ShelfResolution, last: String = "/Users/u/Work/a.pdf", mounted: Bool = true) -> ShelfItemState {
        ShelfValidation.state(for: resolution, lastPath: last, locations: places, volumeMounted: { _ in mounted })
    }
    check(state(.resolved(path: "/Users/u/Work/a.pdf")) == .available, "found where it was")
    check(state(.resolved(path: "/Users/u/Archive/renamed.pdf")) == .available, "moved or renamed: still available")
    check(state(.resolved(path: "/Users/u/.Trash/a.pdf")) == .inTrash, "in the Trash")
    check(state(.notFound) == .missing, "deleted")
    check(state(.notFound, last: "/Volumes/Backup/a.pdf", mounted: false) == .unavailable, "on a volume that isn't connected")
    check(state(.notFound, last: "/Volumes/Backup/a.pdf", mounted: true) == .missing, "gone from a connected volume")
    check(state(.noPermission) == .noAccess, "reading refused")
}

// MARK: - Keyboard and Clear All

@MainActor
private func checkShelfKeyboard() {
    check(ShelfKey.from(keyCode: 49, characters: " ", command: false) == .space && ShelfKey.from(keyCode: 123, characters: nil, command: false) == .left
          && ShelfKey.from(keyCode: 124, characters: nil, command: false) == .right && ShelfKey.from(keyCode: 36, characters: "\r", command: false) == .enter
          && ShelfKey.from(keyCode: 76, characters: nil, command: false) == .enter && ShelfKey.from(keyCode: 53, characters: nil, command: false) == .escape,
          "Space, arrows, Return/Enter, Escape")
    check(ShelfKey.from(keyCode: 8, characters: "c", command: true) == .copy && ShelfKey.from(keyCode: 12, characters: "q", command: true) == .other
          && ShelfKey.from(keyCode: 0, characters: "a", command: false) == .other, "⌘C copies; ⌘Q and letters are 'other'")
    check(ShelfKeyboard.action(for: .space, quickLookOpen: false) == .toggleQuickLook
          && ShelfKeyboard.action(for: .escape, quickLookOpen: true) == .closeQuickLook
          && ShelfKeyboard.action(for: .escape, quickLookOpen: false) == .closeIsland
          && ShelfKeyboard.action(for: .other, quickLookOpen: false) == .giveBackKeyboard
          && ShelfKeyboard.action(for: .enter, quickLookOpen: false) == .open, "key actions")
    check(ShelfKeyboard.wantsFocus(pageOpen: true, itemCount: 2, pointerInside: true, quickLookOpen: false, gaveBack: false),
          "keyboard taken over the open Shelf page with items")
    check(!ShelfKeyboard.wantsFocus(pageOpen: true, itemCount: 0, pointerInside: true, quickLookOpen: false, gaveBack: false)
          && !ShelfKeyboard.wantsFocus(pageOpen: true, itemCount: 2, pointerInside: false, quickLookOpen: false, gaveBack: false)
          && !ShelfKeyboard.wantsFocus(pageOpen: false, itemCount: 2, pointerInside: true, quickLookOpen: false, gaveBack: false)
          && !ShelfKeyboard.wantsFocus(pageOpen: true, itemCount: 2, pointerInside: true, quickLookOpen: false, gaveBack: true),
          "never on an empty Shelf, with the pointer outside, on another page, or after typing something else")
    check(ShelfKeyboard.wantsFocus(pageOpen: false, itemCount: 2, pointerInside: false, quickLookOpen: true, gaveBack: true),
          "kept while Quick Look shows a Shelf item")
    check(ShelfKeyboard.move(from: "b", by: 1, in: ["a", "b", "c"]) == "c" && ShelfKeyboard.move(from: "c", by: 1, in: ["a", "b", "c"]) == "a"
          && ShelfKeyboard.move(from: "a", by: -1, in: ["a", "b", "c"]) == "c" && ShelfKeyboard.move(from: nil, by: 1, in: ["a", "b"]) == "a"
          && ShelfKeyboard.move(from: nil, by: -1, in: ["a", "b"]) == "b" && ShelfKeyboard.move(from: "a", by: 1, in: []) == nil,
          "arrows move through the items and wrap")

    var confirmation = ShelfClearConfirmation()
    check(!confirmation.tap(now: 10) && confirmation.isArmed(now: 12), "Clear All: the first click asks")
    check(confirmation.tap(now: 12.5) && !confirmation.isArmed(now: 12.6), "a second click within 3 s clears")
    _ = confirmation.tap(now: 20)
    check(!confirmation.isArmed(now: 23.1) && !confirmation.tap(now: 23.1), "after 3 s the question lapses and the next click asks again")
}

// MARK: - Settings

@MainActor
private func checkShelfSettings() {
    check(Keys.shelfEnabled.name == "shelf.enabled" && Keys.shelfEnabled.defaultValue == true, "shelf.enabled defaults to on")
    check(Keys.shelfIndicator.name == "shelf.indicator" && Keys.shelfIndicator.defaultValue == true, "shelf.indicator defaults to on")
    check(Keys.shelfStorage.name == "shelf.storage" && Keys.shelfStorage.defaultValue == .reference, "shelf.storage defaults to a reference")
    check([Keys.shelfEnabled.name, Keys.shelfIndicator.name, Keys.shelfStorage.name].allSatisfy { $0.hasPrefix(Keys.shelfKeyPrefix) },
          "Shelf keys share the shelf. prefix")
    check(ShelfStorageMode.reference.title == "Keep a link to the original" && ShelfStorageMode.copy.title == "Store a copy", "storage titles")
    let suite = "lintel.checks.shelf.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    let store = SettingsStore(defaults: defaults, center: NotificationCenter())
    store[Keys.shelfStorage] = .copy
    check(defaults.string(forKey: "shelf.storage") == "copy" && store[Keys.shelfStorage] == .copy, "storage mode stored by its raw value")
    defaults.set("sideways", forKey: "shelf.storage")
    check(store[Keys.shelfStorage] == .reference, "an unknown storage mode falls back to the default")
    defaults.removePersistentDomain(forName: suite)
}

// MARK: - Activity-engine contract

@MainActor
private func checkShelfEngineContract() {
    check(LiveActivityKind.shelf.rawValue == "shelf" && ExpandedContent.shelf.rawValue == "shelf", "contract cases")

    var engine = ActivityEngine()
    engine.setLive(.shelf, active: true, identity: "drop-1", now: 1)
    check(engine.compactPresentation == .live([.shelf]), "the indicator shows on its own")
    check(engine.expandedContent == .shelf, "opening from the indicator shows the Shelf page")
    check(engine.mostRecent == .shelf, "a drop makes the Shelf the most recent activity")
    check(engine.hasDismissible, "the indicator can be swiped away")
    engine.setLive(.media, active: true, identity: "t1", now: 2)
    check(engine.compactPresentation == .live([.media]), "with media visible the indicator is left out")
    check(engine.expandedContent == .media, "media wins the open island over the indicator")
    engine.setLive(.calendar, active: true, identity: "e1", now: 3)
    check(engine.compactPresentation == .live([.media, .calendar]) && engine.expandedContent == .both, "media + calendar unchanged by the Shelf")
    engine.setLive(.media, active: false, now: 4)
    check(engine.compactPresentation == .live([.calendar]) && engine.expandedContent == .calendar, "calendar + Shelf: calendar")

    // A drag chooses the Shelf page whatever is live, until the island closes.
    var drag = ActivityEngine()
    drag.setLive(.media, active: true, identity: "t1", now: 1)
    drag.setExpanded(true)
    let generation = drag.generation
    drag.focusShelfForDrop()
    check(drag.expandedContent == .shelf && drag.shelfDropFocus && drag.cycledChoice == .shelf, "a drag over the island shows the drop zone over media")
    check(drag.generation != generation, "the drag focus is a change")
    let again = drag.generation
    drag.focusShelfForDrop()
    check(drag.generation == again, "repeated drag events change nothing")
    drag.setExpanded(false)
    check(!drag.shelfDropFocus && drag.cycledChoice == nil && drag.expandedContent == .media, "closing the island ends the drag focus")
    var idle = ActivityEngine()
    idle.focusShelfForDrop()
    check(idle.expandedContent == .shelf, "a drag on an idle island shows the Shelf (slot 4 and the choice agree)")

    // Cycle: media → calendar → both → shelf → media.
    var cycle = ActivityEngine()
    var seen: [ExpandedContent] = []
    for _ in 0..<5 {
        cycle.cycleExpanded()
        seen.append(cycle.expandedContent)
    }
    check(seen == [.calendar, .both, .shelf, .media, .calendar], "cycle includes the Shelf page after both (got \(seen))")
    cycle.shelfEnabled = false
    seen = []
    for _ in 0..<4 {
        cycle.cycleExpanded()
        seen.append(cycle.expandedContent)
    }
    check(!seen.contains(.shelf), "a switched-off Shelf leaves the cycle")

    // Switching the Shelf off leaves the page and the drop focus.
    var off = ActivityEngine()
    off.setLive(.shelf, active: true, identity: "drop-1", now: 1)
    off.focusShelfForDrop()
    off.shelfEnabled = false
    check(off.expandedContent == off.idleContent && off.cycledChoice == nil && !off.shelfDropFocus && off.mostRecent == nil,
          "switching the Shelf off returns to the usual content")
    off.focusShelfForDrop()
    check(off.cycledChoice == nil, "no drop focus while switched off")
    off.followMostRecent = true
    check(off.expandedContent != .shelf, "never the Shelf page while switched off")

    // Dismissing: the hidden indicator is never what a swipe dismisses.
    var dismiss = ActivityEngine()
    dismiss.setLive(.media, active: true, identity: "t1", now: 1)
    dismiss.setLive(.shelf, active: true, identity: "drop-1", now: 2)
    check(dismiss.dismissTopLiveActivity() == .media, "swipe up dismisses what's drawn (media), not the hidden indicator")
    check(dismiss.compactPresentation == .live([.shelf]), "with media put away the indicator shows")
    check(dismiss.dismissTopLiveActivity() == .shelf && dismiss.compactPresentation == .idle, "then the indicator itself")
    dismiss.setLive(.shelf, active: true, identity: "drop-2", now: 3)
    check(dismiss.compactPresentation == .live([.shelf]), "a new drop brings the dismissed indicator back")

    // Media peeks: skipped while Now Playing is what the island shows.
    var peek = ActivityEngine()
    peek.setLive(.media, active: true, identity: "t1", now: 1)
    peek.setLive(.shelf, active: true, identity: "drop-1", now: 2)
    check(!peek.requestPeek(.media, userInitiated: false, now: 3), "no media peek while Now Playing shows (Shelf hidden behind it)")
    var peekShelf = ActivityEngine()
    peekShelf.setLive(.shelf, active: true, identity: "drop-1", now: 1)
    peekShelf.setLive(.media, active: true, identity: "t1", now: 2)
    peekShelf.dismissTopLiveActivity()
    check(peekShelf.requestPeek(.media, userInitiated: false, now: 3), "a media change peeks while only the indicator shows")

    check(SwapPlan.between(.live([.shelf]), .live([.media])) == .morph && SwapPlan.between(.idle, .live([.shelf])) == .grow,
          "live swaps involving the Shelf")
    let base = CGSize(width: 185, height: 33.5)
    check(PresentationMetrics.compactSize(for: .live([.shelf]), base: base) == PresentationMetrics.compactSize(for: .live([.calendar]), base: base),
          "the indicator has the live-activity size")
    check(PresentationMetrics.expandedBodySize(for: .shelf) == CGSize(width: 345, height: 175), "Shelf page body 345 × 175")
    check(ExpandedContent(idle: .media) == .media, "idle choices unchanged")
}
