import Foundation
import LintelCore
import os
import Security

/// Lintel's unified-log categories, readable with
/// `log show --predicate 'subsystem == "com.sashagilliard.lintel"' --info`.
enum Log {
    static let subsystem = "com.sashagilliard.lintel"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hud = Logger(subsystem: subsystem, category: "hud")
    static let focus = Logger(subsystem: subsystem, category: "focus")
}

/// How the running copy is signed. macOS ties privacy permissions to the designated requirement: an
/// ad-hoc copy is identified by its cdhash, so each rebuild needs its permissions granted again,
/// while a certificate-signed copy keeps them (README › Signing).
struct SigningInfo: Sendable, CustomStringConvertible {
    var isAdHoc: Bool
    var teamIdentifier: String?
    var cdhash: String?
    /// Designated requirement as text (what macOS matches permissions against).
    var designatedRequirement: String?

    static let current: SigningInfo = read()

    var description: String {
        let hash = cdhash.map { String($0.prefix(12)) } ?? "?"
        if isAdHoc { return "ad-hoc signature (cdhash \(hash)…): permissions belong to this build only" }
        if let teamIdentifier { return "signed by team \(teamIdentifier) (cdhash \(hash)…)" }
        return "not signed"
    }

    private static func read() -> SigningInfo {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else {
            return SigningInfo(isAdHoc: false, teamIdentifier: nil, cdhash: nil, designatedRequirement: nil)
        }
        let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let unique = dictionary[kSecCodeInfoUnique as String] as? Data
        var requirement: SecRequirement?
        var requirementText: CFString?
        if SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement {
            _ = SecRequirementCopyString(requirement, [], &requirementText)
        }
        return SigningInfo(isAdHoc: flags & SecCodeSignatureFlags.adhoc.rawValue != 0,
                           teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
                           cdhash: unique.map { $0.map { String(format: "%02x", $0) }.joined() },
                           designatedRequirement: requirementText as String?)
    }
}

/// Records this copy's designated requirement at launch and notices when it differs from the copy
/// that ran last time: macOS keeps every permission for the signature it was granted to, so after a
/// change the switches in System Settings look on but don't apply (fixes record, 2026-11-22 HUD).
@MainActor
enum SignatureTracker {
    @discardableResult
    static func recordLaunch(settings: SettingsStore, signing: SigningInfo = .current) -> SignatureContinuity {
        let current = signing.designatedRequirement
        let continuity = SignatureContinuity.evaluate(previous: settings[Keys.lastDesignatedRequirement], current: current)
        switch continuity {
        case .changed(let previous):
            settings[Keys.signatureChangedFrom] = previous.requirement
            let now = current.map { SignatureIdentity(requirement: $0).summary } ?? "unknown"
            Log.app.notice("""
                Code signature changed since the last launch: was \(previous.summary, privacy: .public), now \(now, privacy: .public). \
                Permissions granted to the earlier copy (Accessibility, Full Disk Access, …) don't apply to this one, even where \
                System Settings shows them on, and toggling them keeps the old signature: remove Lintel from those lists (−) \
                and add this copy (+)
                """)
        case .same, .unknown:
            break
        }
        if let current, settings[Keys.lastDesignatedRequirement] != current {
            settings[Keys.lastDesignatedRequirement] = current
        }
        return continuity
    }
}
