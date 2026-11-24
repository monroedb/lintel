import AppKit
import LintelCore

/// A window-server space above all Spaces that windows can be held in, so Space switches, full-screen
/// transitions and the desktop slide don't move them.
/// No public API does this: windows that join all Spaces are
/// still drawn as part of each Space and slide with it.
@MainActor
protocol WindowSpaceProvider: AnyObject {
    /// Whether windows can be held now (functions present, switched on, behaving).
    var isAvailable: Bool { get }
    var status: PrivateCapabilityRegistry.Status { get }
    /// Adds the windows to the space (creating and showing it on first use) and takes them out of the
    /// desktops and full-screen Spaces, so the space is the only one drawing them. False when the
    /// window server doesn't confirm that; the provider then reports itself misbehaving and holds nothing.
    func hold(_ windowNumbers: [Int]) -> Bool
    /// Takes the windows back out; the window server puts them back in every Space (they join all
    /// Spaces), measured.
    func release(_ windowNumbers: [Int])
    /// Releases every window and destroys the space (quit, switched off).
    func invalidate()
    /// Re-reads the capability switch (Settings, `defaults write`).
    func reload()
    /// The spaces a window is in (nil when that can't be asked).
    func spaces(of windowNumber: Int) -> [UInt64]?
}

/// The public behaviour: no dedicated space; the panels rely on their collection behaviour.
@MainActor
final class AllSpacesProvider: WindowSpaceProvider {
    var isAvailable: Bool { false }
    var status: PrivateCapabilityRegistry.Status { .unavailable("public behaviour only") }
    func hold(_ windowNumbers: [Int]) -> Bool { false }
    func release(_ windowNumbers: [Int]) {}
    func invalidate() {}
    func reload() {}
    func spaces(of windowNumber: Int) -> [UInt64]? { nil }
}

/// The private CGS space functions, resolved with `dlopen`/`dlsym` at runtime (never linked):
/// `CGSSpaceCreate`, `CGSSpaceSetAbsoluteLevel(400)`, `CGSShowSpaces`, `CGSAddWindowsToSpaces`,
/// `CGSRemoveWindowsFromSpaces`, `CGSHideSpaces`, `CGSSpaceDestroy`, plus
/// `CGSSpaceGetAbsoluteLevel` and `CGSCopySpacesForWindows` to confirm the result. If a function is
/// missing or the window server doesn't confirm the level or the windows' membership, the capability
/// reports itself and the island keeps the public behaviour.
@MainActor
final class CGSWindowSpaceProvider: WindowSpaceProvider {
    static let capabilityID = "windowSpace"
    private static let title = "Still island during Space switches (window-server space)"
    private static let frameworkPath = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"

    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceDestroy = @convention(c) (Int32, UInt64) -> Void
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Void
    private typealias SpaceGetLevel = @convention(c) (Int32, UInt64) -> Int32
    private typealias WindowsAndSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias Spaces = @convention(c) (Int32, CFArray) -> Void
    private typealias CopySpacesForWindows = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?

    private struct Functions {
        let connection: MainConnection
        let create: SpaceCreate
        let destroy: SpaceDestroy
        let setLevel: SpaceSetLevel
        let getLevel: SpaceGetLevel?
        let add: WindowsAndSpaces
        let remove: WindowsAndSpaces
        let show: Spaces
        let hide: Spaces
        let copySpaces: CopySpacesForWindows?
    }

    private let settings: SettingsStore
    private let registry: PrivateCapabilityRegistry
    private var functions: Functions?
    private var space: UInt64?
    private var held: Set<Int> = []
    private(set) var status: PrivateCapabilityRegistry.Status = .unavailable("not loaded")
    /// Window-server calls made.
    private(set) var calls: [String: Int] = [:]

    init(settings: SettingsStore, registry: PrivateCapabilityRegistry = .shared) {
        self.settings = settings
        self.registry = registry
        reload()
    }

    var isAvailable: Bool { status.isUsable }

    func reload() {
        if !settings[Keys.windowSpaceCapability] {
            invalidate()
            setStatus(.switchedOff)
            return
        }
        // A misbehaving capability stays off until the next launch.
        if case .misbehaving = status { setStatus(status); return }
        if functions != nil { setStatus(.available); return }
        let handle = dlopen(Self.frameworkPath, RTLD_LAZY) ?? UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func symbol<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let connection = symbol("CGSMainConnectionID", MainConnection.self),
              let create = symbol("CGSSpaceCreate", SpaceCreate.self),
              let destroy = symbol("CGSSpaceDestroy", SpaceDestroy.self),
              let setLevel = symbol("CGSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let add = symbol("CGSAddWindowsToSpaces", WindowsAndSpaces.self),
              let remove = symbol("CGSRemoveWindowsFromSpaces", WindowsAndSpaces.self),
              let show = symbol("CGSShowSpaces", Spaces.self),
              let hide = symbol("CGSHideSpaces", Spaces.self) else {
            setStatus(.unavailable("symbols missing"))
            return
        }
        functions = Functions(connection: connection, create: create, destroy: destroy, setLevel: setLevel,
                              getLevel: symbol("CGSSpaceGetAbsoluteLevel", SpaceGetLevel.self),
                              add: add, remove: remove, show: show, hide: hide,
                              copySpaces: symbol("CGSCopySpacesForWindows", CopySpacesForWindows.self))
        setStatus(.available)
    }

    private func setStatus(_ newValue: PrivateCapabilityRegistry.Status) {
        status = newValue
        registry.report(id: Self.capabilityID, title: Self.title, setting: Keys.windowSpaceCapability, status: newValue)
    }

    private func count(_ call: String) { calls[call, default: 0] += 1 }

    // MARK: Holding

    func hold(_ windowNumbers: [Int]) -> Bool {
        guard isAvailable, let functions else { return false }
        let windows = windowNumbers.filter { $0 > 0 }
        guard !windows.isEmpty else { return true }
        guard let space = ensureSpace(functions) else { return false }
        let cid = functions.connection()
        functions.add(cid, windows.map { NSNumber(value: $0) } as CFArray, [NSNumber(value: space)] as CFArray)
        count("add")
        // A panel that already joined every Space (re-held after a lock, or after the switch was off) stays
        // in the desktops too; each of them would still draw a copy that slides, so it leaves them.
        for number in windows {
            let others = IslandSpacePolicy.otherSpaces(spaces(of: number, mask: IslandSpacePolicy.desktopsMask) ?? [],
                                                       dedicated: space)
            guard !others.isEmpty else { continue }
            functions.remove(cid, [NSNumber(value: number)] as CFArray, others.map { NSNumber(value: $0) } as CFArray)
            count("leaveDesktops")
        }
        let answers = windows.map { spaces(of: $0) }
        guard IslandSpacePolicy.holdConfirmed(space: space, spacesPerWindow: answers) else {
            functions.remove(cid, windows.map { NSNumber(value: $0) } as CFArray, [NSNumber(value: space)] as CFArray)
            count("remove")
            Log.app.error("Window-server space \(space, privacy: .public): windows \(windows.description, privacy: .public) didn't join it; keeping the public behaviour")
            invalidate()
            setStatus(.misbehaving("windows didn't join the space"))
            return false
        }
        held.formUnion(windows)
        return true
    }

    func release(_ windowNumbers: [Int]) {
        guard let functions, let space else { return }
        let windows = windowNumbers.filter { held.contains($0) }
        guard !windows.isEmpty else { return }
        functions.remove(functions.connection(), windows.map { NSNumber(value: $0) } as CFArray,
                         [NSNumber(value: space)] as CFArray)
        count("remove")
        held.subtract(windows)
    }

    func invalidate() {
        guard let functions, let space else { return }
        release(Array(held))
        let cid = functions.connection()
        functions.hide(cid, [NSNumber(value: space)] as CFArray)
        functions.destroy(cid, space)
        count("destroy")
        self.space = nil
        held.removeAll()
    }

    /// Creates the space at absolute level 400 and shows it (once).
    private func ensureSpace(_ functions: Functions) -> UInt64? {
        if let space { return space }
        let cid = functions.connection()
        let id = functions.create(cid, IslandSpacePolicy.createFlag, nil)
        count("create")
        guard IslandSpacePolicy.isUsableSpace(id) else {
            setStatus(.misbehaving("space not created"))
            return nil
        }
        functions.setLevel(cid, id, IslandSpacePolicy.absoluteLevel)
        let level = functions.getLevel.map { $0(cid, id) }
        guard IslandSpacePolicy.levelConfirmed(level) else {
            functions.destroy(cid, id)
            setStatus(.misbehaving("level reads \(level ?? -1)"))
            return nil
        }
        functions.show(cid, [NSNumber(value: id)] as CFArray)
        space = id
        Log.app.notice("Window-server space \(id, privacy: .public) at level \(IslandSpacePolicy.absoluteLevel, privacy: .public) holds the island")
        return id
    }

    // MARK: Reading back

    func spaces(of windowNumber: Int) -> [UInt64]? { spaces(of: windowNumber, mask: IslandSpacePolicy.membershipMask) }

    private func spaces(of windowNumber: Int, mask: Int32) -> [UInt64]? {
        guard let functions, let copy = functions.copySpaces else { return nil }
        guard let array = copy(functions.connection(), mask,
                               [NSNumber(value: windowNumber)] as CFArray)?.takeRetainedValue() as? [NSNumber] else { return [] }
        return array.map(\.uint64Value)
    }
}
