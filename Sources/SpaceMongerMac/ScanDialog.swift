import AppKit

/// Scan-progress dialog, a port of the original's `CFolderDialog`
/// (IDD_SCAN_DIALOG): shows the current path, files found, folders found, a
/// progress bar filled by the fraction of used disk space discovered, and a
/// Cancel button. Unlike the original's modal dialog this is a non-modal
/// window kept at the floating level, so the main window stays visible during
/// the scan but can never cover it.
final class ScanDialog {
    static let shared = ScanDialog()

    /// Called when the user presses Cancel.
    var onCancel: (() -> Void)?

    private var window: NSWindow?
    private var pathLabel: NSTextField!
    private var filesLabel: NSTextField!
    private var foldersLabel: NSTextField!
    private var progress: NSProgressIndicator!
    private var cancelButton: NSButton!

    /// Always animated (reloads, where nothing says how much is left).
    private var alwaysIndeterminate = false
    /// Last time the bar rose noticeably, and to what.
    private var lastRise = (time: Date(), value: 0.0)
    /// The bar's value when the current stall began (nil = not stalled).
    private var stalledAt: Double?
    /// Bumped on every show, so a pending close from `finish` can't close
    /// a newer scan's dialog.
    private var generation = 0

    /// Past this the rest is mostly tiny files and unreadable space: the bar
    /// would crawl, so it animates instead.
    private static let nearlyDone = 0.95
    /// No noticeable rise (0.5 points) for this long counts as a stall…
    private static let stallSeconds = 3.0
    /// …which ends only after a clear rise, so short pauses don't make the
    /// bar flicker between the value and the animation.
    private static let resumeRise = 0.015

    /// `indeterminate` for reloads, where the share of the disk still to read
    /// isn't known up front.
    func show(path: String, indeterminate: Bool = false) {
        if window == nil { buildWindow() }
        generation += 1
        alwaysIndeterminate = indeterminate
        lastRise = (Date(), 0)
        stalledAt = nil
        window?.title = indeterminate ? "Reloading…" : "Scanning Disk…"
        pathLabel.stringValue = path
        filesLabel.stringValue = "Files found: 0"
        foldersLabel.stringValue = "Folders found: 0"
        setAnimating(indeterminate)
        progress.doubleValue = 0
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func update(path: String, files: Int, folders: Int, fraction: Double) {
        guard let window, window.isVisible else { return }
        pathLabel.stringValue = path
        filesLabel.stringValue = "Files found: \(files)"
        foldersLabel.stringValue = "Folders found: \(folders)"
        updateBar(fraction)
        // Drain the event queue so the window stays responsive (the original
        // pumps messages every 200 ms in CFolderDialog::UpdateDisplay).
        window.displayIfNeeded()
    }

    /// The bar shows bytes found against the space in use. The last stretch
    /// of a scan is typically huge numbers of tiny files (caches,
    /// node_modules) that barely move it, and space the scan can't read never
    /// arrives at all — so near the end, or whenever it stalls while the
    /// counters keep climbing, the bar animates instead of looking frozen.
    /// A stall ends as soon as the bar rises again; past 95% it stays animated.
    private func updateBar(_ fraction: Double) {
        guard !alwaysIndeterminate else { return }
        guard fraction >= 0 else { setAnimating(true); return }   // no known total
        let now = Date()
        if fraction - lastRise.value >= 0.005 { lastRise = (now, fraction) }
        if let start = stalledAt {
            if fraction - start >= Self.resumeRise { stalledAt = nil }
        } else if now.timeIntervalSince(lastRise.time) > Self.stallSeconds {
            stalledAt = fraction
        }
        setAnimating(fraction >= Self.nearlyDone || stalledAt != nil)
        if !progress.isIndeterminate { progress.doubleValue = fraction }
    }

    private func setAnimating(_ on: Bool) {
        guard progress.isIndeterminate != on else { return }
        progress.isIndeterminate = on
        if on { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    /// Scan finished: fill the bar and close shortly after — the original's
    /// `CFolderDialog::ForcedUpdate`, which sets the bar to 100% at the end.
    func finish() {
        guard let window, window.isVisible else { return }
        setAnimating(false)
        progress.doubleValue = 1
        window.displayIfNeeded()
        let shown = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.close()
        }
    }

    func close() {
        window?.orderOut(nil)
    }

    /// Fixed dialog size — the original's IDD_SCAN_DIALOG is a fixed-size
    /// dialog (250×54 dialog units) that the user cannot resize.
    private static let dialogWidth: CGFloat = 360
    private static let dialogHeight: CGFloat = 150

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.dialogWidth, height: Self.dialogHeight),
                          styleMask: [.titled, .miniaturizable],
                          backing: .buffered, defer: false)
        window!.title = "Scanning Disk…"
        window!.isReleasedWhenClosed = false
        window!.styleMask.remove(.resizable)  // fixed size, like the original
        // Always on top: stays above the main window and other apps while the
        // scan runs (the original's dialog was modal and never got buried).
        window!.level = .floating
        window!.hidesOnDeactivate = false
        window!.collectionBehavior.insert(.fullScreenAuxiliary)

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        filesLabel = NSTextField(labelWithString: "Files found: 0")
        foldersLabel = NSTextField(labelWithString: "Folders found: 0")
        filesLabel.font = NSFont.systemFont(ofSize: 11)
        foldersLabel.font = NSFont.systemFont(ofSize: 11)

        // Determinate progress bar, fixed width spanning the dialog's inner
        // width (original: IDC_LOAD_PROGRESS spanning the dialog).
        progress = NSProgressIndicator(frame: NSRect(x: 14, y: 62,
                                                     width: Self.dialogWidth - 28, height: 20))
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.doubleValue = 0
        progress.controlSize = .regular
        // Fixed width: never stretch, never collapse.
        progress.translatesAutoresizingMaskIntoConstraints = true
        progress.autoresizingMask = []
        progress.widthAnchor.constraint(equalToConstant: Self.dialogWidth - 28).isActive = true
        progress.heightAnchor.constraint(equalToConstant: 20).isActive = true

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelScan(_:)))
        cancelButton.bezelStyle = NSButton.BezelStyle.rounded

        pathLabel.frame = NSRect(x: 14, y: 122, width: Self.dialogWidth - 28, height: 16)
        pathLabel.autoresizingMask = [.width]
        filesLabel.frame = NSRect(x: 14, y: 98, width: Self.dialogWidth - 28, height: 16)
        filesLabel.autoresizingMask = [.width]
        foldersLabel.frame = NSRect(x: 14, y: 80, width: Self.dialogWidth - 28, height: 16)
        foldersLabel.autoresizingMask = [.width]
        cancelButton.frame = NSRect(x: Self.dialogWidth - 96, y: 12, width: 82, height: 28)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: Self.dialogWidth, height: Self.dialogHeight))
        content.autoresizesSubviews = true
        content.addSubview(pathLabel)
        content.addSubview(filesLabel)
        content.addSubview(foldersLabel)
        content.addSubview(progress)
        content.addSubview(cancelButton)
        window!.contentView = content
    }

    @objc private func cancelScan(_ sender: Any?) {
        onCancel?()
    }
}