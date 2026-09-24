import AppKit

/// A small borderless tip window, the port of the original's `CTipWnd`
/// (TipWnd.cpp). Used for the file-name tip (drawn over a tile in the tile's
/// own colors) and the file-info tip (near the mouse). It never takes focus
/// or mouse events, and rides along with its parent window as a child window.
final class TipWindow: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let stack: NSStackView
    private let box = NSView()

    init() {
        stack = NSStackView(views: [iconView, label])
        super.init(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true

        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.preferredMaxLayoutWidth = 420

        box.wantsLayer = true
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.black.cgColor
        box.addSubview(stack)
        contentView = box
    }

    /// Shows the tip with its top-left corner at `topLeft` (screen coords),
    /// pushed back on screen if needed (original `CTipWnd::PushOnScreen`).
    func show(_ text: String, icon: NSImage? = nil, font: NSFont,
              background: NSColor, textColor: NSColor = .black,
              padding: NSSize = NSSize(width: 6, height: 4),
              topLeft: CGPoint, parent: NSWindow) {
        label.stringValue = text
        label.font = font
        label.textColor = textColor
        iconView.image = icon
        iconView.isHidden = icon == nil
        box.layer?.backgroundColor = background.cgColor

        NSLayoutConstraint.deactivate(box.constraints.filter { $0.firstItem === stack || $0.secondItem === stack })
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: padding.width),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -padding.width),
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: padding.height),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -padding.height),
        ])
        let size = NSSize(width: stack.fittingSize.width + padding.width * 2,
                          height: stack.fittingSize.height + padding.height * 2)
        var frame = NSRect(x: topLeft.x, y: topLeft.y - size.height,
                           width: size.width, height: size.height)
        if let screen = (parent.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        setFrame(frame, display: true)
        if parent.childWindows?.contains(self) != true {
            parent.addChildWindow(self, ordered: .above)
        }
        orderFront(nil)
    }

    func hide() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}
