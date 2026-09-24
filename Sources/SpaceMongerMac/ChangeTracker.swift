import CoreServices
import Foundation

/// Records which folders under a scan root change on disk, via FSEvents, so
/// Reload can re-read just those (`Scanner.rescan`) instead of the whole
/// drive. The original had nothing like it: every Rescan Drive re-read
/// everything, and was only faster the second time because Windows had the
/// directory data cached.
///
/// Started right before a scan begins, so a change made while the scan runs
/// is picked up by the next reload too. FSEvents reports directory-level
/// events with paths spelled through firmlinks (`/Users/…`, not
/// `/System/Volumes/Data/Users/…`), which is how the tree spells them.
final class ChangeTracker {
    let root: String

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "SpaceMonger.ChangeTracker")
    private let lock = NSLock()
    private var changes = Scanner.ChangeSet()

    /// Past this many distinct folders a full scan is simpler than patching.
    private static let maxTrackedFolders = 100_000

    init(root: String) {
        self.root = root
        // FSEvents only sees changes made through this Mac's kernel: edits
        // from other machines on a network volume never arrive, so for those
        // there is no stream and every reload is a full scan.
        var fs = statfs()
        guard statfs(root, &fs) == 0, fs.f_flags & UInt32(MNT_LOCAL) != 0 else { return }

        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let tracker = Unmanaged<ChangeTracker>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            tracker.record(list, Array(UnsafeBufferPointer(start: flags, count: count)))
        }
        stream = FSEventStreamCreate(
            nil, callback, &context, [root] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes
                                     | kFSEventStreamCreateFlagWatchRoot))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, queue)
            if !FSEventStreamStart(stream) {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                self.stream = nil
            }
        }
    }

    /// False on network volumes (and if FSEvents couldn't start): every
    /// reload is then a full scan.
    var canTrack: Bool { stream != nil }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func record(_ paths: [String], _ flags: [FSEventStreamEventFlags]) {
        let mustRescanAll = FSEventStreamEventFlags(kFSEventStreamEventFlagRootChanged
                                                    | kFSEventStreamEventFlagEventIdsWrapped)
        let subdirs = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        let mounts = FSEventStreamEventFlags(kFSEventStreamEventFlagMount
                                             | kFSEventStreamEventFlagUnmount)
        let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)

        lock.lock(); defer { lock.unlock() }
        for (path, f) in zip(paths, flags) {
            if f & historyDone != 0 { continue }
            if f & mustRescanAll != 0 {
                changes.full = true
            } else if f & subdirs != 0 {
                // Events were coalesced or dropped (user/kernel dropped comes
                // with this flag): everything below `path` is suspect.
                changes.deep.insert(path)
            } else if f & mounts != 0 {
                // A volume appeared or vanished at `path`: its parent's
                // listing (the mount point's status) changed.
                changes.shallow.insert((path as NSString).deletingLastPathComponent)
            } else {
                changes.shallow.insert(path)
            }
        }
        if changes.shallow.count + changes.deep.count > Self.maxTrackedFolders {
            changes = Scanner.ChangeSet(full: true)
        }
    }

    /// Everything recorded so far (after delivering pending events); the
    /// tracker then starts collecting afresh. Call off the main thread.
    func drain() -> Scanner.ChangeSet {
        guard let stream else { return Scanner.ChangeSet(full: true) }
        FSEventStreamFlushSync(stream)
        lock.lock(); defer { lock.unlock() }
        let taken = changes
        changes = Scanner.ChangeSet()
        return taken
    }

    /// Puts changes back, e.g. when the reload that drained them was cancelled.
    func restore(_ taken: Scanner.ChangeSet) {
        lock.lock(); defer { lock.unlock() }
        changes.merge(taken)
    }
}
