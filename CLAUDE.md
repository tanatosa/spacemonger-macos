# CLAUDE.md

Guidance for AI coding agents working in this repository.

## Repository layout

This repository is **SpaceMongerMac**, a Swift/AppKit port of **SpaceMonger
1.4.0**, the Windows MFC/C++ app by Sean Werkema (1998-2000). The original's
source is not in this repo: it lives at
<https://github.com/seanofw/spacemonger1> (root folder). Comments and this file
cite it by file and function (`FolderView.cpp`, `CFolder::Finalize`, …) — read
it there to learn *intended behaviour*. It does not build on macOS.

## Build & run

```bash
swift build                       # debug build
swift run                         # launch the app
swift build -c release && ./.build/release/SpaceMongerMac
./make-release.sh                     # universal SpaceMonger.app + zip in dist/, ad-hoc signed
swift run SpaceMongerMac /some/path   # scan a folder straight away, no picker
```

There is no test target. `.build/`, `.swiftpm/` and `dist/` are gitignored.
`.github/workflows/release.yml` runs `make-release.sh` on `v*` tags and
publishes a GitHub Release (ad-hoc signed; see README for the Gatekeeper note).
The app is **not sandboxed** (only `get-task-allow`), so it can read the whole
disk except paths blocked by TCC (Desktop/Documents/Downloads prompts,
`.Spotlight-V100`, etc.). Enumeration failures are collected in
`Scanner.errors`, not swallowed.

## Port architecture (and its Windows ancestor)

| macOS file | Role | Original counterpart |
|---|---|---|
| `Models.swift` | `Node` value tree (COW structs), `Format.bytes` (decimal/binary units) | `CFolder` packed arrays |
| `Scanner.swift` | Parallel `getattrlistbulk` scan, incremental `rescan`, sizes, sparse detection, volume info, progress | `CFolderTree::LoadTree`, `CFolder::LoadFolder` |
| `ChangeTracker.swift` | FSEvents stream recording changed folders since a scan, for Reload | — (original always rescanned everything) |
| `TreemapLayout.swift` | Greedy balanced binary-split treemap + radix sort | `CFolderView::SizeFolders`, `EightBitCountingSort` |
| `TreemapView.swift` | `NSView` drawing, hit-testing, labels, sparse badge, rollover boxes, name/info tips, zoom animations (`AnimateBox`) | `CFolderView` |
| `TipWindow.swift` | Borderless child window for name and info tips | `CTipWnd` |
| `MainWindowController.swift` | Window, button bar, title, navigation, context menu, file actions, Properties | `CMainFrame` |
| `DriveDialog.swift` | Volume picker; Connect to Server… (NetFS mount of SMB/AFP/NFS/WebDAV) | `CDriveDialog` (drive letters, incl. mapped network drives) |
| `ScanDialog.swift` | Progress panel | `CFolderDialog` (`IDD_SCAN_DIALOG`) |
| `Settings.swift` | All options (layout, colors, tips, misc, units, zoom), `UserDefaults` | `CCurrentSettings` (registry) |
| `SettingsDialog.swift` | Settings sheet (no language selector) | `CSettingsDialog` (`IDD_SETTINGS`) |
| `Palette.swift` | `BoxColors` / `FixedColors` schemes (fill, bright, dark) | `MinimalDrawDisplayFolder` colors |
| `Resources/AppIcon.png` | App icon, loaded via `Bundle.module` | `res/SpaceMonger.ico` (upscaled 16× nearest-neighbor) |

The port deliberately mirrors the original's algorithms (balanced split rather
than squarified, 8-bit counting radix sort descending, title-bar inset of
`x+3, w-6`, top `folderTitleBarHeight` (15, vs. the original's 12) + bottom 3, density table `minsizes[]` indexed by `density + 3`). When
changing layout or sorting, check the C++ first and keep the comment that cites
it.

## macOS filesystem pitfalls (these caused real bugs — do not regress)

The Windows original scans a drive letter and skips reparse points. The macOS
equivalent is subtler; `Scanner.swift` must keep all of the following:

1. **`/.nofollow` exists on macOS.** The port supports a `.nofollow` marker that
   stops descent into a folder, but macOS ships an empty `/.nofollow`
   *directory* on the system volume. Only a **non-directory** entry may count
   as the marker (directories are handled before the name check), otherwise every scan of `/` returns an empty
   tree instantly and the treemap renders nothing but the free-space tile.
2. **Firmlinks are not mount points.** `/Users`, `/Applications`, `/Library`,
   `/usr/local`, … report `f_mntonname == /System/Volumes/Data` but are ordinary
   directories. Only skip **foreign mount roots** — entries whose
   `ATTR_DIR_MOUNTSTATUS` has `DIR_MNTSTATUS_MNTPOINT` (or `_TRIGGER`, autofs).
   The scan root is never an entry, so it is always entered. That drops `/dev`,
   `/Volumes/Other`, `/System/Volumes/Data`, while the data volume is still reached exactly once
   through the firmlinks. Any "one mount = one visit" rule silently deletes
   hundreds of GB from the scan.
3. **De-duplicate directories by device+inode.** A firmlink and its target share
   `(st_dev, st_ino)`, so the `visitedDirs` set makes single-counting
   order-independent. Take the identity from `fstat` on the *opened* directory
   fd, so it is the directory actually entered, whichever name reached it.
4. **Use allocated size, not logical size.** APFS sparse files and clones make
   logical size up to ~2× the real disk usage — enough to exceed the volume's
   capacity. Size tiles by `ATTR_FILE_ALLOCSIZE` (matches `du`); fall back to
   the original's cluster-rounding rule only when the attribute isn't
   returned. An allocation of 0 is real (empty, or an evicted iCloud file), not
   "unavailable". The logical size (`ATTR_FILE_TOTALSIZE`) is kept in
   `Node.logicalSize` only for display — it is Finder's Get Info number. A file
   is flagged `isSparse` only if it isn't compressed (`UF_COMPRESSED`) or
   dataless (`SF_DATALESS`), which also allocate less than their length.
5. **Free space belongs to volume scans only.** The synthetic `<Free Space>`
   node is appended only when the scan root is a mount root; on a subfolder the
   volume's free space dwarfs everything into slivers. Its size is *not* added
   to the root's `size` (the root's size is the scanned/used total; the layout
   weighs the tile from the children list).

6. **Scanning is parallel.** Sibling subdirectories are scanned with
   `DispatchQueue.concurrentPerform`, so shared state (counters, `errors`,
   `visitedDirs`, progress) lives behind `stateLock`, taken once per directory.
   Don't replace this with `async` + `DispatchGroup.wait()` per directory: the
   blocked waits use up GCD's thread pool and the scan hangs.

7. **Incremental Reload relies on FSEvents, which misses held-open files.**
   A content change is reported only when the file is *closed*, so VM disks
   (`Docker.raw`), databases and logs written for hours produce no event.
   `rescan` therefore also re-reads every folder holding a file ≥
   `largeFileThreshold` (16 MB) on each reload. Any change to `rescan` must
   still produce a tree identical to a fresh `scan` (compare node by node,
   sorted order included). Paths from FSEvents come through firmlinks
   (`/Users/…`) like the tree's; unknown paths resolve to their nearest known
   ancestor, which is re-read. Network volumes (no `MNT_LOCAL`) have no
   tracker, so every reload is a full scan.
8. **Through a firmlink, the Data volume reports the System volume's
   `st_dev`.** `(st_dev, st_ino)` is still unique (APFS keeps System-volume
   inodes in their own range, near 2⁶⁰), so `visitedDirs` is fine, but never
   use `st_dev` alone to tell volumes apart — key them by mount path
   (`f_mntonname`), as `countVolumesUpFront` does.
9. **Progress is measured per volume.** `statfs` on APFS reports the whole
   container, whose "used" includes Preboot/VM/Update, so the bar's total is
   the `ATTR_VOL_SPACEUSED` of the volumes the scan crosses (the root's plus
   those its top-level folders lead into), summed *before* the scan starts.
   Unreadable folders still keep it short of 100% (~87% on `/`); `ScanDialog`
   animates on stalls and `finish()` fills it, like `ForcedUpdate`.
10. **Sort each folder as it is read** (`sortChildren` at the end of
   `scanDirectory`, like `LoadFolder` → `Finalize`), never in a pass after the
   scan: in a debug build that pass took ~50 s on `/` with the bar frozen.
   Debug builds scan about 2× slower overall — time things with `-O`.

11. **Network volumes.** They scan like local ones (`getattrlistbulk` works
   on SMB/AFP/NFS/WebDAV), but: many report no capacity (WebDAV via
   `mount_webdav`: 0 total, 0 free) — then there is no `<Free Space>` tile,
   the drive list says "Size unknown", and the progress bar animates; there
   is no `ChangeTracker` stream (`canTrack == false`), so Reload is a full
   rescan; and NetFS reports mounting an already-mounted WebDAV share as a
   generic `-6600`, not `EEXIST` — `DriveDialog.mount` therefore looks for an
   existing mount of that server after any failure.

## Verifying scanner changes without the GUI

`Scanner` lives in an executable target, so there is nothing to `import`. The
fastest check is a throwaway harness:

```bash
mkdir /tmp/smtest && cd /tmp/smtest
cp <repo>/Sources/SpaceMongerMac/{Scanner,Models,TreemapLayout,Settings}.swift .
# add a main.swift that calls Scanner().scan(URL(...)) and buildLayout(...)
swiftc -O -o harness *.swift && ./harness /some/path
```

Useful ground truths:

- `du -sh <path>` must match the reported size (allocated bytes).
- `df -h <volume>` used/avail must match root size and the `<Free Space>` node.
- A scratch volume gives an exact, fast check:
  `hdiutil create -size 30m -fs APFS -volname SMTest smtest.dmg && hdiutil attach smtest.dmg`.
- Scanning `/` should yield ~20+ children including `Users`, `Library`,
  `Applications`, `private`, `System`, and take tens of seconds (≈45 s for
  2.2 M entries on an M-series Mac) — an instant result means the scan aborted.
- A real network volume, no server needed: serve a scratch folder with
  WebDAV (`python3 -m venv v && v/bin/pip install wsgidav cheroot`, run
  `v/bin/wsgidav` with an anonymous config on 127.0.0.1) and mount it with
  `mount_webdav -S http://127.0.0.1:<port>/ <dir>` (reports 0 capacity) or
  `DriveDialog.mount` (NetFS; reports the host disk's; can take a minute).
- Drawing can be checked offscreen the same way: add `Palette`, `TreemapView`,
  `MainWindowController`, `ScanDialog`, `DriveDialog` to the harness (not
  `AppDelegate`, which needs `Bundle.module`) and save `cacheDisplay` output
  to a PNG.

## Conventions

- Comments explain *why*, and cite the original (`FolderView.cpp`,
  `CFolder::Finalize`, …) when a rule is inherited from it. Keep these when
  editing nearby code.
- `TreemapView` is **not flipped** (origin bottom-left, y grows upward), while
  the original's GDI code is top-down. When porting a `y+n` offset, "top" is
  `maxY`: title-bar names go at `rect.maxY - 1 - textHeight`, and multi-line
  labels stack by *decreasing* y. Mixing this up drew folder names under their
  children and printed label lines in reverse order.
- Drawing code must guard against non-finite / degenerate rects before touching
  `NSBezierPath` — `insetBy` on a thin rect returns `CGRect.null` whose origin
  is infinite and raises an `NSException`. `CGRect.isNull/isEmpty` do **not**
  catch NaN; check components explicitly.
- `Node` is a struct on purpose (packed, copy-on-write) — mirrors the original's
  memory-manager design. Don't turn it into a class for convenience.
- Scanning runs on a background queue; all UI mutation goes through
  `DispatchQueue.main.async`. Progress callbacks are throttled to 200 ms like
  `CFolderDialog::UpdateDisplay`.
- Settings are clamped in `didSet` (`density` ±3, `bias` ±20 like
  `CCurrentSettings::Load`) and persisted to `UserDefaults`; defaults follow
  `CCurrentSettings::Reset`. The density popup maps index `n` to
  `density = n - 3`. Tips are custom `TipWindow`s driven by a tracking area,
  not `NSView` tooltips, because the original's delays and fields are settings.

## Docs to update with behaviour changes

`README.md` (features, file table, differences from the original) — it is the
project's GitHub page. Regenerate `docs/screenshot.png` from generic demo data
(never a real disk: it would publish file names), rendered offscreen as
described above.
