import Foundation

/// One dragged (or pasted) item as the drop target sees it: its pasteboard types and the values the
/// Shelf can use. The app fills it from `NSPasteboardItem`s (file reference URLs already resolved).
public struct ShelfDraggedItem: Equatable, Sendable {
    public var types: [String]
    /// Path of a dragged file or folder.
    public var filePath: String?
    /// A `public.url` value.
    public var url: String?
    public var urlTitle: String?
    public var text: String?
    /// The item offers a file promise that can be received (the app found its receiver).
    public var promise: Bool

    public init(types: [String], filePath: String? = nil, url: String? = nil, urlTitle: String? = nil, text: String? = nil,
                promise: Bool = false) {
        self.types = types
        self.filePath = filePath
        self.url = url
        self.urlTitle = urlTitle
        self.text = text
        self.promise = promise
    }
}

/// What to make of a dragged item.
public enum ShelfImportPlan: Equatable, Sendable {
    case file(path: String)
    case promise
    case imageData(type: String, fileExtension: String)
    case link(url: String, title: String?)
    case text(String)
    case skip
}

public enum ShelfImportPlanner {
    /// The first representation the item offers, in the Shelf's order of preference: file, file
    /// promise, image data, link, text (a text that is one http(s) URL becomes a link).
    public static func plan(for item: ShelfDraggedItem) -> ShelfImportPlan {
        if let path = item.filePath, !path.isEmpty { return .file(path: path) }
        // Only with a promise receiver for the item; otherwise its other representations still count.
        if item.promise { return .promise }
        if let image = ShelfTypes.imageTypes.first(where: { item.types.contains($0.type) }) {
            return .imageData(type: image.type, fileExtension: image.fileExtension)
        }
        if let url = item.url?.trimmingCharacters(in: .whitespacesAndNewlines), isAcceptableLink(url) {
            return .link(url: url, title: item.urlTitle)
        }
        if let text = item.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let link = link(fromText: text) { return .link(url: link, title: nil) }
            return .text(text)
        }
        return .skip
    }

    /// Whether a drag offering these types has anything for the Shelf.
    public static func accepts(types: Set<String>) -> Bool {
        if types.contains(ShelfTypes.ownDrag) { return false }
        if types.contains(ShelfTypes.fileURL) || types.contains(ShelfTypes.url) { return true }
        if types.contains(ShelfTypes.plainText) || types.contains(ShelfTypes.legacyText) { return true }
        if !types.isDisjoint(with: ShelfTypes.promiseTypes) { return true }
        return ShelfTypes.imageTypes.contains { types.contains($0.type) }
    }

    /// Links the Shelf keeps: any scheme except script, data, blob and about URLs (and `file:`, which
    /// is a file), at most 8 KB.
    public static func isAcceptableLink(_ text: String) -> Bool {
        guard text.utf8.count <= 8192, !text.contains(where: \.isWhitespace),
              let url = URL(string: text), let scheme = url.scheme?.lowercased(), !scheme.isEmpty else { return false }
        if ["javascript", "data", "blob", "about", "file"].contains(scheme) { return false }
        // "host:port"-like strings parse with the host as the scheme; real links have more.
        return url.host != nil || ["mailto", "tel", "sms", "facetime", "maps", "x-apple.systempreferences"].contains(scheme)
            || text.contains("://")
    }

    /// The URL when the whole text is one http(s) link.
    public static func link(fromText text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return trimmed
    }
}
