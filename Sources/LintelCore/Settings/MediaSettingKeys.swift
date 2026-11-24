import Foundation

/// Badge after the track title in the open player (`songTitleBadge`).
public enum MediaTitleBadge: String, SettingChoice {
    case none, explicit, format

    public var title: String {
        switch self {
        case .none: return "None"
        case .explicit: return "Explicit"
        case .format: return "Audio format"
        }
    }
}

/// Fill of the open player's progress bar (`progressStyle`; colours come from the artwork).
public enum MediaProgressStyle: String, SettingChoice {
    case mono, color, gradient

    public var title: String {
        switch self {
        case .mono: return "Grey"
        case .color: return "Artwork colour"
        case .gradient: return "Artwork blend"
        }
    }
}

/// The optional extra button on the left of the open player's controls (`controlChoice`).
public enum MediaExtraControl: String, SettingChoice {
    case favorite, shuffle, repeating, copyLink

    public var title: String {
        switch self {
        case .favorite: return "Favourite"
        case .shuffle: return "Shuffle"
        case .repeating: return "Repeat"
        case .copyLink: return "Copy link"
        }
    }
}

/// Where Now Playing comes from when not following the playing app automatically (`musicApp`).
public enum MediaSourceChoice: String, SettingChoice {
    case music, spotify, system

    public var title: String {
        switch self {
        case .music: return "Music"
        case .spotify: return "Spotify"
        case .system: return "System"
        }
    }
}

/// Now Playing settings. Quick Peek keys start with `peek.media`.
extension Keys {
    public static let mediaEnabled = SettingKey<Bool>("media.enabled", default: true)
    /// Seconds the activity stays after playback pauses (`idleDuration`, 3 s).
    public static let mediaIdleDuration = SettingKey<Double>("media.idleDuration", default: 3)
    public static let mediaTitleBadge = SettingKey<MediaTitleBadge>("media.titleBadge", default: .explicit)
    public static let mediaProgressStyle = SettingKey<MediaProgressStyle>("media.progressStyle", default: .mono)
    /// Live waveform from a Core Audio process tap (needs audio-capture permission).
    public static let mediaLiveWaveform = SettingKey<Bool>("media.liveWaveform", default: false)
    /// Internal: the audio-capture permission has been requested once.
    public static let mediaAudioCaptureRequested = SettingKey<Bool>("media.liveWaveform.requested", default: false)
    public static let mediaDisableCompactWaveform = SettingKey<Bool>("media.disableCompactWaveform", default: false)
    public static let mediaDisableArtworkFlip = SettingKey<Bool>("media.disableArtworkFlip", default: false)
    public static let mediaHideWhileSourceActive = SettingKey<Bool>("media.hideWhileSourceActive", default: false)
    public static let mediaStripTitleExtras = SettingKey<Bool>("media.stripTitleExtras", default: false)
    public static let mediaExtraControl = SettingKey<MediaExtraControl>("media.extraControl", default: .shuffle)
    /// Follow whichever app is playing (`automaticMusicApp`); the manual choice is ignored while on.
    public static let mediaAutomaticSource = SettingKey<Bool>("media.source.automatic", default: true)
    public static let mediaSource = SettingKey<MediaSourceChoice>("media.source", default: .system)
    /// Switch for the MediaRemote adapter (private capabilities can be turned off). Off leaves
    /// the AppleScript sources (Music, Spotify).
    public static let mediaSystemAdapter = SettingKey<Bool>("media.systemAdapter", default: true)
}
