import AppKit
import LintelCore

/// Something the Shelf takes from a drop, after `ShelfImportPlanner` picked the item's best
/// representation.
enum ShelfIncoming {
    case file(URL)
    case promise(NSFilePromiseReceiver, sourceURL: String?)
    case image(Data, fileExtension: String, sourceURL: String?)
    case link(String, title: String?)
    case text(String)
}

/// Reads a drag (or any) pasteboard item by item. Runs on the main actor while the drop is being
/// performed, so everything that lives only on the drag pasteboard (image data, text, promises) is
/// read before the drop returns; the slow work happens afterwards.
@MainActor
enum ShelfPasteboardReader {
    /// Types the island's drop view registers for.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, NSPasteboard.PasteboardType(ShelfTypes.urlName)]
        types += ShelfTypes.imageTypes.map { NSPasteboard.PasteboardType($0.type) }
        types += NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
        types += ShelfTypes.promiseTypes.map { NSPasteboard.PasteboardType($0) }
        var seen = Set<String>()
        return types.filter { seen.insert($0.rawValue).inserted }
    }

    static func read(_ pasteboard: NSPasteboard, locations: ShelfLocations) -> [ShelfIncoming] {
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        let promiseTypes = Set(NSFilePromiseReceiver.readableDraggedTypes).union(ShelfTypes.promiseTypes)
        // Promise receivers come back in item order for the items that offer one. AppKit can only
        // receive promised files from the drag pasteboard while a drop is being performed (it raises
        // an exception otherwise), so other pasteboards use the items' other representations.
        let promisesAllowed = pasteboard.name == .drag
        var receivers = promisesAllowed
            ? (pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]) ?? []
            : []
        var incoming: [ShelfIncoming] = []
        for item in items {
            let types = item.types.map(\.rawValue)
            let offersPromise = types.contains(where: promiseTypes.contains)
            let receiver = offersPromise && !receivers.isEmpty ? receivers.removeFirst() : nil
            let dragged = ShelfDraggedItem(types: types, filePath: filePath(of: item), url: item.string(forType: .URL),
                                           urlTitle: item.string(forType: NSPasteboard.PasteboardType(ShelfTypes.urlName)),
                                           text: item.string(forType: .string), promise: receiver != nil)
            switch ShelfImportPlanner.plan(for: dragged) {
            case .file(let path):
                incoming.append(.file(URL(fileURLWithPath: path)))
            case .promise:
                if let receiver { incoming.append(.promise(receiver, sourceURL: dragged.url)) }
            case .imageData(let type, let fileExtension):
                guard var data = item.data(forType: NSPasteboard.PasteboardType(type)) else { continue }
                if type == "public.tiff" {
                    // TIFF from apps and browsers is stored as PNG.
                    guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else { continue }
                    data = png
                }
                incoming.append(.image(data, fileExtension: fileExtension, sourceURL: dragged.url))
            case .link(let url, let title):
                incoming.append(.link(url, title: title))
            case .text(let text):
                incoming.append(.text(text))
            case .skip:
                continue
            }
        }
        return incoming
    }

    /// The dragged file's path. Read through `NSURL`'s own pasteboard reader (the path that carries
    /// the drop's access to files in protected folders); Finder puts file reference URLs
    /// (`file:///.file/id=…`) on the pasteboard, which resolve to a path here.
    private static func filePath(of item: NSPasteboardItem) -> String? {
        guard item.types.contains(.fileURL) else { return nil }
        let url: URL
        if let plist = item.propertyList(forType: .fileURL), let read = NSURL(pasteboardPropertyList: plist, ofType: .fileURL) {
            url = read as URL
        } else if let string = item.string(forType: .fileURL), let parsed = URL(string: string) {
            url = parsed
        } else {
            return nil
        }
        guard url.isFileURL else { return nil }
        let pathURL = (url as NSURL).filePathURL ?? url
        let path = pathURL.standardizedFileURL.path
        return path.isEmpty || path.hasPrefix("/.file/") ? nil : path
    }
}
