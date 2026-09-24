import Foundation

/// Data model for a file or folder. `children` is populated only for folders.
///
/// A struct (rather than a class) keeps the tree packed: each folder stores its
/// entries as contiguous value arrays, and copy-on-write means navigation stacks
/// and views share the same storage instead of duplicating it. This mirrors the
/// original's "packed arrays / half the memory" memory-manager design.
struct Node {
    let name: String
    let url: URL
    var isDirectory: Bool
    /// Bytes allocated on disk (what `du` reports). For a folder, the sum of all
    /// descendants. This is what tiles are sized by.
    var size: Int64 = 0
    /// Content length in bytes — the headline "Size" in Finder's Get Info. For
    /// a folder, the sum of all descendants.
    var logicalSize: Int64 = 0
    /// A file whose length includes large holes that take no disk space
    /// (see `Scanner.sparseThreshold`), so Finder reports far more than it uses.
    var isSparse: Bool = false
    /// File modification time (used to draw the date on tiles).
    var modificationDate: Date?
    var children: [Node] = []
    /// Synthetic "free space" entry appended to the scan root (original appends
    /// "<<<<<<<<<<<<<<<<<<<<" to the root folder in CFolderTree::LoadTree).
    var isFreeSpace: Bool = false

    /// Volume stats attached to the free-space entry so the renderer can draw
    /// the original's free-space caption (free %, free size, file/folder counts).
    var freeStats: FreeSpaceStats?

    init(name: String, url: URL, isDirectory: Bool) {
        self.name = name
        self.url = url
        self.isDirectory = isDirectory
    }

    var isLeaf: Bool { !isDirectory || children.isEmpty }

    /// Human-readable sizes.
    var sizeString: String { Format.bytes(size) }
}

/// Scan totals for the volume, kept on the synthetic free-space entry
/// (the original draws them as the tile's caption instead of its name).
struct FreeSpaceStats {
    let totalSpace: Int64
    let freeSpace: Int64
    let files: Int
    let folders: Int
}

enum Format {
    /// Format a byte count as B/KB/MB/GB/TB with one decimal for large units.
    /// Decimal (1 KB = 1000 B, like Finder) or binary (1 KB = 1024 B, like the
    /// original SpaceMonger and `du -h`) depending on `Settings.decimalUnits`.
    static func bytes(_ n: Int64) -> String {
        bytes(n, decimal: Settings.shared.decimalUnits)
    }

    static func bytes(_ n: Int64, decimal: Bool) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        let base: Double = decimal ? 1000 : 1024
        var value = Double(n)
        var i = 0
        while value >= base, i < units.count - 1 {
            value /= base
            i += 1
        }
        if i == 0 { return "\(Int(value)) \(units[i])" }
        return String(format: "%.1f %@", value, units[i])
    }
}