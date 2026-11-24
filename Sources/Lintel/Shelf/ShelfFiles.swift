import AppKit
import ImageIO
import LintelCore
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers

let shelfLog = Logger(subsystem: Log.subsystem, category: "shelf")

/// Layout of `~/Library/Application Support/Lintel/Shelf`.
struct ShelfPaths: Sendable, Equatable {
    let root: URL

    static var standard: ShelfPaths {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return ShelfPaths(root: base.appendingPathComponent("Lintel/Shelf", isDirectory: true))
    }

    var index: URL { root.appendingPathComponent("Shelf.json") }
    var items: URL { root.appendingPathComponent("Items", isDirectory: true) }
    var thumbnails: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }

    func thumbnail(id: String) -> URL { thumbnails.appendingPathComponent(ShelfNaming.safeFileName(id) + ".png") }
    func itemFolder(id: String) -> URL { root.appendingPathComponent(ShelfStoragePolicy.itemFolder(id: id), isDirectory: true) }
    func url(relative path: String) -> URL { root.appendingPathComponent(path) }

    /// Path relative to the Shelf folder, for files inside it.
    func relative(_ url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path, path = url.standardizedFileURL.path
        guard ShelfLocations.isInside(path, folder: rootPath), path != rootPath else { return nil }
        return String(path.dropFirst(rootPath.count + 1))
    }
}

/// What a background resolve found for one reference.
struct ShelfResolveResult: Sendable {
    var id: String
    var resolution: ShelfResolution
    /// Fresh bookmark when the old one was stale (moved or renamed).
    var bookmark: Data?
    var name: String?
    var modified: Date?
}

/// File work that must not run on the main thread. Every function is `@concurrent` (off the main
/// actor) and every callback handed to the system is `@Sendable`, so nothing inherits main-actor
/// isolation (the crash fixed in 3af9d89); results come back through `await`.
enum ShelfFileWork {
    // MARK: Index

    @concurrent static func write(_ data: Data, to url: URL) async -> String? {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Copies and stored files

    /// Copies a file or folder into `folder` (created), keeping its name. Returns the copy, or the
    /// error; a failed copy leaves nothing behind.
    @concurrent static func copy(_ source: URL, into folder: URL, name: String) async -> Result<URL, ShelfFileError> {
        let manager = FileManager()
        let destination = folder.appendingPathComponent(name)
        do {
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            try manager.copyItem(at: source, to: destination)
            return .success(destination)
        } catch {
            try? manager.removeItem(at: folder)
            return .failure(ShelfFileError(error))
        }
    }

    @concurrent static func store(_ data: Data, in folder: URL, name: String) async -> Result<URL, ShelfFileError> {
        let destination = folder.appendingPathComponent(name)
        do {
            try FileManager().createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic)
            return .success(destination)
        } catch {
            return .failure(ShelfFileError(error))
        }
    }

    /// Deletes stored files, only inside the Shelf folder (symlinks resolved first).
    @concurrent static func delete(_ urls: [URL], storageRoot: URL) async -> [String] {
        let manager = FileManager()
        let root = storageRoot.resolvingSymlinksInPath().standardizedFileURL.path
        var deleted: [String] = []
        for url in urls {
            let path = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard ShelfStoragePolicy.canDelete(path, storageRoot: root) else {
                shelfLog.error("Refused to delete outside the Shelf folder")
                continue
            }
            if (try? manager.removeItem(atPath: path)) != nil { deleted.append(path) }
        }
        return deleted
    }

    @concurrent static func exists(_ url: URL) async -> Bool {
        FileManager().fileExists(atPath: url.path)
    }

    /// Total size of the Shelf folder (Settings).
    @concurrent static func folderSize(_ url: URL) async -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager().enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        while let item = enumerator.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isRegularFile == true { total += Int64(values?.totalFileAllocatedSize ?? 0) }
        }
        return total
    }

    // MARK: References

    struct ResolveRequest: Sendable {
        var id: String
        var bookmark: Data
        var path: String
    }

    @concurrent static func resolve(_ requests: [ResolveRequest]) async -> [ShelfResolveResult] {
        requests.map(resolveOne)
    }

    private static func resolveOne(_ request: ResolveRequest) -> ShelfResolveResult {
        var stale = false
        var result = ShelfResolveResult(id: request.id, resolution: .notFound)
        let url: URL
        do {
            url = try URL(resolvingBookmarkData: request.bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            // The bookmark no longer resolves; the last known path may still be there (another volume
            // restored, bookmark from an older system).
            if FileManager().fileExists(atPath: request.path) {
                result.resolution = .resolved(path: request.path)
                result.bookmark = try? URL(fileURLWithPath: request.path).bookmarkData()
            } else if ShelfFileError(error).isPermission {
                result.resolution = .noPermission
            }
            return result
        }
        var reachable = false
        do {
            reachable = try url.checkResourceIsReachable()
        } catch {
            if ShelfFileError(error).isPermission { result.resolution = .noPermission; return result }
        }
        guard reachable else { return result }
        let path = url.standardizedFileURL.path
        result.resolution = .resolved(path: path)
        let values = try? url.resourceValues(forKeys: [.localizedNameKey, .contentModificationDateKey, .nameKey])
        result.name = values?.name
        result.modified = values?.contentModificationDate
        if stale || path != request.path { result.bookmark = try? url.bookmarkData() }
        return result
    }

    // MARK: Thumbnails (made at drop time)

    /// Writes a PNG thumbnail of at most `pixels` × `pixels`; false when none could be made.
    @concurrent static func thumbnail(of file: URL, to output: URL, pixels: CGFloat = 104) async -> Bool {
        let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: pixels / 2, height: pixels / 2), scale: 2,
                                                   representationTypes: .all)
        let image: CGImage? = await withCheckedContinuation { continuation in
            // @Sendable: Quick Look calls back on its own queue.
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { @Sendable representation, _ in
                continuation.resume(returning: representation?.cgImage)
            }
        }
        guard let image else { return false }
        return writePNG(image, to: output)
    }

    /// Writes an icon image (e.g. the file's Finder icon) as the thumbnail.
    @concurrent static func writeThumbnail(_ image: CGImage, to output: URL) async -> Bool {
        writePNG(image, to: output)
    }

    private static func writePNG(_ image: CGImage, to output: URL) -> Bool {
        try? FileManager().createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

/// A file-system error reduced to what the Shelf needs.
struct ShelfFileError: Error, Sendable {
    var message: String
    var isPermission: Bool

    init(_ error: Error) {
        let ns = error as NSError
        message = ns.localizedDescription
        let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? $0.code : nil }
        isPermission = ns.code == NSFileReadNoPermissionError || ns.code == NSFileWriteNoPermissionError
            || posix == Int(EPERM) || posix == Int(EACCES) || (ns.domain == NSPOSIXErrorDomain && (ns.code == Int(EPERM) || ns.code == Int(EACCES)))
    }
}
