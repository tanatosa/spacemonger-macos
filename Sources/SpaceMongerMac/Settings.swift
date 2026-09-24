import Foundation

/// Application settings, mirroring the original's `CCurrentSettings`
/// (`SpaceMonger.h`), persisted to `UserDefaults` instead of the registry.
/// Defaults and clamping follow `CCurrentSettings::Reset` / `Load`.
/// `density` ranges from -3 to +3 and selects one of seven minimum-tile sizes,
/// exactly like the original's `minsizes[]` table (default density 0 = 32x24).
final class Settings {
    static let shared = Settings()

    /// Minimum tile dimensions (horizontal, vertical) for each density level,
    /// indexed by `density + 3`. Matches the original's `minsizes[][2]`.
    static let minsizes: [(h: CGFloat, v: CGFloat)] = [
        (96, 64),   // density -3  (fewest tiles)
        (64, 48),   // density -2
        (48, 32),   // density -1
        (32, 24),   // density  0  (DEFAULT)
        (24, 16),   // density +1
        (16, 12),   // density +2
        (8, 6),     // density +3  (most tiles)
    ]

    private let defaults = UserDefaults.standard

    var density: Int {
        didSet {
            if density < -3 { density = -3 }
            if density > 3 { density = 3 }
            defaults.set(density, forKey: "density")
        }
    }

    /// Horizontal minimum tile width for the current density.
    var hmin: CGFloat { Settings.minsizes[density + 3].h }
    /// Vertical minimum tile height for the current density.
    var vmin: CGFloat { Settings.minsizes[density + 3].v }

    /// Split bias, the original's `m_settings.bias` (-20…+20, slider "Horz …
    /// Equal … Vert"): positive values split side by side more often (taller
    /// boxes), negative ones stack more often (wider boxes). 0 = even.
    var bias: Int {
        didSet {
            if bias > 20 { bias = 20 }
            if bias < -20 { bias = -20 }
            defaults.set(bias, forKey: "bias")
        }
    }

    /// Whether the "<Free Space>" tile is shown in the treemap (original's
    /// `showfreespace`; when off, the free-space entry's weight becomes 0 and
    /// it disappears from the layout, exactly like the original's SizeFolders).
    var showFreeSpace: Bool {
        didSet { defaults.set(showFreeSpace, forKey: "showFreeSpace") }
    }

    /// Size units: decimal (1 KB = 1000 B, what Finder shows since Mac OS X
    /// 10.6) or binary (1 KB = 1024 B, the original SpaceMonger's format).
    /// Same bytes either way; only the displayed numbers differ (~7% at GB).
    var decimalUnits: Bool {
        didSet { defaults.set(decimalUnits, forKey: "decimalUnits") }
    }

    /// Zoom animation, the original's `animated_zoom` extended with a
    /// smooth Core Animation style.
    enum ZoomAnimation: String, CaseIterable {
        case smooth, classic, off
    }

    var zoomAnimation: ZoomAnimation {
        didSet { defaults.set(zoomAnimation.rawValue, forKey: "zoomAnimation") }
    }

    // MARK: - Display colors (original: file_color / folder_color)

    /// Index into `Palette.schemeNames`: 0 = Rainbow (by depth), 1 = Windows
    /// Colors (3D face gray), 2… = one fixed color.
    var fileColor: Int {
        didSet {
            if !Palette.schemeNames.indices.contains(fileColor) { fileColor = 0 }
            defaults.set(fileColor, forKey: "fileColor")
        }
    }
    var folderColor: Int {
        didSet {
            if !Palette.schemeNames.indices.contains(folderColor) { folderColor = 0 }
            defaults.set(folderColor, forKey: "folderColor")
        }
    }

    // MARK: - Tooltips (original: show_name_tips, rollover_box, show_info_tips)

    /// Fields shown in the file-info tip (original `TIP_*` flags).
    struct InfoTipFields: OptionSet {
        let rawValue: Int
        static let path   = InfoTipFields(rawValue: 1)
        static let name   = InfoTipFields(rawValue: 2)
        static let icon   = InfoTipFields(rawValue: 4)
        static let date   = InfoTipFields(rawValue: 8)
        static let size   = InfoTipFields(rawValue: 16)
        static let attrib = InfoTipFields(rawValue: 32)
        static let all: InfoTipFields = [.path, .name, .icon, .date, .size, .attrib]
    }

    /// Show the full name over a tile whose label doesn't fit.
    var showNameTips: Bool {
        didSet { defaults.set(showNameTips, forKey: "showNameTips") }
    }
    /// Milliseconds before the name tip appears (0…99999).
    var nameTipDelay: Int {
        didSet {
            nameTipDelay = min(max(nameTipDelay, 0), 99_999)
            defaults.set(nameTipDelay, forKey: "nameTipDelay")
        }
    }
    /// Light up the hovered tile and its parent folders, dim the rest.
    var rolloverBox: Bool {
        didSet { defaults.set(rolloverBox, forKey: "rolloverBox") }
    }
    var showInfoTips: Bool {
        didSet { defaults.set(showInfoTips, forKey: "showInfoTips") }
    }
    var infoTipFields: InfoTipFields {
        didSet {
            infoTipFields = infoTipFields.intersection(.all)
            defaults.set(infoTipFields.rawValue, forKey: "infoTipFields")
        }
    }
    /// Milliseconds before the info tip appears (0…99999).
    var infoTipDelay: Int {
        didSet {
            infoTipDelay = min(max(infoTipDelay, 0), 99_999)
            defaults.set(infoTipDelay, forKey: "infoTipDelay")
        }
    }

    // MARK: - Miscellaneous (original: auto_rescan, disable_delete, save_pos)

    /// Rescan the whole drive after Move to Trash; otherwise the item is
    /// just removed from the map (original `CSpaceMonger::OnFileDelete`).
    var autoRescan: Bool {
        didSet { defaults.set(autoRescan, forKey: "autoRescan") }
    }
    /// Disable every Move to Trash command.
    var disableDelete: Bool {
        didSet { defaults.set(disableDelete, forKey: "disableDelete") }
    }
    /// Reopen the window where it was last closed.
    var savePosition: Bool {
        didSet { defaults.set(savePosition, forKey: "savePosition") }
    }

    private init() {
        // Local reference: the helpers can't touch `self` before init finishes.
        let store = UserDefaults.standard
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            store.object(forKey: key) as? Bool ?? fallback
        }
        func int(_ key: String, _ fallback: Int) -> Int {
            store.object(forKey: key) as? Int ?? fallback
        }
        density = defaults.integer(forKey: "density")  // defaults to 0 when unset
        bias = min(max(defaults.integer(forKey: "bias"), -20), 20)
        showFreeSpace = bool("showFreeSpace", true)
        decimalUnits = bool("decimalUnits", true)
        zoomAnimation = defaults.string(forKey: "zoomAnimation")
            .flatMap(ZoomAnimation.init(rawValue:)) ?? .smooth
        let schemes = Palette.schemeNames.indices
        fileColor = schemes.contains(int("fileColor", 0)) ? int("fileColor", 0) : 0
        folderColor = schemes.contains(int("folderColor", 0)) ? int("folderColor", 0) : 0
        // CCurrentSettings::Reset defaults.
        showNameTips = bool("showNameTips", true)
        nameTipDelay = min(max(int("nameTipDelay", 125), 0), 99_999)
        rolloverBox = bool("rolloverBox", false)
        showInfoTips = bool("showInfoTips", true)
        infoTipFields = InfoTipFields(rawValue: int("infoTipFields",
            InfoTipFields([.date, .size, .icon]).rawValue)).intersection(.all)
        infoTipDelay = min(max(int("infoTipDelay", 250), 0), 99_999)
        autoRescan = bool("autoRescan", false)
        disableDelete = bool("disableDelete", false)
        savePosition = bool("savePosition", false)
    }
}
