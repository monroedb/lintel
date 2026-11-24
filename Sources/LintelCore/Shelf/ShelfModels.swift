import Foundation

// Shelf models: what an item is, where its data lives, its
// state, and the persisted index.

/// What a Shelf item is.
public enum ShelfItemKind: String, Codable, Sendable, CaseIterable {
    case file, folder, image, text, link

    /// Kinds backed by a file or folder on disk that Finder can show.
    public var isFileBased: Bool { self == .file || self == .folder || self == .image }
}

/// How dropped files are kept (setting `shelf.storage`).
public enum ShelfStorageMode: String, SettingChoice {
    case reference, copy

    public var title: String {
        switch self {
        case .reference: return "Keep a link to the original"
        case .copy: return "Store a copy"
        }
    }
}

/// Where an item's data lives.
public enum ShelfItemStorage: Codable, Equatable, Sendable {
    /// The original stays where it is; the bookmark follows it when it moves or is renamed.
    case reference(bookmark: Data, path: String)
    /// A file or folder in Lintel's Shelf folder (copies, received files, text clips, link files),
    /// relative to that folder, with the original's path when there was one.
    case stored(relativePath: String, originalPath: String?)

    public var isReference: Bool {
        if case .reference = self { return true }
        return false
    }
}

/// Whether an item can be used.
public enum ShelfItemState: String, Codable, Sendable, CaseIterable {
    case available
    /// Being copied or received.
    case pending
    /// Doesn't resolve: moved to another volume or deleted.
    case missing
    case inTrash
    /// On a volume that isn't mounted.
    case unavailable
    /// Reading it was refused (privacy).
    case noAccess
    /// Copying or receiving failed.
    case failed

    public var isUsable: Bool { self == .available }

    /// Removed by "Remove Missing Items".
    public var isGone: Bool { self == .missing || self == .inTrash || self == .failed }

    /// Tile and tooltip wording; nil while usable.
    public func label(volume: String? = nil) -> String? {
        switch self {
        case .available: return nil
        case .pending: return "Copying…"
        case .missing: return "Not found — it was moved or deleted"
        case .inTrash: return "Moved to the Trash"
        case .unavailable: return "\(volume ?? "Its disk") isn't connected"
        case .noAccess:
            return "Lintel can't read files in this folder. Allow it in System Settings › Privacy & Security › Files and Folders, or use “Store a copy”."
        case .failed: return "Couldn't store a copy"
        }
    }
}

public struct ShelfLink: Codable, Equatable, Sendable {
    public var url: String
    public var title: String?

    public init(url: String, title: String? = nil) {
        self.url = url
        self.title = title
    }
}

public struct ShelfItem: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: ShelfItemKind
    /// Display name (file name, text clip's first line, link title).
    public var name: String
    /// Uniform type identifier of the file, when known.
    public var typeIdentifier: String?
    public var byteSize: Int64?
    public var added: Date
    public var storage: ShelfItemStorage
    public var state: ShelfItemState
    public var link: ShelfLink?
    /// First characters of a text clip (the full text is in its stored file).
    public var textPreview: String?
    /// Identifies duplicates: the original's path (references), the URL (links), a hash of the text;
    /// nil for copies, which are snapshots.
    public var fingerprint: String?
    public var hasThumbnail: Bool
    /// The reference is in a folder macOS protects: not read at launch or on display.
    public var isProtected: Bool
    /// The original's modification date when the thumbnail was made.
    public var modified: Date?
    /// Where received image data or a promised file came from (browser drags).
    public var sourceURL: String?

    public init(id: String, kind: ShelfItemKind, name: String, typeIdentifier: String? = nil, byteSize: Int64? = nil,
                added: Date, storage: ShelfItemStorage, state: ShelfItemState = .available, link: ShelfLink? = nil,
                textPreview: String? = nil, fingerprint: String? = nil, hasThumbnail: Bool = false, isProtected: Bool = false,
                modified: Date? = nil, sourceURL: String? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.typeIdentifier = typeIdentifier
        self.byteSize = byteSize
        self.added = added
        self.storage = storage
        self.state = state
        self.link = link
        self.textPreview = textPreview
        self.fingerprint = fingerprint
        self.hasThumbnail = hasThumbnail
        self.isProtected = isProtected
        self.modified = modified
        self.sourceURL = sourceURL
    }

    /// Path of the original (references) or of the original a copy was made from.
    public var originalPath: String? {
        switch storage {
        case .reference(_, let path): return path
        case .stored(_, let original): return original
        }
    }

    /// Volume name when the item lives on `/Volumes/<name>`.
    public var volumeName: String? {
        guard case .reference(_, let path) = storage, let root = ShelfLocations.volumeRoot(of: path) else { return nil }
        return (root as NSString).lastPathComponent
    }
}

/// The persisted index (`Shelf.json`).
public struct ShelfIndex: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Number of drops so far; names the indicator's identity so a new drop restores a dismissed
    /// indicator.
    public var drops: Int
    /// Newest first.
    public var items: [ShelfItem]

    public init(version: Int = ShelfIndex.currentVersion, drops: Int = 0, items: [ShelfItem] = []) {
        self.version = version
        self.drops = drops
        self.items = items
    }

    /// Reads only the version, so an index from a newer Lintel is left alone.
    public struct Header: Decodable, Sendable {
        public var version: Int
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public enum LoadResult: Equatable, Sendable {
        case loaded(ShelfIndex)
        /// Written by a newer Lintel: shown but never overwritten.
        case newer(version: Int)
        /// Not JSON or not an index: moved aside, the Shelf starts empty.
        case corrupt
    }

    public static func load(_ data: Data) -> LoadResult {
        guard let header = try? decoder().decode(Header.self, from: data) else { return .corrupt }
        if header.version > currentVersion { return .newer(version: header.version) }
        guard let index = try? decoder().decode(ShelfIndex.self, from: data) else { return .corrupt }
        return .loaded(index)
    }
}
