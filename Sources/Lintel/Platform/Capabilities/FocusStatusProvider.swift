import AppKit
import Foundation
import Intents
import LintelCore
import Security

/// Access to the Focus status (`INFocusStatusCenter`).
enum FocusAccess: String {
    case notDetermined, denied, restricted, authorized
}

/// State of the optional Focus database reader (mode name, symbol and tint).
enum FocusDatabaseStatus: String {
    /// "Identify the Focus" is off (default).
    case off
    /// On, but the folder can't be read (Full Disk Access missing).
    case noAccess
    case reading
}

/// Whether a Focus is on and which one: on/off from `INFocusStatusCenter` (public; needs
/// the user's Focus-status permission and the Communication Notifications entitlement), else from
/// the system's Focus database (public file APIs on an undocumented format; needs Full Disk Access),
/// which also gives the mode identity.
@MainActor
protocol FocusStatusProvider: AnyObject {
    /// nil while nothing is known (no access to either source).
    var state: FocusState? { get }
    var access: FocusAccess { get }
    var databaseStatus: FocusDatabaseStatus { get }
    /// Which source decides on/off (`FocusDetection.choose`).
    var detection: FocusDetection { get }
    /// True when on/off can only come from the database (no Communication Notifications entitlement),
    /// so the database must be read whether or not "Identify which Focus is on" is switched on.
    var needsDatabaseForStatus: Bool { get }
    /// The status center's last answer, for diagnostics (nil when not read).
    var systemAnswer: Bool? { get }
    /// Modes listed in the Focus database (empty without it).
    var knownModes: [FocusModeDescriptor] { get }
    var onChange: (() -> Void)? { get set }
    func start()
    /// Shows the system's Focus-status prompt (only ever called from a button in Settings).
    func requestAccess()
    func setDatabaseReading(_ enabled: Bool, folder: URL?)
}

@MainActor
final class SystemFocusStatusProvider: FocusStatusProvider {
    private(set) var state: FocusState?
    private(set) var access: FocusAccess = .notDetermined
    private(set) var databaseStatus: FocusDatabaseStatus = .off
    private(set) var knownModes: [FocusModeDescriptor] = []
    private(set) var detection: FocusDetection = .unavailable
    var onChange: (() -> Void)?

    /// `INFocusStatusCenter` only works with this entitlement; Apple grants it through a provisioning
    /// profile, so ad-hoc, self-signed and personal-team builds can't have it. Without it the Focus
    /// service answers every request with "App is missing Communication Notifications entitlement"
    /// (DNDErrorDomain 1004) and the status never turns on.
    static let communicationEntitlement = "com.apple.developer.usernotifications.communication"
    static let isEntitled: Bool = {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, communicationEntitlement as CFString, nil) as? Bool == true
    }()

    var needsDatabaseForStatus: Bool { !Self.isEntitled }
    var systemAnswer: Bool? { isFocused }

    /// Gathering time for watcher events before the files are read, so a write in progress isn't
    /// read half done and a burst of events reads once.
    static let watcherSettle: Double = 0.05

    /// Fast while there is a status to poll; otherwise only slow checks run (`FocusPolling`). The
    /// database is read when its watchers fire: the former 1 s re-read (two JSON files parsed every
    /// second, and the Focus service asked for access every 5 s although its status can't be used
    /// without the entitlement) woke Lintel every second.
    private var timerInterval: Double? {
        FocusPolling.interval(detection: detection, databaseConfigured: databaseFolder != nil,
                              databaseReadable: databaseStatus == .reading, entitled: Self.isEntitled,
                              authorized: access == .authorized)
    }

    private var isFocused: Bool?
    private var database: FocusDatabase.Snapshot?
    private var databaseFolder: URL?
    private var watcher: DispatchSourceFileSystemObject?
    /// One watcher per database file, for files rewritten in place (the folder doesn't change).
    private var fileWatchers: [DispatchSourceFileSystemObject] = []
    private var settleTask: Task<Void, Never>?
    /// Size and modification date of the files when they were last read.
    private var fileStamp: [String] = []
    private var timer: Timer?
    private var lastAccessCheck: Double = 0
    private var lastDatabaseRead: Double = 0
    /// Database reads.
    private(set) var databaseReads = 0
    private var activationObserver: NSObjectProtocol?
    private var started = false

    static var systemDatabaseFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB", isDirectory: true)
    }

    func start() {
        guard !started else { return }
        started = true
        Log.focus.notice("Focus status: Communication Notifications entitlement \(Self.isEntitled ? "present" : "missing", privacy: .public)")
        refreshAccess()
        updateDetection(force: true)
        readStatus()
        reschedule()
        activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                    object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshAccess()
                self?.poll()
            }
        }
    }

    func requestAccess() {
        // @Sendable: the completion arrives off the main thread (no main-actor isolation to check).
        INFocusStatusCenter.default.requestAuthorization { @Sendable [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.refreshAccess()
                    self?.poll()
                }
            }
        }
    }

    func setDatabaseReading(_ enabled: Bool, folder: URL?) {
        let target = enabled ? (folder ?? Self.systemDatabaseFolder) : nil
        guard target != databaseFolder || (enabled && databaseStatus == .off) else { return }
        stopWatching()
        databaseFolder = target
        database = nil
        knownModes = []
        databaseStatus = enabled ? .noAccess : .off
        if enabled {
            readDatabase()
            startWatching()
        }
        reschedule()
        publish()
    }

    private func reschedule() {
        guard started else { return }
        guard let interval = timerInterval else {
            timer?.invalidate()
            timer = nil
            return
        }
        if let timer, timer.isValid, timer.timeInterval == interval { return }
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Status

    private func refreshAccess() {
        lastAccessCheck = ProcessInfo.processInfo.systemUptime
        let new: FocusAccess
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: new = .authorized
        case .denied: new = .denied
        case .restricted: new = .restricted
        case .notDetermined: new = .notDetermined
        @unknown default: new = .notDetermined
        }
        guard new != access else { return }
        access = new
        if new != .authorized { isFocused = nil }
        updateDetection()
        reschedule()
        publish()
    }

    /// Re-chooses the on/off source after the access or database state changed.
    private func updateDetection(force: Bool = false) {
        let new = FocusDetection.choose(entitled: Self.isEntitled, authorized: access == .authorized,
                                        databaseReadable: databaseStatus == .reading)
        guard new != detection || force else { return }
        detection = new
        if new != .system { isFocused = nil }
        Log.focus.notice("""
            Focus detection: \(new.rawValue, privacy: .public) (entitlement \(Self.isEntitled ? "present" : "missing", privacy: .public), \
            status access \(self.access.rawValue, privacy: .public), database \(self.databaseStatus.rawValue, privacy: .public))
            """)
        reschedule()
    }

    private func poll() {
        let now = ProcessInfo.processInfo.systemUptime
        if Self.isEntitled, access != .authorized, now - lastAccessCheck >= FocusPolling.access {
            refreshAccess()
        }
        readStatus()
        guard databaseFolder != nil else { return }
        if databaseStatus != .reading {
            // Access may have been granted since (Full Disk Access): try again, and watch once readable.
            readDatabase()
            if databaseStatus == .reading {
                startWatching()
                reschedule()
                publish()
            }
        } else if currentStamp() != fileStamp {
            // A change the watchers missed.
            refreshDatabase()
        }
    }

    /// Reads the database again and tells the alerts when it changed.
    private func refreshDatabase() {
        let before = database
        readDatabase()
        if database != before { publish() }
    }

    /// Size and modification date of both files (a stat each, no reading).
    private func currentStamp() -> [String] {
        guard let folder = databaseFolder else { return [] }
        return [FocusDatabase.assertionsFile, FocusDatabase.configurationsFile].map { name in
            let values = try? folder.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(values?.fileSize ?? -1)@\(values?.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0)"
        }
    }

    /// The on/off status is only read when it can be trusted: access granted and the entitlement
    /// present (reading never prompts).
    private func readStatus() {
        guard detection == .system else { return }
        let focused = INFocusStatusCenter.default.focusStatus.isFocused
        guard focused != isFocused else { return }
        isFocused = focused
        // Turning a Focus on or off rewrites the database; read it again for the mode.
        if databaseFolder != nil { readDatabase() }
        publish()
    }

    private func publish() {
        state = FocusState.combine(isFocused: isFocused, database: database, detection: detection)
        onChange?()
    }

    // MARK: Database (opt-in)

    private func readDatabase() {
        guard let folder = databaseFolder else { return }
        lastDatabaseRead = ProcessInfo.processInfo.systemUptime
        databaseReads += 1
        fileStamp = currentStamp()
        let assertions = try? Data(contentsOf: folder.appendingPathComponent(FocusDatabase.assertionsFile))
        let configurations = try? Data(contentsOf: folder.appendingPathComponent(FocusDatabase.configurationsFile))
        guard assertions != nil || configurations != nil else {
            database = nil
            databaseStatus = .noAccess
            updateDetection()
            return
        }
        let snapshot = FocusDatabase.parse(assertions: assertions, configurations: configurations)
        database = snapshot
        knownModes = snapshot.modes
        databaseStatus = .reading
        updateDetection()
    }

    /// Watches the folder (files replaced, added or removed) and each file (rewritten in place).
    private func startWatching() {
        guard let folder = databaseFolder, watcher == nil else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return } // no access: status stays "noAccess"
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                // A file may have been replaced: its watcher follows the new one.
                self?.watchFiles()
                self?.databaseChanged()
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
        watchFiles()
    }

    private func watchFiles() {
        fileWatchers.forEach { $0.cancel() }
        fileWatchers.removeAll()
        guard let folder = databaseFolder else { return }
        for name in [FocusDatabase.assertionsFile, FocusDatabase.configurationsFile] {
            let descriptor = open(folder.appendingPathComponent(name).path, O_EVTONLY)
            guard descriptor >= 0 else { continue } // not there (yet): the folder watcher sees it arrive
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                                   eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
                                                                   queue: .main)
            source.setEventHandler { [weak self, weak source] in
                let replaced = source.map { !$0.data.isDisjoint(with: [.rename, .delete, .revoke]) } ?? false
                MainActor.assumeIsolated {
                    if replaced { self?.watchFiles() }
                    self?.databaseChanged()
                }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            fileWatchers.append(source)
        }
    }

    /// A watcher fired: read once the burst of events has settled.
    private func databaseChanged() {
        settleTask?.cancel()
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.watcherSettle))
            guard !Task.isCancelled, let self else { return }
            self.settleTask = nil
            self.refreshDatabase()
        }
    }

    private func stopWatching() {
        watcher?.cancel()
        watcher = nil
        fileWatchers.forEach { $0.cancel() }
        fileWatchers.removeAll()
        settleTask?.cancel()
        settleTask = nil
    }
}
