import AppKit
import NetFS

/// Drive-selection dialog, a port of the original's `CDriveDialog`: it lists
/// every available mounted volume (analogous to the original enumerating drive
/// letters A–Z and skipping types UNKNOWN / NO_ROOT_DIR — which kept mapped
/// network drives, DRIVE_REMOTE), showing the volume's icon and display name.
/// Double-clicking an entry or pressing OK returns that volume's root URL;
/// Cancel returns nil, matching `EndDialog(-1)`.
///
/// Network shares that aren't mounted yet can be reached with Connect to
/// Server… — the macOS counterpart of mapping a network drive letter — which
/// mounts through NetFS with the system's sign-in dialog and Keychain.
final class DriveDialog: NSObject, NSTableViewDataSource, NSTableViewDelegate {

    /// Modal loop: returns the selected volume root URL, or nil if cancelled.
    static func selectDrive() -> URL? {
        let dialog = DriveDialog()
        return dialog.runModal()
    }

    private struct DriveInfo {
        let url: URL
        let name: String
        let icon: NSImage
        let totalSpace: Int64
        let freeSpace: Int64
        /// Not on this Mac: SMB, AFP, NFS, WebDAV… (`volumeIsLocal == false`).
        let isNetwork: Bool
        /// "SMB", "WebDAV", "APFS", … for the detail line.
        let format: String
    }

    private var drives: [DriveInfo] = []

    private var window: NSWindow!
    private var tableView: NSTableView!
    private var okButton: NSButton!
    private var connectButton: NSButton!
    private var cancelButton: NSButton!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var returnURL: URL?
    private var mountObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        loadDrives()
    }

    /// Enumerate available volumes (the macOS analog of CDriveInfo::LoadDriveInfo).
    private func loadDrives() {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeTotalCapacityKey,
                                      .volumeAvailableCapacityKey, .volumeIsLocalKey,
                                      .volumeLocalizedFormatDescriptionKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) ?? []
        drives = urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 32, height: 32)
            return DriveInfo(url: url,
                             name: values?.volumeName ?? url.lastPathComponent,
                             icon: icon,
                             totalSpace: Int64(values?.volumeTotalCapacity ?? 0),
                             freeSpace: Int64(values?.volumeAvailableCapacity ?? 0),
                             isNetwork: values?.volumeIsLocal == false,
                             format: values?.volumeLocalizedFormatDescription ?? "")
        }
    }

    private func runModal() -> URL? {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340),
                          styleMask: [.titled],
                          backing: .buffered, defer: false)
        window.title = "Select Drive"

        tableView = NSTableView()
        let iconColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("icon"))
        iconColumn.width = 40
        iconColumn.isEditable = false
        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 190
        let spaceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("space"))
        spaceColumn.title = "Free / Total"
        spaceColumn.width = 170
        tableView.addTableColumn(iconColumn)
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(spaceColumn)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.rowHeight = 40
        tableView.doubleAction = #selector(doubleClick(_:))
        tableView.target = self

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true

        okButton = NSButton(title: "OK", target: self, action: #selector(ok(_:)))
        okButton.keyEquivalent = "\r"
        okButton.isEnabled = false
        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelDialog(_:)))
        cancelButton.keyEquivalent = "\u{1b}"
        connectButton = NSButton(title: "Connect to Server…", target: self,
                                 action: #selector(connectToServer(_:)))
        connectButton.toolTip = "Mount a network share (SMB, AFP, NFS or WebDAV) and scan it — like mapping a network drive in Windows"
        okButton.widthAnchor.constraint(equalToConstant: 96).isActive = true
        cancelButton.widthAnchor.constraint(equalToConstant: 96).isActive = true

        // One centered group, like the pair before it.
        let buttonBar = NSStackView(views: [connectButton, cancelButton, okButton])
        buttonBar.spacing = 12

        spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingMiddle
        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.spacing = 6

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 340))
        for v in [scroll, statusRow, buttonBar] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusRow.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 6),
            statusRow.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            statusRow.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 12),
            statusRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 16),
            buttonBar.topAnchor.constraint(equalTo: statusRow.bottomAnchor, constant: 6),
            buttonBar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            buttonBar.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -10),
        ])
        window.contentView = content
        window.center()

        // Keep the list current while the dialog is open (a share mounted from
        // Finder, a USB disk plugged in or ejected).
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            mountObservers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in self?.reloadList()
            })
        }
        defer {
            mountObservers.forEach(center.removeObserver)
            mountObservers = []
        }

        returnURL = nil
        window.makeKeyAndOrderFront(nil)
        let response = NSApp.runModal(for: window)
        // Close the dialog window once a drive was selected (or cancelled).
        window.orderOut(nil)
        guard response == NSApplication.ModalResponse.stop, let url = returnURL else { return nil }
        return url
    }

    private func reloadList() {
        let selected = returnURL
        loadDrives()
        tableView.reloadData()
        if let selected, let row = drives.firstIndex(where: { $0.url == selected }) {
            tableView.selectRowIndexes([row], byExtendingSelection: false)
        } else {
            returnURL = nil
            okButton.isEnabled = false
        }
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { drives.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let d = drives[row]
        switch tableColumn?.identifier.rawValue {
        case "icon":
            let v = NSImageView()
            v.image = d.icon
            v.widthAnchor.constraint(equalToConstant: 32).isActive = true
            v.heightAnchor.constraint(equalToConstant: 32).isActive = true
            return centered(v, horizontally: true)
        case "space":
            // Many network shares don't report a capacity (WebDAV reports 0):
            // say so rather than showing "0 B / 0 B".
            let text = d.totalSpace > 0
                ? "\(Format.bytes(d.freeSpace)) / \(Format.bytes(d.totalSpace))"
                : "Size unknown"
            let v = NSTextField(labelWithString: text)
            v.font = NSFont.systemFont(ofSize: 11)
            v.textColor = .secondaryLabelColor
            v.lineBreakMode = .byTruncatingTail
            return centered(v, horizontally: false)
        default:
            let name = NSTextField(labelWithString: d.name)
            name.lineBreakMode = .byTruncatingTail
            let kind = d.isNetwork ? "Network" + (d.format.isEmpty ? "" : " · \(d.format)") : d.format
            let detail = NSTextField(labelWithString: kind)
            detail.font = NSFont.systemFont(ofSize: 10)
            detail.textColor = .secondaryLabelColor
            detail.lineBreakMode = .byTruncatingTail
            let stack = NSStackView(views: kind.isEmpty ? [name] : [name, detail])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 1
            return centered(stack, horizontally: false)
        }
    }

    /// Wraps a cell's content so it sits vertically centered in the row. A
    /// bare NSTextField returned as the cell pins to the row's top.
    private func centered(_ content: NSView, horizontally: Bool) -> NSView {
        let cell = NSTableCellView()
        content.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(content)
        var constraints = [content.centerYAnchor.constraint(equalTo: cell.centerYAnchor)]
        if horizontally {
            constraints.append(content.centerXAnchor.constraint(equalTo: cell.centerXAnchor))
        } else {
            constraints += [
                content.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                content.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Single-selection required, like the original's GetSelectedCount() check.
        okButton.isEnabled = tableView.selectedRowIndexes.count == 1
        if tableView.selectedRow >= 0, tableView.selectedRow < drives.count {
            returnURL = drives[tableView.selectedRow].url
        }
    }

    @objc private func doubleClick(_ sender: Any?) {
        guard tableView.clickedRow >= 0, returnURL != nil else { return }
        NSApp.stopModal(withCode: NSApplication.ModalResponse.stop)
    }

    @objc private func ok(_ sender: Any?) {
        guard returnURL != nil else { return }
        NSApp.stopModal(withCode: NSApplication.ModalResponse.stop)
    }

    @objc private func cancelDialog(_ sender: Any?) {
        returnURL = nil
        NSApp.stopModal(withCode: NSApplication.ModalResponse.cancel)
    }

    // MARK: - Connect to Server

    private static let recentServersKey = "recentServers"
    private static let maxRecentServers = 10

    static var recentServers: [String] {
        UserDefaults.standard.stringArray(forKey: recentServersKey) ?? []
    }

    private static func remember(_ address: String) {
        var list = recentServers.filter { $0 != address }
        list.insert(address, at: 0)
        UserDefaults.standard.set(Array(list.prefix(maxRecentServers)), forKey: recentServersKey)
    }

    /// `server/share` or `smb://server/share`, `afp://…`, `nfs://…`,
    /// `https://…` (WebDAV). No scheme means SMB, as in Finder; a Windows UNC
    /// path (`\\server\share`, what the original's users typed to map a
    /// drive) is taken as SMB too.
    static func serverURL(from text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") {
            t = t.replacingOccurrences(of: "\\", with: "/")
            t = "smb://" + t.drop(while: { $0 == "/" })
            // `$` (admin shares like c$) must be percent-encoded in a URL path.
            t = t.replacingOccurrences(of: "$", with: "%24")
        }
        guard let url = URL(string: t), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    @objc private func connectToServer(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Connect to Server"
        alert.informativeText = """
            Enter a server address, for example smb://server/share. Also \
            accepted: afp://, nfs://, and https:// for WebDAV. You will be asked \
            to sign in if the server needs it.
            """
        let combo = NSComboBox(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        combo.addItems(withObjectValues: Self.recentServers)
        combo.stringValue = Self.recentServers.first ?? "smb://"
        combo.completes = true
        alert.accessoryView = combo
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = combo
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard let url = Self.serverURL(from: combo.stringValue) else {
            showError("“\(combo.stringValue)” isn’t a server address.",
                      "Use a form like smb://server/share.")
            return
        }
        mount(url, address: combo.stringValue)
    }

    /// Mounts `url` with NetFS, then returns its mount point as the drive to
    /// scan. The system shows its own sign-in dialog when needed.
    private func mount(_ url: URL, address: String) {
        setConnecting("Connecting to \(url.host ?? "server")…")
        Self.mount(url) { [weak self] result in
            guard let self else { return }
            self.setConnecting(nil)
            switch result {
            case .success(let mountPoint):
                Self.remember(address)
                self.returnURL = mountPoint
                NSApp.stopModal(withCode: NSApplication.ModalResponse.stop)
            case .failure(let error):
                if error.code == ECANCELED || error.code == Int32(userCanceledErr) { return }
                self.showError("Couldn’t connect to “\(address)”.", error.detail)
            }
        }
    }

    struct MountError: Error {
        let code: Int32
        var detail: String {
            let text = code > 0 ? String(cString: strerror(code)) : "error \(code)"
            return "\(text) (\(code)). Check the address, the network, and that the share exists."
        }
    }

    /// NetFS mount with the system sign-in UI allowed; calls back on the main
    /// queue with the mount point. A share that is already mounted resolves
    /// to its existing mount point — NetFS reports that as EEXIST or, for
    /// some protocols (WebDAV), as a generic -6600, so any failure first
    /// checks for an existing mount.
    static func mount(_ url: URL, completion: @escaping (Result<URL, MountError>) -> Void) {
        let openOptions = NSMutableDictionary()
        openOptions[kNAUIOptionKey] = kNAUIOptionAllowUI
        var request: AsyncRequestID?
        let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, openOptions, nil,
                                        &request, DispatchQueue.main) { result, _, mountpoints in
            if result == 0, let first = (mountpoints as? [String])?.first {
                completion(.success(URL(fileURLWithPath: first)))
            } else if result != ECANCELED, result != Int32(userCanceledErr),
                      let existing = existingMount(for: url) {
                completion(.success(existing))
            } else {
                completion(.failure(MountError(code: result)))
            }
        }
        if status != 0 {
            DispatchQueue.main.async { completion(.failure(MountError(code: status))) }
        }
    }

    /// A mount of the same server (and share) that is already there.
    static func existingMount(for url: URL) -> URL? {
        guard let host = url.host?.lowercased() else { return nil }
        let share = url.pathComponents.dropFirst().first?.lowercased()
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return nil }
        for i in 0..<Int(count) {
            var fs = mounts[i]
            let from = withUnsafeBytes(of: &fs.f_mntfromname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }.lowercased()
            let on = withUnsafeBytes(of: &fs.f_mntonname) {
                String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
            }
            if from.contains(host), share.map({ from.contains("/" + $0) }) ?? true {
                return URL(fileURLWithPath: on)
            }
        }
        return nil
    }

    private func setConnecting(_ message: String?) {
        statusLabel.stringValue = message ?? ""
        if message != nil { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        connectButton.isEnabled = message == nil
        cancelButton.isEnabled = message == nil
        okButton.isEnabled = message == nil && returnURL != nil
        tableView.isEnabled = message == nil
    }

    private func showError(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.beginSheetModal(for: window)
    }
}
