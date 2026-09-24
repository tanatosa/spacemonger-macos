import AppKit

/// Settings dialog, a port of the original's `CSettingsDialog`
/// (SetupDlg.cpp, IDD_SETTINGS) without the language selector: File Layout
/// (density, bias), Display Colors (files, folders), ToolTips (name tips,
/// rollover boxes, info tips with their fields and delays) and Miscellaneous
/// Options. Shown as a sheet; like the original, nothing changes until OK.
final class SettingsDialog: NSObject {

    /// Shows the dialog on `window`; `onApply` runs after OK has stored the
    /// new values.
    static func run(on window: NSWindow, onApply: @escaping () -> Void) {
        let dialog = SettingsDialog()
        dialog.onApply = onApply
        current = dialog   // keep alive while the sheet is up
        window.beginSheet(dialog.buildSheet()) { _ in current = nil }
    }

    private static var current: SettingsDialog?
    private var onApply: (() -> Void)?
    private var sheet: NSWindow!

    static let densityNames = ["Sparse", "Low", "Medium-Low", "Medium", "Medium-High", "High", "Dense"]

    // Controls
    private let density = NSPopUpButton()
    private let bias = NSSlider(value: 0, minValue: -20, maxValue: 20, target: nil, action: nil)
    private let fileColor = NSPopUpButton()
    private let folderColor = NSPopUpButton()
    private let showNameTips = NSButton(checkboxWithTitle: "Show file-name-tips", target: nil, action: nil)
    private let nameTipDelay = NSTextField()
    private let nameTipDelayLabels = [NSTextField(labelWithString: "Delay:"), NSTextField(labelWithString: "msec")]
    private let rolloverBox = NSButton(checkboxWithTitle: "Show Rollover Boxes", target: nil, action: nil)
    private let showInfoTips = NSButton(checkboxWithTitle: "Show file-info-tips", target: nil, action: nil)
    private let infoTipDelay = NSTextField()
    private let infoTipDelayLabels = [NSTextField(labelWithString: "Delay:"), NSTextField(labelWithString: "msec")]
    private let infoFields: [(Settings.InfoTipFields, NSButton)] = [
        (.path, NSButton(checkboxWithTitle: "Full Path", target: nil, action: nil)),
        (.name, NSButton(checkboxWithTitle: "Filename", target: nil, action: nil)),
        (.icon, NSButton(checkboxWithTitle: "Icon", target: nil, action: nil)),
        (.date, NSButton(checkboxWithTitle: "Date / Time", target: nil, action: nil)),
        (.size, NSButton(checkboxWithTitle: "File Size", target: nil, action: nil)),
        (.attrib, NSButton(checkboxWithTitle: "Attributes", target: nil, action: nil)),
    ]
    private let autoRescan = NSButton(checkboxWithTitle: "Auto Rescan on Delete", target: nil, action: nil)
    private let disableDelete = NSButton(checkboxWithTitle: "Disable \u{201C}Move to Trash\u{201D} Command", target: nil, action: nil)
    private let zoomAnimation = NSPopUpButton()
    private let savePosition = NSButton(checkboxWithTitle: "Remember Window Position", target: nil, action: nil)

    // MARK: - Building

    private func buildSheet() -> NSWindow {
        let s = Settings.shared

        // File Layout
        for (i, n) in Self.densityNames.enumerated() {
            density.addItem(withTitle: "\(n) (\(Int(Settings.minsizes[i].h))×\(Int(Settings.minsizes[i].v)))")
        }
        density.selectItem(at: s.density + 3)
        density.toolTip = "Minimum tile size before a folder stops being subdivided. Denser shows more, smaller files."
        bias.integerValue = s.bias
        bias.numberOfTickMarks = 9          // original: SetTicFreq(5) over 0…40
        bias.allowsTickMarkValuesOnly = false
        bias.widthAnchor.constraint(equalToConstant: 200).isActive = true
        bias.toolTip = "Which way boxes are split: toward Horz stacks them (wider boxes), toward Vert places them side by side (taller boxes)."
        let biasLabels = NSStackView(views: [small("Horz"), NSView(), small("Equal"), NSView(), small("Vert")])
        biasLabels.distribution = .equalCentering
        let biasColumn = NSStackView(views: [biasLabels, bias])
        biasColumn.orientation = .vertical
        biasColumn.spacing = 2
        biasLabels.widthAnchor.constraint(equalTo: bias.widthAnchor).isActive = true
        let layout = group("File Layout", grid([
            [label("Density:"), density],
            [label("Bias:"), biasColumn],
        ]))

        // Display Colors
        for popup in [fileColor, folderColor] { popup.addItems(withTitles: Palette.schemeNames) }
        fileColor.selectItem(at: s.fileColor)
        folderColor.selectItem(at: s.folderColor)
        let colors = group("Display Colors", grid([
            [label("Files:"), fileColor],
            [label("Folders:"), folderColor],
        ]))

        // ToolTips
        showNameTips.state = s.showNameTips ? .on : .off
        showNameTips.target = self
        showNameTips.action = #selector(tipTogglesChanged(_:))
        configureDelay(nameTipDelay, s.nameTipDelay)
        rolloverBox.state = s.rolloverBox ? .on : .off
        showInfoTips.state = s.showInfoTips ? .on : .off
        showInfoTips.target = self
        showInfoTips.action = #selector(tipTogglesChanged(_:))
        configureDelay(infoTipDelay, s.infoTipDelay)
        for (field, box) in infoFields { box.state = s.infoTipFields.contains(field) ? .on : .off }
        let fieldGrid = NSGridView(views: [
            [infoFields[0].1, infoFields[3].1],
            [infoFields[1].1, infoFields[4].1],
            [infoFields[2].1, infoFields[5].1],
        ])
        fieldGrid.rowSpacing = 4
        fieldGrid.columnSpacing = 16
        let nameRow = row([showNameTips, NSView(), nameTipDelayLabels[0], nameTipDelay, nameTipDelayLabels[1]])
        let infoRow = row([showInfoTips, NSView(), infoTipDelayLabels[0], infoTipDelay, infoTipDelayLabels[1]])
        let indentedFields = row([spacer(20), fieldGrid])
        let tipsStack = NSStackView(views: [nameRow, rolloverBox, infoRow, indentedFields])
        tipsStack.orientation = .vertical
        tipsStack.alignment = .leading
        tipsStack.spacing = 6
        for r in [nameRow, infoRow] {
            r.widthAnchor.constraint(equalTo: tipsStack.widthAnchor).isActive = true
        }
        let tips = group("ToolTips", tipsStack)

        // Miscellaneous Options
        autoRescan.state = s.autoRescan ? .on : .off
        autoRescan.toolTip = "After Move to Trash, scan the whole drive again. Off: the item is just removed from the map."
        disableDelete.state = s.disableDelete ? .on : .off
        disableDelete.toolTip = "Turn off every Move to Trash button and menu item, to browse without risk."
        zoomAnimation.addItems(withTitles: ["Smooth", "Classic (outline)", "Off"])
        zoomAnimation.selectItem(at: Settings.ZoomAnimation.allCases.firstIndex(of: s.zoomAnimation) ?? 0)
        savePosition.state = s.savePosition ? .on : .off
        let misc = group("Miscellaneous Options", grid([
            [autoRescan, disableDelete],
            [row([label("Zoom animation:"), zoomAnimation]), savePosition],
        ]))

        // OK / Cancel, centered like the drive dialog.
        let ok = NSButton(title: "OK", target: self, action: #selector(ok(_:)))
        ok.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        for b in [ok, cancel] { b.widthAnchor.constraint(equalToConstant: 96).isActive = true }
        let buttons = NSStackView(views: [cancel, ok])
        buttons.spacing = 12

        let top = NSStackView(views: [layout, colors])
        top.alignment = .top
        top.distribution = .fillEqually
        top.spacing = 12

        let content = NSStackView(views: [top, tips, misc, buttons])
        content.orientation = .vertical
        content.alignment = .centerX
        content.spacing = 12
        content.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [top, tips, misc] {
            v.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -32).isActive = true
        }

        sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        sheet.title = "Settings"
        sheet.contentView = content
        sheet.setContentSize(content.fittingSize)
        tipTogglesChanged(nil)
        return sheet
    }

    private func label(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.alignment = .right
        return l
    }

    private func small(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func spacer(_ width: CGFloat) -> NSView {
        let v = NSView()
        v.widthAnchor.constraint(equalToConstant: width).isActive = true
        return v
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let r = NSStackView(views: views)
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 6
        return r
    }

    private func grid(_ rows: [[NSView]]) -> NSGridView {
        let g = NSGridView(views: rows)
        g.rowSpacing = 8
        g.columnSpacing = 8
        g.rowAlignment = .firstBaseline
        return g
    }

    /// A titled group box, the original's GROUPBOX.
    private func group(_ title: String, _ body: NSView) -> NSBox {
        let box = NSBox()
        box.title = title
        box.titlePosition = .atTop
        body.translatesAutoresizingMaskIntoConstraints = false
        let inner = NSView()
        inner.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 8),
            body.trailingAnchor.constraint(lessThanOrEqualTo: inner.trailingAnchor, constant: -8),
            body.topAnchor.constraint(equalTo: inner.topAnchor, constant: 6),
            body.bottomAnchor.constraint(equalTo: inner.bottomAnchor, constant: -6),
        ])
        box.contentView = inner
        return box
    }

    private func configureDelay(_ field: NSTextField, _ value: Int) {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.minimum = 0
        f.maximum = 99_999
        f.allowsFloats = false
        field.formatter = f
        field.integerValue = value
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: 56).isActive = true
    }

    // MARK: - Actions

    /// Original EnableNameTipButtons / EnableInfoTipButtons: a tip's options
    /// are only editable while that tip is switched on.
    @objc private func tipTogglesChanged(_ sender: Any?) {
        let names = showNameTips.state == .on
        nameTipDelay.isEnabled = names
        for l in nameTipDelayLabels { l.textColor = names ? .labelColor : .disabledControlTextColor }
        let infos = showInfoTips.state == .on
        infoTipDelay.isEnabled = infos
        for l in infoTipDelayLabels { l.textColor = infos ? .labelColor : .disabledControlTextColor }
        for (_, box) in infoFields { box.isEnabled = infos }
    }

    /// Original CSettingsDialog::OnOK: store every control, then redraw.
    @objc private func ok(_ sender: Any?) {
        sheet.makeFirstResponder(nil)   // commit an edit in progress
        let s = Settings.shared
        s.density = density.indexOfSelectedItem - 3
        s.bias = Int(bias.doubleValue.rounded())
        s.fileColor = fileColor.indexOfSelectedItem
        s.folderColor = folderColor.indexOfSelectedItem
        s.showNameTips = showNameTips.state == .on
        s.nameTipDelay = nameTipDelay.integerValue
        s.rolloverBox = rolloverBox.state == .on
        s.showInfoTips = showInfoTips.state == .on
        s.infoTipDelay = infoTipDelay.integerValue
        var fields: Settings.InfoTipFields = []
        for (field, box) in infoFields where box.state == .on { fields.insert(field) }
        s.infoTipFields = fields
        s.autoRescan = autoRescan.state == .on
        s.disableDelete = disableDelete.state == .on
        s.zoomAnimation = Settings.ZoomAnimation.allCases[max(zoomAnimation.indexOfSelectedItem, 0)]
        s.savePosition = savePosition.state == .on
        sheet.sheetParent?.endSheet(sheet, returnCode: .OK)
        onApply?()
    }

    @objc private func cancel(_ sender: Any?) {
        sheet.sheetParent?.endSheet(sheet, returnCode: .cancel)
    }
}
