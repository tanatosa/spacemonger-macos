import AppKit

/// The main application window: a toolbar/status bar plus the treemap view.
final class MainWindowController: NSWindowController, NSMenuItemValidation {

    let treemap = TreemapView()

    // MARK: - State
    private let scanner = Scanner()
    private var scanRoot: Node?
    private var displayedRoot: Node?
    private var navStack: [Node] = []
    /// Watches the scanned folder for changes since the scan started, so
    /// Reload only re-reads what changed (see `ChangeTracker`).
    private var changeTracker: ChangeTracker?

    // MARK: - Buttons & UI
    private let openButton = MainWindowController.symbolButton("Open", "internaldrive")
    private let reloadButton = MainWindowController.symbolButton("Reload", "arrow.clockwise")
    private let zoomInButton = MainWindowController.symbolButton("Zoom In", "plus.magnifyingglass")
    private let zoomOutButton = MainWindowController.symbolButton("Zoom Out", "minus.magnifyingglass")
    private let fullButton = MainWindowController.symbolButton("Zoom Full", "magnifyingglass")
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)
    private let trashButton = NSButton(title: "Move to Trash", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let freeSpaceButton = NSButton(checkboxWithTitle: "Show Free Space", target: nil, action: nil)
    private let settingsButton = MainWindowController.symbolButton("Settings", "gearshape")
    private let unitsPopup = NSPopUpButton()
    private let unitsHelpButton = NSButton()
    private var unitsHelpPopover: NSPopover?
    private let statusLabel = NSTextField(labelWithString: "Choose a folder to scan.")

    /// Shown on the units pop-up and the matching View menu item.
    static let unitsHelp = """
        Size units. Only the displayed numbers change; the bytes are the same.

        Decimal (default): 1 KB = 1,000 bytes, 1 GB = 1,000,000,000 bytes. \
        This is what Finder has used since Mac OS X 10.6, so sizes line up \
        with Get Info and the Finder status bar.

        Binary: 1 KB = 1,024 bytes, 1 GB = 1,073,741,824 bytes. This is the \
        original SpaceMonger's format, also used by du -h and most Terminal \
        tools.

        Why it matters: the same size reads about 7% smaller in binary at GB \
        scale (10% at TB), so without this setting a folder looks smaller \
        here than in Finder even when both agree on the bytes.
        """

    /// Toolbar button with an SF Symbol before its title.
    private static func symbolButton(_ title: String, _ symbol: String) -> NSButton {
        let b = NSButton(title: title, target: nil, action: nil)
        b.bezelStyle = .rounded
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            b.image = image
            b.imagePosition = .imageLeading
        }
        return b
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 560, height: 420)
        super.init(window: window)
        // Original save_pos: reopen where the window was last closed.
        let restored = Settings.shared.savePosition && window.setFrameUsingName(Self.frameName)
        applyWindowPositionSetting()
        defer { if !restored { fitWindowToToolbar() } }

        treemap.translatesAutoresizingMaskIntoConstraints = false
        treemap.onZoomIn = { [weak self] node in self?.zoomIn(to: node) }
        treemap.onSelection = { [weak self] node in self?.selectionChanged(node) }
        treemap.contextMenuProvider = { [weak self] node in self?.contextMenu(for: node) }

        wireButtons()
        buildUnitsControl()
        buildLayout(in: window)
        updateButtons()
        updateTitle()
    }

    // MARK: - Settings

    private static let frameName = "SpaceMongerMainWindow"

    /// Settings dialog (original: ID_SETTINGS → CSettingsDialog).
    @objc func openSettings(_ sender: Any?) {
        guard let window, window.attachedSheet == nil else { return }
        SettingsDialog.run(on: window) { [weak self] in self?.settingsApplied() }
    }

    /// Original: after the dialog, CFolderView::OnUpdate re-lays out and
    /// redraws with the new density, bias, colors and tip options.
    private func settingsApplied() {
        treemap.settingsChanged()
        applyWindowPositionSetting()
        updateButtons()
    }

    private func applyWindowPositionSetting() {
        guard let window else { return }
        if Settings.shared.savePosition {
            window.setFrameAutosaveName(Self.frameName)   // also saves the current frame
        } else {
            window.setFrameAutosaveName("")
            NSWindow.removeFrame(usingName: Self.frameName)
        }
    }

    private func buildUnitsControl() {
        unitsPopup.removeAllItems()
        unitsPopup.addItems(withTitles: ["KB = 1000", "KB = 1024"])   // details in the tooltip
        unitsPopup.toolTip = Self.unitsHelp
        unitsPopup.target = self
        unitsPopup.action = #selector(unitsChanged(_:))
        syncUnitsControl()

        // Round "?" button: same text on hover, and as a popover on click
        // (tooltips alone are easy to miss and vanish when the mouse moves).
        unitsHelpButton.bezelStyle = .helpButton
        unitsHelpButton.title = ""
        unitsHelpButton.controlSize = .small
        unitsHelpButton.toolTip = Self.unitsHelp
        unitsHelpButton.target = self
        unitsHelpButton.action = #selector(showUnitsHelp(_:))
    }

    @objc private func showUnitsHelp(_ sender: NSButton) {
        if let open = unitsHelpPopover, open.isShown {
            open.performClose(sender)
            return
        }
        let text = NSTextField(wrappingLabelWithString: Self.unitsHelp)
        text.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        text.preferredMaxLayoutWidth = 340
        text.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            text.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            text.widthAnchor.constraint(equalToConstant: 340),
        ])
        let vc = NSViewController()
        vc.view = container
        let popover = NSPopover()
        popover.contentViewController = vc
        popover.behavior = .transient
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY)
        unitsHelpPopover = popover
    }

    private func syncUnitsControl() {
        unitsPopup.selectItem(at: Settings.shared.decimalUnits ? 0 : 1)
    }

    @objc private func unitsChanged(_ sender: Any?) {
        setDecimalUnits(unitsPopup.indexOfSelectedItem == 0)
    }

    @objc func toggleDecimalUnits(_ sender: Any?) {
        setDecimalUnits(!Settings.shared.decimalUnits)
    }

    private func setDecimalUnits(_ decimal: Bool) {
        Settings.shared.decimalUnits = decimal
        syncUnitsControl()
        // Every label, tooltip and status line goes through Format.bytes.
        treemap.needsDisplay = true
        selectionChanged(treemap.selectedNode)
        if treemap.selectedNode == nil, let root = displayedRoot, navStack.isEmpty {
            statusLabel.stringValue = summary(for: root)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func wireButtons() {
        openButton.target = self
        openButton.action = #selector(openFolder(_:))
        openButton.toolTip = "Choose a drive to scan"
        reloadButton.target = self
        reloadButton.action = #selector(reload(_:))
        reloadButton.toolTip = "Update the map: re-reads only the folders that changed since the last scan, and keeps the current zoom"

        zoomInButton.target = self
        zoomInButton.action = #selector(doZoomIn(_:))
        zoomOutButton.target = self
        zoomOutButton.action = #selector(doZoomOut(_:))
        fullButton.target = self
        fullButton.action = #selector(doFull(_:))
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        trashButton.target = self
        trashButton.action = #selector(trash(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancelScan(_:))
        freeSpaceButton.target = self
        freeSpaceButton.action = #selector(freeSpaceCheckboxChanged(_:))
        freeSpaceButton.state = Settings.shared.showFreeSpace ? .on : .off
        settingsButton.target = self
        settingsButton.action = #selector(openSettings(_:))
        settingsButton.toolTip = "Layout, colors, tooltips and other options"
        cancelButton.isEnabled = false
    }

    private func buildLayout(in window: NSWindow) {
        let content = window.contentView!
        content.addSubview(treemap)

        let controls = [openButton, reloadButton, zoomInButton, zoomOutButton, fullButton,
                        revealButton, trashButton, cancelButton, freeSpaceButton,
                        unitsPopup, unitsHelpButton, settingsButton, statusLabel]
        let bar = NSStackView(views: controls)
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.distribution = .fill
        bar.setCustomSpacing(2, after: unitsPopup)   // keep the "?" with its pop-up
        bar.setCustomSpacing(14, after: unitsHelpButton)
        // Only the status text may take up spare width. Buttons default to
        // the same low hugging priority as the label (250), which left the
        // stack free to stretch any of them: the first layout after a
        // restored window frame widened Open to ~250 pt, and the next resize
        // shrank it back.
        for control in controls where control !== statusLabel {
            control.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        }
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Truncate the status text rather than forcing the window wider.
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(separator)
        content.addSubview(bar)

        NSLayoutConstraint.activate([
            treemap.topAnchor.constraint(equalTo: content.topAnchor),
            treemap.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            treemap.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            separator.topAnchor.constraint(equalTo: treemap.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            bar.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 10),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -10),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8)
        ])
    }

    /// Open wide enough for the whole button bar (status text excluded, it
    /// truncates), so no control starts out clipped.
    private func fitWindowToToolbar() {
        guard let window, let content = window.contentView,
              let bar = content.subviews.compactMap({ $0 as? NSStackView }).first else { return }
        let needed = bar.arrangedSubviews.filter { $0 !== statusLabel }
            .reduce(CGFloat(0)) { $0 + $1.fittingSize.width + bar.spacing } + 20 + 120
        // …but never wider than the screen it opens on.
        let screenWidth = (window.screen ?? NSScreen.main)?.visibleFrame.width ?? needed
        let width = min(needed, screenWidth - 40)
        if content.frame.width < width {
            window.setContentSize(NSSize(width: width, height: content.frame.height))
        }
        window.center()
    }

    // MARK: - Title

    /// Window title, a port of the original's `CFolderView::UpdateTitleBar`.
    ///
    /// With a selection: its path, its share of the drive and its size —
    /// `path - 12.3% - 1.2 GB - SpaceMonger`. Without one: the folder on
    /// screen, its total and the drive's free space — `path - 20 GB total -
    /// 5 GB free - SpaceMonger`, where at the top level "total" is the drive's
    /// capacity (the original's "Kludge": `size = ft->totalspace`) and when
    /// zoomed it is the folder's size. Zoomed views keep a "Zoomed:" prefix.
    private func updateTitle() {
        guard let root = scanRoot, let shown = displayedRoot else {
            window?.title = "SpaceMonger"
            return
        }
        // Drive totals come from the free-space entry; a folder scan, or a
        // share that reports no capacity, has none.
        let volume = root.children.first(where: { $0.isFreeSpace })?.freeStats
        var parts: [String]
        if let sel = treemap.selectedNode, !sel.isFreeSpace, sel.url != shown.url {
            // Percent of the drive (the original's GetSizeString(size,
            // totalspace, 1)); for a folder scan, of the scanned folder.
            let whole = volume?.totalSpace ?? root.size
            parts = [sel.url.path]
            if whole > 0 { parts.append(String(format: "%.1f%%", Double(sel.size) / Double(whole) * 100)) }
            parts.append(sel.sizeString)
        } else {
            let atTop = navStack.isEmpty
            let total = atTop ? (volume?.totalSpace ?? root.size) : shown.size
            parts = [(atTop ? "" : "Zoomed: ") + shown.url.path, "\(Format.bytes(total)) total"]
            if let volume { parts.append("\(Format.bytes(volume.freeSpace)) free") }
        }
        window?.title = (parts + ["SpaceMonger"]).joined(separator: "  -  ")
    }

    // MARK: - Scanning

    @objc func openFolder(_ sender: Any?) {
        // Drive picker, port of the original's CDriveDialog: choose a mounted
        // volume; Cancel (nil) does nothing, exactly like EndDialog(-1).
        guard let url = DriveDialog.selectDrive() else { return }
        scan(url)
    }

    /// Scan the current root again from scratch and return to the full view —
    /// exactly the original's ID_FILE_REFRESH "Rescan Drive".
    @objc func fullRescan(_ sender: Any?) {
        guard let root = scanRoot else { return }
        scan(root.url)
    }

    /// Reload: bring the map up to date by re-reading only the folders that
    /// changed since the last scan, keeping the current zoom.
    @objc func reload(_ sender: Any?) {
        runRescan(folder: nil)
    }

    /// Reload This Folder: scan the chosen folder (right-clicked or selected,
    /// else the one on screen) again completely, keeping the zoom.
    @objc func reloadFolder(_ sender: Any?) {
        runRescan(folder: reloadTarget())
    }

    private func reloadTarget() -> Node? {
        if let n = treemap.selectedNode, n.isDirectory, !n.isFreeSpace { return n }
        return displayedRoot
    }

    private var isBusy: Bool { !openButton.isEnabled }

    private func setBusy(_ busy: Bool) {
        openButton.isEnabled = !busy
        cancelButton.isEnabled = busy
        updateButtons()
    }

    /// Incremental update of the current tree (`Scanner.rescan`). Tracked
    /// changes are always applied; `folder` adds a complete rescan of it.
    private func runRescan(folder: Node?) {
        guard let oldRoot = scanRoot, !isBusy else { return }
        let tracker = changeTracker
        let started = Date()
        setBusy(true)
        statusLabel.stringValue = folder.map { "Reloading \($0.name)…" } ?? "Reloading…"
        scanner.onProgress = { [weak self] p in
            DispatchQueue.main.async { self?.ScanDialog_update(p) }
        }
        // Most reloads finish in well under a second: only show the progress
        // window if this one doesn't, so it doesn't flash.
        let showDialog = DispatchWorkItem { [weak self] in
            ScanDialog.shared.show(path: folder?.url.path ?? oldRoot.url.path, indeterminate: true)
            ScanDialog.shared.onCancel = { [weak self] in self?.cancelScan(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: showDialog)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var changes = tracker?.drain() ?? Scanner.ChangeSet(full: true)
            if let folder { changes.deep.insert(folder.url.path) }
            let newRoot = self.scanner.rescan(oldRoot, changes: changes)
            let reread = self.scanner.rescannedFolders
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                showDialog.cancel()
                if newRoot != nil { ScanDialog.shared.finish() } else { ScanDialog.shared.close() }
                self.setBusy(false)
                guard let newRoot else {
                    tracker?.restore(changes)   // not applied: keep them for next time
                    self.statusLabel.stringValue = "Reload cancelled."
                    return
                }
                self.adopt(newRoot)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                let what: String
                if tracker?.canTrack == false {
                    // FSEvents only sees this Mac's own changes, not other
                    // machines' edits to a network share.
                    what = "network volume: full rescan"
                } else if changes.full {
                    what = "full rescan"
                } else {
                    what = "\(reread) folder\(reread == 1 ? "" : "s") re-read"
                }
                self.statusLabel.stringValue = "Reloaded in \(seconds) s (\(what)) — " + self.summary(for: newRoot)
            }
        }
    }

    /// Installs an updated tree while keeping the zoom: the displayed folder
    /// and zoom stack are value copies of the old tree, so each is looked up
    /// again (by path) in the new one; a folder that vanished drops the zoom
    /// back to its nearest surviving ancestor.
    private func adopt(_ root: Node) {
        scanRoot = root
        let oldStack = navStack + (displayedRoot.map { [$0] } ?? [])
        var stack: [Node] = []
        for old in oldStack {
            guard let found = Self.find(old.url, in: root) else { break }
            stack.append(found)
        }
        let shown = stack.popLast() ?? root
        navStack = shown.url == root.url ? [] : stack
        displayedRoot = shown
        treemap.show(shown, transition: nil)
        updateButtons()
        updateTitle()
    }

    func scan(_ url: URL) {
        statusLabel.stringValue = "Scanning \(url.path)…"
        setBusy(true)
        // Start watching before reading anything, so changes made while the
        // scan runs are picked up by the next Reload too.
        let tracker = ChangeTracker(root: url.path)
        ScanDialog.shared.show(path: url.path)
        ScanDialog.shared.onCancel = { [weak self] in self?.cancelScan(nil) }
        scanner.onProgress = { [weak self] p in
            DispatchQueue.main.async {
                self?.ScanDialog_update(p)
            }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let root = self.scanner.scan(url)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if root != nil { ScanDialog.shared.finish() } else { ScanDialog.shared.close() }
                self.setBusy(false)
                if let root = root {
                    // A cancelled scan keeps the previous tree and its tracker.
                    self.changeTracker = tracker
                    self.finishScan(root: root)
                    // A result holding nothing but the free-space entry means
                    // nothing readable was enumerated — explain why instead
                    // of rendering a lone free-space tile (the silent TCC
                    // permission-denial failure mode).
                    if root.children.allSatisfy({ $0.isFreeSpace || $0.size == 0 }) {
                        let detail = self.scanner.errors.first
                            ?? "no readable entries under \(url.path)"
                        self.statusLabel.stringValue =
                            "Scan found no files — \(detail)"
                    }
                } else {
                    self.statusLabel.stringValue = "Scan cancelled."
                }
            }
        }
    }

    private func ScanDialog_update(_ p: Scanner.ScanProgress) {
        ScanDialog.shared.update(path: p.path, files: p.files,
                                 folders: p.folders, fraction: p.fraction)
    }

    @objc private func cancelScan(_ sender: Any?) {
        scanner.cancel()
        statusLabel.stringValue = "Cancelling scan…"
    }

    @objc private func freeSpaceCheckboxChanged(_ sender: Any?) {
        setShowFreeSpace(freeSpaceButton.state == .on)
    }

    @objc func toggleFreeSpace(_ sender: Any?) {
        setShowFreeSpace(!Settings.shared.showFreeSpace)
    }

    private func setShowFreeSpace(_ on: Bool) {
        Settings.shared.showFreeSpace = on
        freeSpaceButton.state = on ? .on : .off
        treemap.needsLayout = true
    }

    private func finishScan(root: Node) {
        scanRoot = root
        displayedRoot = root
        navStack.removeAll()
        treemap.clearSelection()
        treemap.show(root, transition: nil)
        statusLabel.stringValue = summary(for: root)
        updateButtons()
        updateTitle()
    }

    /// "<used> used in <path> • <free> free — N items" for a scan root.
    private func summary(for root: Node) -> String {
        var text = "\(root.sizeString) in \(root.url.path)"
        if let stats = root.children.first(where: { $0.isFreeSpace })?.freeStats {
            text += " • \(Format.bytes(stats.freeSpace)) free"
        }
        return text + " — \(flattenedCount(root)) items"
    }

    private func flattenedCount(_ node: Node) -> Int {
        node.children.reduce(0) { $0 + flattenedCount($1) } + max(node.children.count, 0)
    }

    // MARK: - Zoom & navigation

    @objc func doZoomIn(_ sender: Any?) {
        guard let n = treemap.selectedNode, n.isDirectory, !n.isLeaf else { return }
        zoomIn(to: n)
    }

    private func zoomIn(to node: Node) {
        guard let current = displayedRoot, current.url != node.url else { return }
        navStack.append(current)
        displayedRoot = node
        treemap.show(node, transition: .zoomIn)
        statusLabel.stringValue = "\(node.name) — \(node.sizeString)"
        updateButtons()
        updateTitle()
    }

    @objc func doZoomOut(_ sender: Any?) {
        guard let previous = navStack.popLast() else { return }
        displayedRoot = previous
        treemap.show(previous, transition: .zoomOut)
        statusLabel.stringValue = "\(previous.name) — \(previous.sizeString)"
        updateButtons()
        updateTitle()
    }

    @objc func doFull(_ sender: Any?) {
        guard let root = scanRoot, !navStack.isEmpty else { return }
        navStack.removeAll()
        displayedRoot = root
        treemap.show(root, transition: .zoomOut)
        statusLabel.stringValue = summary(for: root)
        updateButtons()
        updateTitle()
    }

    @objc func setZoomAnimation(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let style = Settings.ZoomAnimation(rawValue: raw) else { return }
        Settings.shared.zoomAnimation = style
    }

    /// A real file or folder (the synthetic free-space tile's URL is the scan
    /// root itself, so file actions on it would hit the whole volume/folder).
    private func actionable(_ node: Node?) -> Node? {
        guard let node, !node.isFreeSpace else { return nil }
        return node
    }

    private func canZoomIn(_ node: Node?) -> Bool {
        guard let node else { return false }
        return node.isDirectory && !node.isLeaf && displayedRoot?.url != node.url
    }

    private func updateButtons() {
        let n = treemap.selectedNode
        // Original: ID_FILE_REFRESH is enabled whenever something is open.
        reloadButton.isEnabled = scanRoot != nil && !isBusy
        zoomInButton.isEnabled = canZoomIn(n)
        zoomOutButton.isEnabled = !navStack.isEmpty
        fullButton.isEnabled = !navStack.isEmpty
        revealButton.isEnabled = actionable(n) != nil
        trashButton.isEnabled = canTrash(n)
        // View options only mean something once there is a map to show.
        freeSpaceButton.isEnabled = scanRoot != nil
        unitsPopup.isEnabled = scanRoot != nil
    }

    /// Move to Trash is allowed for real items unless Settings disables it
    /// (original disable_delete).
    private func canTrash(_ node: Node?) -> Bool {
        actionable(node) != nil && !Settings.shared.disableDelete
    }

    /// Keep button states in sync whenever the selection changes.
    private func selectionChanged(_ node: Node?) {
        if let node = node {
            var text = "\(node.name) — \(node.sizeString)"
            if node.isSparse { text += " on disk (sparse; Finder shows \(Format.bytes(node.logicalSize)))" }
            statusLabel.stringValue = text
        } else if let d = displayedRoot {
            statusLabel.stringValue = "\(d.name) — \(d.sizeString)"
        }
        updateButtons()
        updateTitle()   // original: SelectFolder → UpdateTitleBar
    }

    // MARK: - Context menu

    /// Port of the original's tile popup menu (`CFolderView::OnRButtonUp`):
    /// zoom commands, open / delete, drive commands, then properties. Reveal
    /// in Finder is a macOS addition.
    private func contextMenu(for node: Node?) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let file = actionable(node)

        func add(_ title: String, _ action: Selector, enabled: Bool, state: Bool = false) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.isEnabled = enabled
            item.state = state ? .on : .off
            menu.addItem(item)
        }

        add("Zoom In", #selector(doZoomIn(_:)), enabled: canZoomIn(node))
        add("Zoom Out", #selector(doZoomOut(_:)), enabled: !navStack.isEmpty)
        add("Zoom Full", #selector(doFull(_:)), enabled: !navStack.isEmpty)
        menu.addItem(.separator())
        add("Open", #selector(openSelected(_:)), enabled: file != nil)
        add("Reveal in Finder", #selector(reveal(_:)), enabled: file != nil)
        add("Move to Trash…", #selector(trash(_:)), enabled: canTrash(node))
        menu.addItem(.separator())
        add("Open Drive…", #selector(openFolder(_:)), enabled: openButton.isEnabled)
        let canReload = scanRoot != nil && !isBusy
        add("Reload", #selector(reload(_:)), enabled: canReload)
        let target = node.flatMap { $0.isDirectory && !$0.isFreeSpace ? $0 : nil } ?? displayedRoot
        add("Reload “\(target?.name ?? "Folder")”", #selector(reloadFolder(_:)), enabled: canReload)
        add("Full Rescan", #selector(fullRescan(_:)), enabled: canReload)
        add("Show Free Space", #selector(toggleFreeSpace(_:)), enabled: scanRoot != nil,
            state: Settings.shared.showFreeSpace)
        menu.addItem(.separator())
        add("Properties…", #selector(showProperties(_:)), enabled: node != nil || displayedRoot != nil)
        return menu
    }

    // MARK: - Menu validation (main menu bar)

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(doZoomIn(_:)): return canZoomIn(treemap.selectedNode)
        case #selector(doZoomOut(_:)), #selector(doFull(_:)): return !navStack.isEmpty
        case #selector(reveal(_:)), #selector(openSelected(_:)):
            return actionable(treemap.selectedNode) != nil
        case #selector(trash(_:)): return canTrash(treemap.selectedNode)
        case #selector(reload(_:)), #selector(fullRescan(_:)):
            return scanRoot != nil && !isBusy
        case #selector(reloadFolder(_:)):
            if let target = reloadTarget() { item.title = "Reload “\(target.name)”" }
            return scanRoot != nil && !isBusy
        case #selector(openFolder(_:)): return openButton.isEnabled
        case #selector(showProperties(_:)): return treemap.selectedNode != nil || displayedRoot != nil
        case #selector(toggleFreeSpace(_:)):
            item.state = Settings.shared.showFreeSpace ? .on : .off
            return scanRoot != nil
        case #selector(toggleDecimalUnits(_:)):
            item.state = Settings.shared.decimalUnits ? .on : .off
            return scanRoot != nil
        case #selector(setZoomAnimation(_:)):
            item.state = (item.representedObject as? String) == Settings.shared.zoomAnimation.rawValue
                ? .on : .off
        default: break
        }
        return true
    }

    // MARK: - File actions

    /// Open the file with its default app (original: ID_FILE_RUN).
    @objc func openSelected(_ sender: Any?) {
        guard let node = actionable(treemap.selectedNode) else { return }
        NSWorkspace.shared.open(node.url)
    }

    @objc func reveal(_ sender: Any?) {
        guard let node = actionable(treemap.selectedNode) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }

    @objc func trash(_ sender: Any?) {
        guard canTrash(treemap.selectedNode), let node = treemap.selectedNode else { return }
        let alert = NSAlert()
        alert.messageText = "Move to Trash?"
        alert.informativeText = "“\(node.name)” (\(node.sizeString)) will be moved to the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try FileManager.default.trashItem(at: node.url, resultingItemURL: nil)
                self?.itemTrashed(node)
            } catch {
                let err = NSAlert()
                err.messageText = "Could not move item to Trash."
                err.informativeText = error.localizedDescription
                err.beginSheetModal(for: self!.window!)
            }
        }
    }

    /// After a successful Move to Trash (original CSpaceMonger::OnFileDelete):
    /// reload when Auto Rescan is on (incrementally — the tracker saw the
    /// move), otherwise take the item out of the tree and subtract its size
    /// from every folder above it.
    private func itemTrashed(_ node: Node) {
        if Settings.shared.autoRescan {
            reload(nil)
            return
        }
        guard var root = scanRoot, Self.remove(node.url, from: &root) else { return }
        treemap.clearSelection()
        adopt(root)
        statusLabel.stringValue = "Moved “\(node.name)” to the Trash — \(node.sizeString) freed"
    }

    /// Removes the node at `url` below `node`, subtracting its sizes from
    /// every folder on the way down. Returns false if it wasn't found.
    private static func remove(_ url: URL, from node: inout Node) -> Bool {
        if let i = node.children.firstIndex(where: { $0.url == url && !$0.isFreeSpace }) {
            let gone = node.children.remove(at: i)
            node.size -= gone.size
            node.logicalSize -= gone.logicalSize
            return true
        }
        let path = url.standardizedFileURL.path
        for i in node.children.indices where node.children[i].isDirectory {
            let dir = node.children[i].url.standardizedFileURL.path
            guard path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") else { continue }
            let before = (node.children[i].size, node.children[i].logicalSize)
            guard remove(url, from: &node.children[i]) else { return false }
            node.size -= before.0 - node.children[i].size
            node.logicalSize -= before.1 - node.children[i].logicalSize
            return true
        }
        return false
    }

    private static func find(_ url: URL, in node: Node) -> Node? {
        if node.url == url && !node.isFreeSpace { return node }
        let path = url.standardizedFileURL.path
        for c in node.children where c.isDirectory {
            let dir = c.url.standardizedFileURL.path
            if dir == path || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/") {
                return find(url, in: c)
            }
        }
        return nil
    }

    /// Properties sheet (original: ID_FILE_PROPERTIES) for the selection, or
    /// the displayed folder when nothing is selected. Shows both the on-disk
    /// size SpaceMonger uses and the size Finder's Get Info reports.
    @objc func showProperties(_ sender: Any?) {
        guard let node = treemap.selectedNode ?? displayedRoot, let window else { return }
        let exact = NumberFormatter()
        exact.numberStyle = .decimal
        func both(_ n: Int64) -> String {
            "\(Format.bytes(n)) (\(exact.string(from: NSNumber(value: n)) ?? "\(n)") bytes)"
        }

        let alert = NSAlert()
        alert.messageText = node.isFreeSpace ? "Free Space" : node.name
        var lines: [String] = []
        if node.isFreeSpace, let stats = node.freeStats {
            lines.append("Free: \(both(stats.freeSpace))")
            lines.append("Capacity: \(both(stats.totalSpace))")
            lines.append("Files: \(stats.files)   Folders: \(stats.folders)")
        } else {
            lines.append("Where: \(node.url.deletingLastPathComponent().path)")
            lines.append("Kind: \(node.isDirectory ? "Folder" : node.isSparse ? "Sparse file" : "File")")
            lines.append("Size on disk: \(both(node.size))")
            lines.append("Size in Finder: \(both(node.logicalSize))")
            if node.isDirectory {
                let (files, folders) = counts(node)
                lines.append("Contains: \(files) files, \(folders) folders")
            }
            if let date = node.modificationDate {
                lines.append("Modified: \(DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .medium))")
            }
            lines.append("")
            lines.append(node.isSparse
                ? "This sparse file's holes take no disk space, so Finder's size is larger than what it uses."
                : "“Size on disk” is what the tiles show; “Size in Finder” is Get Info's headline number.")
        }
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        if !node.isFreeSpace { alert.addButton(withTitle: "Reveal in Finder") }
        alert.beginSheetModal(for: window) { response in
            if response == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
        }
    }

    private func counts(_ node: Node) -> (files: Int, folders: Int) {
        var files = 0, folders = 0
        for c in node.children where !c.isFreeSpace {
            if c.isDirectory {
                folders += 1
                let sub = counts(c)
                files += sub.files; folders += sub.folders
            } else {
                files += 1
            }
        }
        return (files, folders)
    }
}
