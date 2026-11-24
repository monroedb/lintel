import Foundation

// Shelf rules: ordering and duplicates, paging, naming,
// locations (protected, temporary, Trash, volumes), deletion safety, resolution → state, keyboard
// and the two-step Clear All. Pure, checked by `lintel-checks`.

// MARK: - Order and duplicates

public enum ShelfOrdering {
    /// Fingerprints that identify duplicates. Copies have none: each copy is a snapshot.
    public static func fingerprint(referencePath path: String) -> String { "path:" + ShelfLocations.normalized(path) }
    public static func fingerprint(link url: String) -> String { "link:" + url.trimmingCharacters(in: .whitespacesAndNewlines) }
    public static func fingerprint(text: String) -> String { "text:" + ShelfHash.fnv1a64(text) }
    /// Received images and files that came from a web address (browser drags): the same picture
    /// dragged again is kept once.
    public static func fingerprint(source url: String) -> String { "src:" + url.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Index of a usable item with the same fingerprint.
    public static func duplicate(of fingerprint: String?, in items: [ShelfItem]) -> Int? {
        guard let fingerprint else { return nil }
        return items.firstIndex { $0.fingerprint == fingerprint && $0.state != .missing && $0.state != .inTrash }
    }

    /// Puts a drop's items in front (newest first, keeping the drop's own order); duplicates move
    /// their existing item to the front instead (with a fresh date) and the new copy is dropped.
    /// Returns the new list and the ids now in front because of this drop.
    public static func inserting(_ batch: [ShelfItem], into items: [ShelfItem], now: Date) -> (items: [ShelfItem], front: [String]) {
        var remaining = items
        var front: [ShelfItem] = []
        for var item in batch {
            if let index = duplicate(of: item.fingerprint, in: remaining) {
                var existing = remaining.remove(at: index)
                existing.added = now
                front.append(existing)
            } else if let index = duplicate(of: item.fingerprint, in: front) {
                front[index].added = now // the same thing twice in one drop
            } else {
                item.added = now
                front.append(item)
            }
        }
        return (front + remaining, front.map(\.id))
    }
}

/// FNV-1a, 64-bit: a stable, dependency-free hash for text fingerprints.
public enum ShelfHash {
    public static func fnv1a64(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Paging

public struct ShelfPaging: Equatable, Sendable {
    public static let perPage = 5

    public var count: Int
    public var page: Int

    public init(count: Int, page: Int) {
        self.count = max(0, count)
        self.page = ShelfPaging.clamped(page, count: count)
    }

    public var pageCount: Int { max(1, (count + Self.perPage - 1) / Self.perPage) }
    public var range: Range<Int> {
        let start = min(count, page * Self.perPage)
        return start..<min(count, start + Self.perPage)
    }
    public var hasPrevious: Bool { page > 0 }
    public var hasNext: Bool { page < pageCount - 1 }

    public static func clamped(_ page: Int, count: Int) -> Int {
        let pages = max(1, (max(0, count) + perPage - 1) / perPage)
        return min(max(0, page), pages - 1)
    }

    public static func page(of index: Int) -> Int { max(0, index) / perPage }
}

// MARK: - Naming

public enum ShelfNaming {
    /// A text clip's name: its first non-empty line, spaces collapsed, at most `limit` characters.
    public static func textTitle(_ text: String, limit: Int = 40) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return "Text" }
        return truncated(line, limit: limit)
    }

    /// The first characters kept in the index (the full text lives in the clip's file).
    public static func textPreview(_ text: String, limit: Int = 280) -> String {
        text.count <= limit ? text : String(text.prefix(limit))
    }

    public static func truncated(_ text: String, limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(max(1, limit - 1))) + "…"
    }

    /// Host without "www.".
    public static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// A link's name: its title, else host and path, else the URL itself.
    public static func linkTitle(url: String, title: String?) -> String {
        let cleaned = title?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
        if !cleaned.isEmpty { return truncated(cleaned, limit: 80) }
        if let parsed = URL(string: url), let host = host(of: url) {
            let path = parsed.path == "/" ? "" : parsed.path
            return truncated(host + path, limit: 80)
        }
        return truncated(url, limit: 80)
    }

    /// File name for dropped image data: the source URL's file name when it names an image file,
    /// else "Image yyyy-MM-dd at HH.mm.ss".
    public static func imageFileName(sourceURL: String?, fileExtension: String, date: Date, calendar: Calendar = .current) -> String {
        if let sourceURL, let url = URL(string: sourceURL) {
            let last = url.lastPathComponent
            let ext = (last as NSString).pathExtension.lowercased()
            if !ext.isEmpty, ShelfTypes.imageExtensions.contains(ext) {
                return safeFileName(last.removingPercentEncoding ?? last)
            }
        }
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let stamp = String(format: "%04d-%02d-%02d at %02d.%02d.%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0,
                           c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return "Image \(stamp).\(fileExtension)"
    }

    /// A name that is safe as one path component: no slashes, colons or control characters, no
    /// leading dot, at most 200 UTF-8 bytes (extension kept).
    public static func safeFileName(_ name: String, fallback: String = "Item") -> String {
        var cleaned = String(name.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return Character(scalar)
        }).trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty || cleaned == ".." { cleaned = fallback }
        guard cleaned.utf8.count > 200 else { return cleaned }
        let ext = (cleaned as NSString).pathExtension
        var stem = (cleaned as NSString).deletingPathExtension
        let budget = 200 - (ext.isEmpty ? 0 : ext.utf8.count + 1)
        while stem.utf8.count > budget { stem.removeLast() }
        return ext.isEmpty ? stem : stem + "." + ext
    }

    /// Trailing count of the compact indicator.
    public static func countLabel(_ count: Int) -> String { count > 99 ? "99+" : String(max(0, count)) }

    public static func itemsLabel(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
}

// MARK: - Pasteboard types

public enum ShelfTypes {
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    public static let urlName = "public.url-name"
    public static let plainText = "public.utf8-plain-text"
    public static let legacyText = "NSStringPboardType"
    /// Image data types the Shelf stores, in order of preference, with the extension they're saved
    /// with (TIFF is converted to PNG).
    public static let imageTypes: [(type: String, fileExtension: String)] = [
        ("public.png", "png"), ("public.jpeg", "jpg"), ("public.heic", "heic"), ("com.compuserve.gif", "gif"),
        ("org.webmproject.webp", "webp"), ("public.tiff", "png"),
    ]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp", "svg", "avif"]
    /// Types that announce a file promise (as AppKit's promise receiver reads them).
    public static let promiseTypes: Set<String> = [
        "com.apple.NSFilePromiseItemMetaData", "com.apple.pasteboard.promised-file-content-type",
        "com.apple.pasteboard.promised-file-url", "com.apple.pasteboard.promised-suggested-file-name",
    ]
    /// Marks drags that start on the Shelf, so they aren't dropped back onto it.
    public static let ownDrag = "com.sashagilliard.lintel.shelf-item"
}

// MARK: - Locations

public struct ShelfLocations: Equatable, Sendable {
    public var home: String
    /// Temporary folders whose files don't last (copied even in reference mode).
    public var temporaryRoots: [String]

    public init(home: String, temporaryRoots: [String] = ["/private/var/folders", "/var/folders", "/private/tmp", "/tmp"]) {
        self.home = Self.normalized(home)
        self.temporaryRoots = temporaryRoots.map(Self.normalized)
    }

    /// A path without empty, "." and ".." components, and with the "/private" of /private/var,
    /// /private/tmp and /private/etc dropped (they are the same folders). Purely lexical: unlike
    /// `standardizingPath` it never asks the file system.
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }

    /// Whether `path` is `folder` or inside it, compared component by component.
    public static func isInside(_ path: String, folder: String) -> Bool {
        let p = normalized(path), f = normalized(folder)
        if p == f { return true }
        return p.hasPrefix(f == "/" ? f : f + "/")
    }

    /// Folders macOS protects with "Files and Folders" prompts, plus iCloud Drive, cloud-storage
    /// providers and other volumes.
    public func isProtected(_ path: String) -> Bool {
        let folders = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
        if folders.contains(where: { Self.isInside(path, folder: home + "/" + $0) }) { return true }
        return Self.volumeRoot(of: path) != nil
    }

    public func isTemporary(_ path: String) -> Bool {
        temporaryRoots.contains { Self.isInside(path, folder: $0) }
    }

    public func isInTrash(_ path: String) -> Bool {
        if Self.isInside(path, folder: home + "/.Trash") { return true }
        // Other volumes keep theirs in /Volumes/<name>/.Trashes/<uid>/.
        guard let root = Self.volumeRoot(of: path) else { return false }
        return Self.isInside(path, folder: root + "/.Trashes")
    }

    /// "/Volumes/<name>" for paths on another volume.
    public static func volumeRoot(of path: String) -> String? {
        let parts = normalized(path).split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return nil }
        return "/Volumes/" + parts[1]
    }
}

// MARK: - Deleting stored files

public enum ShelfStoragePolicy {
    /// Lintel deletes only strictly inside its Shelf folder; both paths must already have their
    /// symlinks resolved.
    public static func canDelete(_ path: String, storageRoot: String) -> Bool {
        // A path that climbs with ".." is refused outright, before any normalising.
        guard !path.split(separator: "/").contains("..") else { return false }
        let p = ShelfLocations.normalized(path), root = ShelfLocations.normalized(storageRoot)
        guard root != "/", p != root else { return false }
        return ShelfLocations.isInside(p, folder: root)
    }

    /// Relative path of an item's folder inside the Shelf folder.
    public static func itemFolder(id: String) -> String { "Items/" + ShelfNaming.safeFileName(id) }
}

// MARK: - Resolving references

public enum ShelfResolution: Equatable, Sendable {
    case resolved(path: String)
    case notFound
    case noPermission
}

public enum ShelfValidation {
    /// State after resolving an item whose last known path was `lastPath`.
    public static func state(for resolution: ShelfResolution, lastPath: String, locations: ShelfLocations,
                             volumeMounted: (String) -> Bool) -> ShelfItemState {
        switch resolution {
        case .resolved(let path):
            return locations.isInTrash(path) ? .inTrash : .available
        case .noPermission:
            return .noAccess
        case .notFound:
            if let root = ShelfLocations.volumeRoot(of: lastPath), !volumeMounted(root) { return .unavailable }
            return .missing
        }
    }
}

// MARK: - Keyboard

public enum ShelfKey: Equatable, Sendable {
    case space, left, right, enter, escape, copy, other

    /// Key codes of a US-layout keyboard; ⌘C by character so other layouts work.
    public static func from(keyCode: UInt16, characters: String?, command: Bool) -> ShelfKey {
        if command { return characters?.lowercased() == "c" ? .copy : .other }
        switch keyCode {
        case 49: return .space
        case 123: return .left
        case 124: return .right
        case 36, 76: return .enter
        case 53: return .escape
        default: return .other
        }
    }
}

public enum ShelfKeyAction: Equatable, Sendable {
    case toggleQuickLook, previous, next, open, copy, closeQuickLook, closeIsland, giveBackKeyboard
}

public enum ShelfKeyboard {
    public static func action(for key: ShelfKey, quickLookOpen: Bool) -> ShelfKeyAction {
        switch key {
        case .space: return .toggleQuickLook
        case .left: return .previous
        case .right: return .next
        case .enter: return .open
        case .copy: return .copy
        case .escape: return quickLookOpen ? .closeQuickLook : .closeIsland
        case .other: return .giveBackKeyboard
        }
    }

    /// Whether the Shelf holds the keyboard: while an island is open on the Shelf page with items and
    /// the pointer is inside it, or while Quick Look shows a Shelf item; never after the user typed
    /// something else, until the pointer leaves.
    public static func wantsFocus(pageOpen: Bool, itemCount: Int, pointerInside: Bool, quickLookOpen: Bool,
                                  gaveBack: Bool) -> Bool {
        if quickLookOpen { return true }
        return pageOpen && itemCount > 0 && pointerInside && !gaveBack
    }

    /// The next focused item when moving by `delta` (wraps around).
    public static func move(from id: String?, by delta: Int, in ids: [String]) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let id, let index = ids.firstIndex(of: id) else { return delta >= 0 ? ids.first : ids.last }
        return ids[((index + delta) % ids.count + ids.count) % ids.count]
    }
}

// MARK: - Clear All (two steps)

public struct ShelfClearConfirmation: Equatable, Sendable {
    public static let window: Double = 3

    public private(set) var armedUntil: Double?

    public init() {}

    public func isArmed(now: Double) -> Bool { armedUntil.map { now < $0 } ?? false }

    /// First tap arms, a second tap within the window confirms.
    public mutating func tap(now: Double) -> Bool {
        if isArmed(now: now) {
            armedUntil = nil
            return true
        }
        armedUntil = now + Self.window
        return false
    }

    public mutating func reset() { armedUntil = nil }
}
