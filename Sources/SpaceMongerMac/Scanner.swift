import Foundation

/// Recursively scans a folder tree, computing the byte size of every node.
///
/// Mirrors the original `CFolderTree` / `CFolder::LoadFolder` logic:
///   - hidden files are included (the original enumerates `*.*`),
///   - symlinks are skipped entirely, and so are the mount points of other
///     volumes (like the original skips junctions and mount points — they
///     never appear in the tree); macOS firmlinks (/Users, /Applications,
///     /usr/local, …) are ordinary directories, not mount points, and are
///     scanned, with device+inode identity guaranteeing single counting,
///   - a `.nofollow` marker *file* inside a folder prevents descending into it
///     (folder still appears, but empty, contributing no size),
///   - file sizes are the blocks allocated on disk (what `du` reports),
///   - empty folders contribute nothing (their size is the sum of children),
///   - each folder's entries are sorted by size descending as soon as it has
///     been read, like `LoadFolder` calling `CFolder::Finalize` at its end,
///   - a synthetic free-space entry is appended to the root (`CFolderTree::LoadTree`).
///
/// Performance mirrors the original's single-pass `FindFirstFile` enumeration,
/// taken further: each directory is read with `getattrlistbulk`, which returns
/// name, type, flags, dates, mount status and both sizes for many entries per
/// syscall (no per-entry stat, no URL resource-value lookups), and sibling
/// subdirectories are scanned in parallel.
final class Scanner {
    struct VolumeInfo {
        let clusterSize: Int64
        let totalSpace: Int64
        let freeSpace: Int64
    }

    /// Progress snapshot for the scan dialog (original CFolderDialog state).
    struct ScanProgress {
        let path: String
        let files: Int
        let folders: Int
        /// Share of the expected bytes found so far, 0…1; negative when there
        /// is no meaningful total (a folder rather than a whole volume).
        let fraction: Double
    }

    /// Called periodically on a background queue, throttled to at most one call
    /// per 200 ms like the original's `CFolderDialog::UpdateDisplay`, with the
    /// fraction of used space discovered (the original's `filespace /
    /// usedspace`, measured per volume — see `progressTotal`).
    var onProgress: ((ScanProgress) -> Void)?

    private let cancelLock = NSLock()
    private var _cancelled = false
    var isCancelled: Bool {
        cancelLock.lock(); defer { cancelLock.unlock() }; return _cancelled
    }
    func cancel() {
        cancelLock.lock(); _cancelled = true; cancelLock.unlock()
    }

    private(set) var volume = VolumeInfo(clusterSize: 4096, totalSpace: 0, freeSpace: 0)

    /// Identity of a directory on disk (device + inode). Firmlinks such as
    /// /Users and /System/Volumes/Data/Users share one identity, so this is
    /// what keeps every byte of the data volume counted exactly once no matter
    /// which path reaches it first.
    private struct DirID: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    /// Guards everything below that worker threads share: counters, progress
    /// state, `visitedDirs` and `errors`. Taken once per directory, not per file.
    private let stateLock = NSLock()

    /// Directories already descended into (see `DirID`).
    private var visitedDirs = Set<DirID>()

    /// The path the scan started at: the one mount root we are allowed to enter.
    private var rootPath = ""

    /// True when the scan root is a whole volume (so free space is meaningful).
    private var isVolumeRoot = false

    private var fileCount = 0
    private var folderCount = 0
    private var currentPath = ""
    private var scannedBytes: Int64 = 0
    /// The progress bar's 100%: the used space of every volume the scan has
    /// entered so far. Not the container's: on APFS `statfs` reports the whole
    /// container, whose "used" includes volumes a scan never reaches (Preboot,
    /// VM, Update) — measured at 244 GB vs. 229 GB for System + Data, which
    /// capped the bar at ~82%. Firmlinks lead from the System volume into the
    /// Data volume, so both are counted (see `countVolumesUpFront`).
    private var progressTotal: Int64 = 0
    /// Mount points of the volumes in `progressTotal`. Keyed by mount path,
    /// not `st_dev`: through a firmlink the Data volume reports the System
    /// volume's device number (APFS keeps the two volumes' inode numbers in
    /// separate ranges instead, so (dev, ino) stays unique for `visitedDirs`).
    private var countedVolumes = Set<String>()
    private var lastReport = Date.distantPast

    /// Enumeration failures seen during the scan (e.g. TCC "operation not
    /// permitted"), capped so a huge tree can't balloon the array. Surfaced
    /// by the UI when a scan comes back empty — without this, a permission-
    /// denied scan is indistinguishable from an empty folder and the treemap
    /// renders nothing but the free-space tile.
    private(set) var errors: [String] = []
    private static let maxRecordedErrors = 20

    /// Marker file name: a `.nofollow` file inside a folder excludes that
    /// folder's contents from the scan (the folder itself is kept, empty).
    private static let noFollowMarker = ".nofollow"

    /// A file counts as sparse when at least this many bytes of its length are
    /// holes (never written, no blocks allocated). Smaller gaps are just normal
    /// allocation slack and not worth flagging.
    static let sparseThreshold: Int64 = 1 << 20

    /// Recursively scan `url`, returning the root node with sizes filled in,
    /// or nil if the scan was cancelled.
    func scan(_ url: URL) -> Node? {
        begin(url)
        var root = Node(name: url.lastPathComponent, url: url, isDirectory: true)
        root.modificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
        scanDirectory(&root, path: rootPath)
        if isCancelled { return nil }

        appendFreeSpace(to: &root, url: url)
        sortChildren(&root)   // place the free-space tile; everything else is sorted
        stateLock.lock(); reportProgress(); stateLock.unlock()
        return root
    }

    /// Resets per-scan state and reads the volume, for `scan` and `rescan`.
    private func begin(_ url: URL) {
        fileCount = 0
        folderCount = 0
        scannedBytes = 0
        errors.removeAll()
        lastReport = Date()
        cancelLock.lock(); _cancelled = false; cancelLock.unlock()

        volume = volumeInfo(url.path)
        rootPath = Self.canonicalPath(url.path)
        isVolumeRoot = (mountPoint(url.path) == rootPath)
        visitedDirs.removeAll()
        progressTotal = 0
        countedVolumes.removeAll()
        if isVolumeRoot { countVolumesUpFront() }
    }

    /// Adds up, before the scan starts, the used space of every volume it
    /// will cross, so the bar's total is right from the first update (adding
    /// each volume only when the scan first entered it let the small System
    /// volume fill the bar within a second). The root's own volume, plus
    /// whatever its top-level folders lead into — on macOS the firmlinks
    /// /Users, /Applications, /Library, /private… all lead into the Data
    /// volume. Mount points and symlinks among them are skipped, as the scan
    /// skips them — so no deeper folder can lead into another volume.
    private func countVolumesUpFront() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) ?? []
        for path in [rootPath] + names.map({ Self.join(rootPath, $0) }) {
            let isRoot = path == rootPath
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | (isRoot ? 0 : O_NOFOLLOW))
            guard fd >= 0 else { continue }
            defer { close(fd) }
            var fs = statfs()
            guard fstatfs(fd, &fs) == 0 else { continue }
            let mount = withUnsafeBytes(of: &fs.f_mntonname) { raw in
                String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if !isRoot && mount == path { continue }   // another volume mounted here
            if countedVolumes.insert(mount).inserted {
                progressTotal += Self.volumeUsedBytes(fd: fd)
            }
        }
    }

    /// Add the free-space entry to the root (original: AddFile "<<<<…").
    /// Only when a whole volume was scanned: the original only ever scans
    /// drive roots, and for a subfolder the volume's free space would be
    /// orders of magnitude bigger than the folder, leaving one giant gray
    /// tile with the actual contents squeezed into a sliver.
    private func appendFreeSpace(to root: inout Node, url: URL) {
        // Network shares often report no capacity at all (WebDAV: 0 total,
        // 0 free); a "0 B free" tile and caption would only mislead.
        guard isVolumeRoot, volume.totalSpace > 0 else { return }
        var free = Node(name: "<Free Space>", url: url, isDirectory: false)
        free.isFreeSpace = true
        free.size = volume.freeSpace
        free.freeStats = FreeSpaceStats(totalSpace: volume.totalSpace,
                                        freeSpace: volume.freeSpace,
                                        files: fileCount, folders: folderCount)
        root.children.append(free)
        // NB: the root's own `size` stays the scanned (used) total; the layout
        // weighs the free-space tile from the children list, so adding it here
        // would only make the status line report free space as used space.
    }

    // MARK: - Incremental rescan

    /// What changed on disk since a scan (collected by `ChangeTracker`).
    struct ChangeSet {
        /// Folders whose own entries changed: read them again, but keep
        /// their unchanged subfolders from the previous scan.
        var shallow = Set<String>()
        /// Folders to scan again completely, everything below included.
        var deep = Set<String>()
        /// The changes can't be trusted (events dropped, root moved, network
        /// volume): scan everything.
        var full = false

        mutating func merge(_ other: ChangeSet) {
            shallow.formUnion(other.shallow)
            deep.formUnion(other.deep)
            full = full || other.full
        }
    }

    /// Folders read from disk by the last `rescan` (for the status line).
    private(set) var rescannedFolders = 0

    // Marks for the running rescan (paths as the tree spells them).
    private var shallowMarks = Set<String>()
    private var deepMarks = Set<String>()
    /// Every marked folder plus all its ancestors: the only paths `rescan`
    /// walks into. Everything else is reused from the old tree untouched.
    private var pathsToVisit = Set<String>()

    /// Brings `oldRoot` (a previous result of `scan` / `rescan` of the same
    /// folder) up to date by reading only the changed folders; the original
    /// had no equivalent and always rescanned everything. Nil if cancelled.
    func rescan(_ oldRoot: Node, changes: ChangeSet) -> Node? {
        if changes.full { return scan(oldRoot.url) }
        begin(oldRoot.url)

        var root = oldRoot
        root.children.removeAll { $0.isFreeSpace }   // re-added with fresh volume stats

        shallowMarks = Set(changes.shallow.compactMap { resolve($0, in: root) })
        deepMarks = Set(changes.deep.compactMap { resolve($0, in: root) })
        // FSEvents reports a file's content change only when it is closed, so
        // files held open and written for hours — VM disks (Docker.raw),
        // databases, logs — never show up. They are also the big tiles, so
        // re-read every folder holding a large file on each reload.
        Self.collectFoldersWithLargeFiles(root, path: rootPath, into: &shallowMarks)
        pathsToVisit = []
        for mark in shallowMarks.union(deepMarks) {
            var p = mark
            while pathsToVisit.insert(p).inserted, p != rootPath {
                p = (p as NSString).deletingLastPathComponent
            }
        }
        if !pathsToVisit.isEmpty { updateDirectory(&root, path: rootPath) }
        if isCancelled { return nil }

        rescannedFolders = folderCount
        (fileCount, folderCount) = Self.counts(root)
        appendFreeSpace(to: &root, url: oldRoot.url)
        sortChildren(&root)
        stateLock.lock(); reportProgress(); stateLock.unlock()
        return root
    }

    /// The deepest folder of the tree on the way to `path`: the folder
    /// itself, or — for a folder that no longer exists, is new, or sits in a
    /// skipped mount — the nearest ancestor the tree knows. Re-reading that
    /// ancestor picks up the addition or removal. Nil if outside the root.
    private func resolve(_ path: String, in root: Node) -> String? {
        let p = Self.canonicalPath(path)
        if p == rootPath { return rootPath }
        let prefix = rootPath == "/" ? "/" : rootPath + "/"
        guard p.hasPrefix(prefix) else { return nil }
        var node = root
        var resolved = rootPath
        for component in p.dropFirst(prefix.count).split(separator: "/") {
            guard let child = node.children.first(where: {
                $0.isDirectory && !$0.isFreeSpace && $0.name == component
            }) else { break }
            node = child
            resolved = Self.join(resolved, child.name)
        }
        return resolved
    }

    private static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    /// Updates `node` (at `path`, which is in `pathsToVisit`) in place.
    private func updateDirectory(_ node: inout Node, path: String) {
        if isCancelled { return }

        if deepMarks.contains(path) {
            var fresh = Node(name: node.name, url: node.url, isDirectory: true)
            fresh.modificationDate = node.modificationDate
            scanDirectory(&fresh, path: path)
            node = fresh
            return
        }

        if shallowMarks.contains(path) {
            // Re-read this folder: files come fresh from the listing, known
            // subfolders keep their old contents, new ones get a full scan.
            guard let listing = listDirectory(path), !listing.hasNoFollowMarker else {
                node.children = []
                node.size = 0
                node.logicalSize = 0
                return
            }
            var known: [String: Node] = [:]
            for c in node.children where c.isDirectory { known[c.name] = c }
            var subdirs: [Node] = []
            for (i, listed) in listing.subdirs.enumerated() {
                let childPath = listing.subdirPaths[i]
                if var kept = known[listed.name] {
                    kept.modificationDate = listed.modificationDate
                    if pathsToVisit.contains(childPath) { updateDirectory(&kept, path: childPath) }
                    subdirs.append(kept)
                } else {
                    var fresh = listed
                    scanDirectory(&fresh, path: childPath)
                    subdirs.append(fresh)
                }
            }
            node.children = listing.files + subdirs
        } else {
            // Unchanged itself, but something below it changed.
            for i in node.children.indices where node.children[i].isDirectory {
                let childPath = Self.join(path, node.children[i].name)
                if pathsToVisit.contains(childPath) { updateDirectory(&node.children[i], path: childPath) }
            }
        }

        node.size = node.children.reduce(0) { $0 + $1.size }
        node.logicalSize = node.children.reduce(0) { $0 + $1.logicalSize }
        sortChildren(&node)
    }

    /// Files at least this big have their folder re-read on every reload.
    static let largeFileThreshold: Int64 = 16 << 20

    private static func collectFoldersWithLargeFiles(_ node: Node, path: String,
                                                     into marks: inout Set<String>) {
        for c in node.children where !c.isFreeSpace {
            if c.isDirectory {
                collectFoldersWithLargeFiles(c, path: join(path, c.name), into: &marks)
            } else if c.size >= largeFileThreshold || c.logicalSize >= largeFileThreshold {
                marks.insert(path)
            }
        }
    }

    /// Files and folders in a tree (folders include the root), for the
    /// free-space caption after a rescan.
    private static func counts(_ node: Node) -> (files: Int, folders: Int) {
        var files = 0, folders = 1
        for c in node.children where !c.isFreeSpace {
            if c.isDirectory {
                let sub = counts(c)
                files += sub.files; folders += sub.folders
            } else {
                files += 1
            }
        }
        return (files, folders)
    }

    /// Caller holds `stateLock`.
    private func recordError(_ message: String) {
        guard errors.count < Self.maxRecordedErrors else { return }
        errors.append(message)
    }

    private func recordErrorLocked(_ message: String) {
        stateLock.lock(); recordError(message); stateLock.unlock()
    }

    /// Caller holds `stateLock`.
    private func reportProgress() {
        onProgress?(ScanProgress(path: currentPath, files: fileCount,
                                 folders: folderCount, fraction: progressFraction))
    }

    /// Caller holds `stateLock`.
    private var progressFraction: Double {
        guard isVolumeRoot, progressTotal > 0 else { return -1 }
        return min(Double(scannedBytes) / Double(progressTotal), 1.0)
    }

    /// Bytes in use on the volume holding `fd` — what `df` shows per volume:
    /// `ATTR_VOL_SPACEUSED` on APFS, where `statfs` only knows the container;
    /// blocks minus free blocks elsewhere (HFS+, exFAT, …), where it's exact.
    private static func volumeUsedBytes(fd: Int32) -> Int64 {
        var fs = statfs()
        guard fstatfs(fd, &fs) == 0 else { return 0 }
        let fallback = Int64(fs.f_blocks - fs.f_bfree) * Int64(fs.f_bsize)
        let mount = withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        var attrs = attrlist()
        attrs.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrs.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        attrs.volattr = attrgroup_t(ATTR_VOL_INFO) | attrgroup_t(ATTR_VOL_SPACEUSED)
        // u_int32_t length, attribute_set_t returned, off_t spaceused
        var buffer = [UInt8](repeating: 0, count: 64)
        let ok = buffer.withUnsafeMutableBytes { raw -> Int64? in
            guard getattrlist(mount, &attrs, raw.baseAddress, raw.count, 0) == 0 else { return nil }
            let base = raw.baseAddress!
            let returned = (base + 4).loadUnaligned(as: attribute_set_t.self)
            guard returned.volattr & attrgroup_t(ATTR_VOL_SPACEUSED) != 0 else { return nil }
            return (base + 4 + MemoryLayout<attribute_set_t>.size).loadUnaligned(as: Int64.self)
        }
        return ok ?? fallback
    }

    // MARK: - Directory enumeration

    /// Attributes fetched per entry. Order in the returned record follows the
    /// bit order within each group (common, dir, file), with ATTR_CMN_ERROR
    /// directly after the returned-attributes set — see getattrlistbulk(2).
    private static var bulkAttrs: attrlist = {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
            | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME)
            | attrgroup_t(ATTR_CMN_FLAGS)
        a.dirattr = attrgroup_t(ATTR_DIR_MOUNTSTATUS)
        a.fileattr = attrgroup_t(ATTR_FILE_TOTALSIZE) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        return a
    }()

    private static let bulkBufferSize = 256 * 1024

    /// One directory's entries: files (complete nodes) and subdirectories
    /// (empty nodes still to be scanned), from a single bulk read.
    private struct Listing {
        var files: [Node] = []
        var subdirs: [Node] = []
        var subdirPaths: [String] = []
        var hasNoFollowMarker = false
    }

    /// Reads the entries of the directory at `path`. Nil when it can't be
    /// opened or was already visited under another name (firmlink).
    private func listDirectory(_ path: String) -> Listing? {
        if isCancelled { return nil }

        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            recordErrorLocked("\(path): \(String(cString: strerror(errno)))")
            return nil
        }
        defer { close(fd) }

        // Count a physical directory once. Firmlinks (/Users, /usr/local, …)
        // are extra names for directories that also live under
        // /System/Volumes/Data, so without this the same tree could be added
        // twice when two names for it are reachable from the scan root.
        // fstat on the opened fd sees the firmlink's *target* identity.
        var st = stat()
        stateLock.lock()
        if fstat(fd, &st) == 0,
           !visitedDirs.insert(DirID(dev: st.st_dev, ino: st.st_ino)).inserted {
            stateLock.unlock()
            return nil
        }
        folderCount += 1
        stateLock.unlock()

        let prefix = path == "/" ? "/" : path + "/"
        var listing = Listing()

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bulkBufferSize, alignment: 8)
        defer { buffer.deallocate() }
        var attrs = Self.bulkAttrs

        while true {
            let count = getattrlistbulk(fd, &attrs, buffer, Self.bulkBufferSize, 0)
            if count < 0 {
                recordErrorLocked("\(path): \(String(cString: strerror(errno)))")
                break
            }
            if count == 0 { break }

            var entry = buffer
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var field = entry + MemoryLayout<UInt32>.size
                let returned = field.loadUnaligned(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                var entryError: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_ERROR) != 0 {
                    entryError = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var name = ""
                if returned.commonattr & attrgroup_t(ATTR_CMN_NAME) != 0 {
                    let ref = field.loadUnaligned(as: attrreference_t.self)
                    name = String(cString: (field + Int(ref.attr_dataoffset))
                        .assumingMemoryBound(to: CChar.self))
                    field += MemoryLayout<attrreference_t>.size
                }
                var objType: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_OBJTYPE) != 0 {
                    objType = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var modDate: Date?
                if returned.commonattr & attrgroup_t(ATTR_CMN_MODTIME) != 0 {
                    let ts = field.loadUnaligned(as: timespec.self)
                    modDate = Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9)
                    field += MemoryLayout<timespec>.size
                }
                var flags: UInt32 = 0
                if returned.commonattr & attrgroup_t(ATTR_CMN_FLAGS) != 0 {
                    flags = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var mountStatus: UInt32 = 0
                if returned.dirattr & attrgroup_t(ATTR_DIR_MOUNTSTATUS) != 0 {
                    mountStatus = field.loadUnaligned(as: UInt32.self)
                    field += MemoryLayout<UInt32>.size
                }
                var logical: Int64 = 0
                var allocated: Int64?
                if returned.fileattr & attrgroup_t(ATTR_FILE_TOTALSIZE) != 0 {
                    logical = field.loadUnaligned(as: Int64.self)
                    field += MemoryLayout<Int64>.size
                }
                if returned.fileattr & attrgroup_t(ATTR_FILE_ALLOCSIZE) != 0 {
                    allocated = field.loadUnaligned(as: Int64.self)
                    field += MemoryLayout<Int64>.size
                }

                if entryError != 0 {
                    recordErrorLocked("\(prefix)\(name): \(String(cString: strerror(Int32(entryError))))")
                    continue
                }
                guard !name.isEmpty else { continue }

                // Skip symlinks entirely, like the original skips reparse points
                // (junctions, mount points, symbolic links): they never enter the tree.
                if objType == VLNK.rawValue { continue }

                if objType == VDIR.rawValue {
                    // Skip other volumes' mount points (and autofs triggers), the
                    // macOS analog of the junction / mount-point reparse points
                    // the original never descends into: /dev, /Volumes/OtherDisk,
                    // /System/Volumes/Data, … Firmlinked directories are *not*
                    // mount points, so /Users, /Applications, /Library and
                    // friends are scanned normally. The scan root itself is
                    // never an entry here, so it is always entered.
                    let mountFlags = UInt32(DIR_MNTSTATUS_MNTPOINT) | UInt32(DIR_MNTSTATUS_TRIGGER)
                    if mountStatus & mountFlags != 0 { continue }
                    let childPath = prefix + name
                    var child = Node(name: name, url: URL(fileURLWithPath: childPath, isDirectory: true),
                                     isDirectory: true)
                    child.modificationDate = modDate
                    listing.subdirs.append(child)
                    listing.subdirPaths.append(childPath)
                    continue
                }

                // A `.nofollow` marker *file* means "do not descend": the folder
                // stays in the tree as an empty leaf, like a skipped mount. Only
                // a plain file counts — macOS ships an empty `/.nofollow`
                // *directory* on the system volume (handled above as a normal
                // directory), and treating that as a marker aborted every scan
                // of "/" before it read a single entry. The marker itself is an
                // instruction, not content — never show it.
                if name == Self.noFollowMarker {
                    listing.hasNoFollowMarker = true
                    continue
                }

                var file = Node(name: name, url: URL(fileURLWithPath: prefix + name, isDirectory: false),
                                isDirectory: false)
                file.modificationDate = modDate
                file.logicalSize = logical
                // The file's disk footprint: the blocks actually allocated
                // (what `du` reports). On APFS, sparse files and clones make
                // the logical size wildly larger than the space used, which
                // inflated the tree past the volume's own capacity. Fall back
                // to the original's rule — logical size rounded up to the
                // cluster size, "the smallest the file can get" — only when
                // the file system doesn't report an allocation.
                if let allocated {
                    file.size = allocated
                } else {
                    let cluster = max(volume.clusterSize, 1)
                    file.size = ((logical + cluster - 1) / cluster) * cluster
                }
                // Sparse = holes that were never written. Compressed and
                // dataless (evicted iCloud) files also allocate less than
                // their length, but for a different reason — don't flag them.
                let notSparse = UInt32(UF_COMPRESSED) | UInt32(SF_DATALESS)
                file.isSparse = objType == VREG.rawValue && flags & notSparse == 0
                    && logical - file.size >= Self.sparseThreshold
                listing.files.append(file)
            }
        }
        return listing
    }

    /// Scans the directory at `path` into `node` (children, size, logicalSize).
    /// Safe to call concurrently for distinct nodes.
    private func scanDirectory(_ node: inout Node, path: String) {
        guard let listing = listDirectory(path), !listing.hasNoFollowMarker else { return }
        let files = listing.files
        var subdirs = listing.subdirs
        let subdirPaths = listing.subdirPaths

        // Sibling subtrees are independent, so scan them in parallel. Nested
        // concurrentPerform calls share GCD's width, so this doesn't explode
        // into one thread per directory.
        if subdirs.count > 1 {
            subdirs.withUnsafeMutableBufferPointer { buf in
                let base = buf.baseAddress!
                DispatchQueue.concurrentPerform(iterations: buf.count) { i in
                    scanDirectory(&base[i], path: subdirPaths[i])
                }
            }
        } else if subdirs.count == 1 {
            scanDirectory(&subdirs[0], path: subdirPaths[0])
        }

        var size: Int64 = 0, logicalSize: Int64 = 0, fileBytes: Int64 = 0
        for f in files { fileBytes += f.size; logicalSize += f.logicalSize }
        size = fileBytes
        for d in subdirs { size += d.size; logicalSize += d.logicalSize }
        node.children = files + subdirs
        node.size = size
        node.logicalSize = logicalSize
        // Sort here, on the scanning thread, like the original's LoadFolder
        // ending in Finalize(). A separate pass over 2 M+ entries after the
        // scan left the progress bar frozen at the end — ~50 s in a debug
        // (`swift build`) binary, where the radix sort isn't optimized.
        sortChildren(&node)

        stateLock.lock()
        fileCount += files.count
        scannedBytes += fileBytes
        currentPath = path
        let now = Date()
        if now.timeIntervalSince(lastReport) >= 0.2 {
            lastReport = now
            reportProgress()
        }
        stateLock.unlock()
    }

    // MARK: - Volumes

    /// Cluster size, mount point, and total/free space, like `GetDiskFreeSpace`
    /// + `GetDiskFreeSpaceEx` in the original's `CFolderTree::GetSpace`.
    private func volumeInfo(_ path: String) -> VolumeInfo {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else {
            return VolumeInfo(clusterSize: 4096, totalSpace: 0, freeSpace: 0)
        }
        let bsize = Int64(fs.f_bsize)
        return VolumeInfo(clusterSize: max(bsize, 1),
                          totalSpace: Int64(fs.f_blocks) * bsize,
                          // f_bfree matches the original's lpTotalNumberOfFreeBytes
                          freeSpace: Int64(fs.f_bfree) * bsize)
    }

    /// The mount point a path lives on (f_mntonname), used to detect mounts.
    private func mountPoint(_ path: String) -> String {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return "" }
        return withUnsafeBytes(of: &fs.f_mntonname) { raw in
            String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Trailing slashes removed so paths compare equal to f_mntonname.
    private static func canonicalPath(_ path: String) -> String {
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Sorts a folder's children by size descending, stably, using eight passes
    /// of an 8-bit counting radix sort — a direct port of `CFolder::Finalize`
    /// (which, like this, sorts one folder's entries).
    private func sortChildren(_ node: inout Node) {
        guard node.children.count > 1 else { return }
        let copy = node.children
        let order = countingRadixSortDescending(copy.count) { UInt64(bitPattern: copy[$0].size) }
        node.children = order.map { copy[$0] }
    }
}
