import Foundation

/// The Shelf's settings. Names start with
/// `shelf.`.
extension Keys {
    /// Drop target, Shelf page and indicator. Off keeps the items for later.
    public static let shelfEnabled = SettingKey<Bool>("shelf.enabled", default: true)
    /// Compact indicator while the Shelf has items (shown only when no other live activity is).
    public static let shelfIndicator = SettingKey<Bool>("shelf.indicator", default: true)
    /// How dropped files are kept: a link to the original, or a copy in Lintel's Shelf folder.
    public static let shelfStorage = SettingKey<ShelfStorageMode>("shelf.storage", default: .reference)

    /// Prefix of the keys above; changes to them are handled by the Shelf.
    public static let shelfKeyPrefix = "shelf."
}
