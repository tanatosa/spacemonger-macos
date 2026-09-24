import AppKit

/// Custom view that draws the treemap and handles selection / zoom interaction.
final class TreemapView: NSView {

    /// The folder currently filling the whole view.
    var displayedRoot: Node? {
        didSet { needsLayout = true }
    }

    /// Fired on double-click of a folder (to zoom in).
    var onZoomIn: ((Node) -> Void)?
    /// Fired whenever the selection changes (or becomes nil).
    var onSelection: ((Node?) -> Void)?
    /// Builds the right-click menu for the tile under the mouse (nil = empty
    /// space), after that tile has been selected — like the original's
    /// `CFolderView::OnRButtonUp`.
    var contextMenuProvider: ((Node?) -> NSMenu?)?

    private var layoutTree: LayoutNode?
    private(set) var selectedNode: Node?
    private var selectionFrame: CGRect?

    // Hover state (see the Hover extension).
    fileprivate var trackingArea: NSTrackingArea?
    /// Tiles lit by the rollover box (the hovered tile and its folders).
    fileprivate var hoverChain = Set<ObjectIdentifier>()
    fileprivate weak var hoverTile: LayoutNode?
    fileprivate var hoverOnBadge = false
    fileprivate let nameTip = TipWindow()
    fileprivate let infoTip = TipWindow()
    fileprivate var nameTipTimer: Timer?
    fileprivate var infoTipTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Layer-backed so the zoom animations can run as sublayers on top.
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Layout

    override var isFlipped: Bool {
        false // keep standard bottom-left origin for simple math
    }

    override func layout() {
        super.layout()
        guard let display = displayedRoot else {
            layoutTree = nil
            return
        }
        hideTips()
        let inset = bounds.insetBy(dx: 6, dy: 6)
        let s = Settings.shared
        let tree = buildLayout(for: display, in: inset, hmin: s.hmin, vmin: s.vmin,
                               bias: s.bias, showFreeSpace: s.showFreeSpace)
        layoutTree = tree
        hoverChain = []
        // The selection's rect belongs to the previous layout; find the same
        // node in the new one (or drop the highlight if it's no longer drawn).
        // A folder we just zoomed into fills the view — no highlight for it.
        // After a reload the tile holds the updated node — select that one.
        if let sel = selectedNode {
            let fresh = sel.url == display.url ? nil : tile(for: sel.url, in: tree)
            selectionFrame = fresh?.frame
            selectedNode = fresh?.file
            if fresh == nil || fresh?.file.size != sel.size { onSelection?(fresh?.file) }
        }
        needsDisplay = true
    }

    /// The drawn tile for `url`, if any.
    private func tile(for url: URL, in root: LayoutNode?) -> LayoutNode? {
        guard let root else { return nil }
        if root.file.url == url && !root.file.isFreeSpace { return root }
        for c in root.children {
            if let hit = tile(for: url, in: c) { return hit }
        }
        return nil
    }

    /// The deepest drawn tile that is `url` or one of its ancestors — where a
    /// folder we zoomed out of sits in the new layout.
    private func nearestTile(for url: URL, in root: LayoutNode?) -> LayoutNode? {
        guard let root else { return nil }
        let target = url.standardizedFileURL.path
        var best: LayoutNode?
        func visit(_ ln: LayoutNode) {
            for c in ln.children where c.file.isDirectory {
                let p = c.file.url.standardizedFileURL.path
                if p == target || target.hasPrefix(p.hasSuffix("/") ? p : p + "/") {
                    best = c
                    visit(c)
                    return
                }
            }
        }
        visit(root)
        return best
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let root = layoutTree else {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }
        NSColor(calibratedWhite: 0.15, alpha: 1).setFill()
        bounds.fill()

        var budget = 150_000
        drawNode(root, depth: 0, budget: &budget)

        // Selection highlight (same finite-check: the frame comes from layout
        // and must never reach NSBezierPath with NaN/∞ components).
        if let sel = selectionFrame,
           sel.origin.x.isFinite, sel.origin.y.isFinite,
           sel.width.isFinite, sel.height.isFinite {
            NSColor.selectedControlColor.setStroke()
            let path = NSBezierPath(rect: sel.insetBy(dx: -1.5, dy: -1.5))
            path.lineWidth = 2.5
            path.stroke()
        }
    }

    private func drawNode(_ ln: LayoutNode, depth: Int, budget: inout Int) {
        for child in ln.children {
            guard budget > 0 else { break }
            budget -= 1
            fillTile(child, depth: depth + 1)
            if !child.children.isEmpty {
                drawNode(child, depth: depth + 1, budget: &budget)
            }
        }
    }

    private func fillTile(_ ln: LayoutNode, depth: Int) {
        let rect = ln.frame
        // Defensive: skip degenerate / non-finite tiles. NSBezierPath raises an
        // NSException (→ crash) on any non-finite coordinate. CGRect's
        // isNull/isInfinite/isEmpty do NOT catch NaN or partially-infinite
        // rects, so every component is checked explicitly.
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0 else { return }

        // Original free-space tile (AddDisplayFolder: depth -1, flags & 2):
        // flat GetSysColor(COLOR_3DFACE) fill, no black outer frame, no bevel,
        // and the volume stats instead of the name.
        if ln.file.isFreeSpace {
            NSColor(calibratedWhite: 192.0 / 255.0, alpha: 1).setFill()
            NSBezierPath(rect: rect).fill()
            drawFreeSpaceLabel(for: ln, in: rect)
            return
        }

        // Original MinimalDrawDisplayFolder: the file or folder color scheme
        // (Settings ▸ Display Colors), black outer frame, then a 1px inset 3D
        // bevel (bright top/left, dark bottom/right). With rollover boxes on,
        // the hovered tile and its folders light up and everything else dims.
        let s = Settings.shared
        var (fill, bright, dark) = Palette.colors(
            scheme: ln.file.isDirectory ? s.folderColor : s.fileColor, depth: depth)
        if s.rolloverBox {
            if hoverChain.contains(ObjectIdentifier(ln)) {
                (dark, fill, bright) = (fill, bright, .white)
            } else {
                (bright, fill) = (fill, dark)
            }
        }
        fill.setFill()
        NSBezierPath(rect: rect).fill()

        // 1) Black outer frame (DrawBox with black) — makes borders dark.
        NSColor.black.setStroke()
        let frame = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        frame.lineWidth = 1
        frame.stroke()

        // 2) Inset bevel (DrawDualBox at x+1,y+1): bright / dark edges.
        // Guard: insetBy on a rect thinner than 2pt returns CGRect.null, whose
        // origin is (+inf, +inf) — feeding that to NSBezierPath raises an
        // NSException and crashes the app. Skip the bevel for such slivers.
        let inner = rect.insetBy(dx: 1, dy: 1)
        guard !inner.isNull, inner.width > 0, inner.height > 0,
              inner.origin.x.isFinite, inner.origin.y.isFinite else {
            return
        }
        let topLeft = NSBezierPath()
        topLeft.move(to: CGPoint(x: inner.minX, y: inner.minY))
        topLeft.line(to: CGPoint(x: inner.minX, y: inner.maxY))
        topLeft.line(to: CGPoint(x: inner.maxX, y: inner.maxY))
        topLeft.lineWidth = 1
        bright.setStroke()
        topLeft.stroke()

        let bottomRight = NSBezierPath()
        bottomRight.move(to: CGPoint(x: inner.maxX, y: inner.maxY))
        bottomRight.line(to: CGPoint(x: inner.maxX, y: inner.minY))
        bottomRight.line(to: CGPoint(x: inner.minX, y: inner.minY))
        bottomRight.lineWidth = 1
        dark.setStroke()
        bottomRight.stroke()

        if let badge = sparseBadgeRect(for: ln) { drawSparseBadge(in: badge) }
        drawLabel(for: ln, in: labelRect(for: ln))
    }

    /// Where a tile's label goes: the tile, minus the top strip when a sparse
    /// badge takes the top-right corner, so the two never overlap.
    private func labelRect(for ln: LayoutNode) -> CGRect {
        var r = ln.frame
        if sparseBadgeRect(for: ln) != nil { r.size.height -= Self.badgeReserve }
        return r
    }

    /// The font and size a tile's name is drawn at, or nil when it doesn't fit
    /// even at the 9 pt floor (then no label is drawn — the name tip's cue).
    private func fittedLabel(for ln: LayoutNode, in rect: CGRect) -> (font: NSFont, size: CGSize)? {
        let name = ln.file.name as NSString
        guard name.length > 0 else { return nil }
        let isDir = ln.file.isDirectory
        // Same margins the original uses (w-2, h-2) when deciding fit.
        let availWidth = rect.width - 2
        // A folder's name must fit in its title bar (below the 1px black frame),
        // otherwise it runs into — and is painted over by — the child tiles.
        let availHeight = isDir ? min(folderTitleBarHeight - 1, rect.height - 2) : rect.height - 2
        guard availWidth > 0, availHeight > 0 else { return nil }

        // Shrink the font (to a 9 pt floor) until the name fits the available box.
        var font = NSFont.systemFont(ofSize: isDir ? 13 : 12, weight: isDir ? .medium : .regular)
        var size: CGFloat = font.pointSize
        while size > 9, name.size(withAttributes: [.font: font]).width > availWidth
                        || name.size(withAttributes: [.font: font]).height > availHeight {
            size -= 1
            font = NSFont.systemFont(ofSize: size, weight: isDir ? .medium : .regular)
        }

        // `size(withAttributes:)` reports the full line box (ascender + descender),
        // so the whole glyph row is measured and drawn without mid-letter clipping.
        let textSize = name.size(withAttributes: [.font: font])
        guard textSize.width > 0, textSize.height > 0,
              textSize.width <= availWidth, textSize.height <= availHeight else { return nil }
        return (font, textSize)
    }

    // MARK: - Sparse-file badge

    private static let badgeSize: CGFloat = 12
    /// Strip at the top of a badged tile kept free of the label.
    private static let badgeReserve: CGFloat = 16

    /// Top-right corner badge for sparse files, only when the tile has room
    /// for both the badge and a label below it.
    private func sparseBadgeRect(for ln: LayoutNode) -> CGRect? {
        guard ln.file.isSparse else { return nil }
        let r = ln.frame
        guard r.width >= 32, r.height >= 40,
              r.origin.x.isFinite, r.origin.y.isFinite else { return nil }
        let s = Self.badgeSize
        return CGRect(x: r.maxX - 3 - s, y: r.maxY - 3 - s, width: s, height: s)
    }

    private static let sparseSymbol: NSImage? = {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.black]))
        return NSImage(systemSymbolName: "square.dashed", accessibilityDescription: "Sparse file")?
            .withSymbolConfiguration(config)
    }()

    private func drawSparseBadge(in badge: CGRect) {
        NSColor.white.withAlphaComponent(0.85).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 3, yRadius: 3).fill()
        if let symbol = Self.sparseSymbol {
            let s = symbol.size
            symbol.draw(in: CGRect(x: badge.midX - s.width / 2, y: badge.midY - s.height / 2,
                                   width: s.width, height: s.height))
        } else {
            // Fallback glyph: a dashed square.
            let path = NSBezierPath(rect: badge.insetBy(dx: 3, dy: 3))
            path.setLineDash([2, 1], count: 2, phase: 0)
            NSColor.black.setStroke()
            path.stroke()
        }
    }

    /// Tooltip for the sparse badge: what the file is and why Finder disagrees.
    private func sparseExplanation(for file: Node) -> String {
        """
        Sparse file: “\(file.name)”
        Part of this file is holes: ranges that were never written, which \
        take up no disk space. Disk images, VM disks (e.g. Docker.raw) and \
        databases often work this way.

        Uses on disk: \(Format.bytes(file.size))
        Finder “Get Info” reports: \(Format.bytes(file.logicalSize)) (its full length)

        SpaceMonger sizes tiles by the space actually used.
        """
    }

    /// Draws the file/folder name on a tile, applying the original's centering
    /// logic: center the text when it fits within the tile, otherwise align it
    /// flush to the tile's top-left. Folder title-bars are always top-left.
    private func drawLabel(for ln: LayoutNode, in rect: CGRect) {
        let name = ln.file.name as NSString
        let isDir = ln.file.isDirectory
        // Don't draw the text on tiles too small to hold it — keeps small boxes
        // from showing clipped overflow (this is the explicit no-fit rule; the
        // name tip shows the name on hover instead).
        guard let (font, textSize) = fittedLabel(for: ln, in: rect) else { return }
        let availWidth = rect.width - 2
        let availHeight = isDir ? min(folderTitleBarHeight - 1, rect.height - 2) : rect.height - 2

        // Original centering (FolderView.cpp): center when it fits, else flush
        // left/top; folders sit in their title-bar (always x+2, y+1). The view
        // is not flipped, so "top" is maxY — minY would put the name at the
        // bottom of the tile, underneath the children drawn afterwards.
        let tx: CGFloat
        if isDir || textSize.width > availWidth { tx = rect.minX + 2 }
        else { tx = rect.minX + (rect.width - textSize.width) / 2 }

        let ty: CGFloat
        if isDir || textSize.height > availHeight { ty = rect.maxY - 1 - textSize.height }
        else { ty = rect.minY + (rect.height - textSize.height) / 2 }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Files on large-enough tiles also show size and modification date beneath
        // the name, matching the original (h >= 36 && w >= 48 gate). The three
        // lines are stacked and vertically centered as a small block.
        if !isDir, rect.height >= 36, rect.width >= 48 {
            let subFont = NSFont.systemFont(ofSize: 9)
            let subH = subFont.ascender - subFont.descender   // full line height (no clipping)
            let sizeStr = ln.file.sizeString as NSString
            let dateStr = (dateString(ln.file.modificationDate) ?? "") as NSString

            // Unflipped view: stack downward from the block's top edge (maxY side),
            // otherwise the lines come out in reverse order (date on top).
            let blockH = textSize.height + 3 + subH + 2 + subH
            let top = min(rect.midY + blockH / 2, rect.maxY - 1)

            // Name, then size, then date.
            let nameY = top - textSize.height
            name.draw(in: CGRect(x: tx, y: nameY, width: textSize.width, height: textSize.height),
                      withAttributes: [.font: font, .foregroundColor: NSColor.black])
            let sizeY = nameY - 3 - subH
            drawLine(sizeStr, x: centeredX(sizeStr, font: subFont, in: rect), y: sizeY, font: subFont, alpha: 0.85)
            if dateStr.length > 0 {
                drawLine(dateStr, x: centeredX(dateStr, font: subFont, in: rect),
                         y: sizeY - 2 - subH, font: subFont, alpha: 0.7)
            }
            return
        }

        // Normal tile: just the (centered / title-bar) name.
        name.draw(in: CGRect(x: tx, y: ty, width: textSize.width, height: textSize.height),
                  withAttributes: [.font: font, .foregroundColor: NSColor.black])
    }

    /// Center a tile's sub-line horizontally if it fits, else flush left (original logic).
    private func centeredX(_ text: NSString, font: NSFont, in rect: CGRect) -> CGFloat {
        let w = text.size(withAttributes: [.font: font]).width
        if w > rect.width - 2 { return rect.minX + 2 }
        return rect.minX + (rect.width - w) / 2
    }

    private func drawLine(_ text: NSString, x: CGFloat, y: CGFloat, font: NSFont, alpha: CGFloat) {
        let fullH = font.ascender - font.descender
        text.draw(in: CGRect(x: x, y: y, width: text.size(withAttributes: [.font: font]).width, height: fullH),
                  withAttributes: [.font: font, .foregroundColor: NSColor.black.withAlphaComponent(alpha)])
    }

    /// Original free-space caption (FolderView.cpp flags & 2 branch): four
    /// centered lines — free-space %, free size, file/folder counts — in black
    /// on the flat gray tile (the "<<<…" name itself is never drawn).
    private func drawFreeSpaceLabel(for ln: LayoutNode, in rect: CGRect) {
        guard let stats = ln.file.freeStats else { return }
        let total = max(stats.totalSpace, 1)
        let percent = (stats.freeSpace * 1000) / total
        let lines = [
            "\(percent / 10).\(percent % 10)%",
            "\(Format.bytes(stats.freeSpace)) Free",
            "Files Total:  \(stats.files)",
            "Folders Total:  \(stats.folders)",
        ]
        let font = NSFont.systemFont(ofSize: 9)
        let lineH = font.ascender - font.descender
        let gap: CGFloat = 4
        let blockH = lineH * 4 + gap * 3

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Original centers each line on the block's mid-Y anchor; small tiles
        // simply clip, like the original's SelectClipRgn.
        // Unflipped view: the first line goes at the top (maxY side), stepping down.
        var y = rect.midY + blockH / 2 - lineH
        for line in lines {
            let text = line as NSString
            let w = text.size(withAttributes: [.font: font]).width
            let tx = w > rect.width - 2 ? rect.minX + 2 : rect.minX + (rect.width - w) / 2
            text.draw(in: CGRect(x: tx, y: y, width: w, height: lineH),
                      withAttributes: [.font: font, .foregroundColor: NSColor.black])
            y -= lineH + gap
        }
    }

    private func dateString(_ date: Date?) -> String? {
        guard let date else { return nil }
        return TreemapView.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy HH:mm:ss"
        return f
    }()

    // MARK: - Zoom animation

    enum ZoomTransition { case zoomIn, zoomOut }

    /// Overlay layers / timer of the running animation, and the root it will
    /// install when it ends (classic style swaps the root last, like the
    /// original, which animates first and then calls OnUpdate).
    private var animationLayer: CALayer?
    private var classicTimer: Timer?
    private var pendingRoot: Node?

    /// Shows `node` as the new root, animated per `Settings.zoomAnimation`.
    func show(_ node: Node, transition: ZoomTransition?) {
        finishZoomAnimation()
        hideTips()
        hoverTile = nil
        guard let transition, let oldRoot = displayedRoot, window != nil,
              bounds.width > 40, bounds.height > 40 else {
            displayedRoot = node
            return
        }
        switch Settings.shared.zoomAnimation {
        case .off:
            displayedRoot = node
        case .classic:
            classicZoom(to: node, transition: transition)
        case .smooth:
            smoothZoom(to: node, from: oldRoot, transition: transition)
        }
    }

    /// Ends any running zoom animation immediately, installing its root.
    private func finishZoomAnimation() {
        classicTimer?.invalidate()
        classicTimer = nil
        animationLayer?.removeFromSuperlayer()
        animationLayer = nil
        if let root = pendingRoot {
            pendingRoot = nil
            displayedRoot = root
        }
    }

    /// Port of `CFolderView::AnimateBox`: 8 inverted outline rectangles
    /// interpolated from `start` to `end`, 25 ms apart, then the same 8 again
    /// to erase them (R2_NOT drawn twice cancels out) — about 0.4 s. Zoom in
    /// grows from the clicked tile to the whole view; zoom out shrinks the
    /// whole view to its center point, exactly like the original.
    private func classicZoom(to node: Node, transition: ZoomTransition) {
        let full = bounds
        let center = CGRect(x: full.midX, y: full.midY, width: 0, height: 0)
        let start: CGRect, end: CGRect
        switch transition {
        case .zoomIn:
            start = tile(for: node.url, in: layoutTree)?.frame ?? center
            end = full
        case .zoomOut:
            start = full
            end = center
        }
        func rect(_ step: Int) -> CGRect {   // ComputeNewRect(…, 8, step)
            let t = CGFloat(step) / 8
            let x0 = start.minX + (end.minX - start.minX) * t
            let y0 = start.minY + (end.minY - start.minY) * t
            let x1 = start.maxX + (end.maxX - start.maxX) * t
            let y1 = start.maxY + (end.maxY - start.maxY) * t
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }

        let shape = CAShapeLayer()
        shape.frame = full
        shape.fillColor = nil
        shape.strokeColor = NSColor.white.cgColor
        shape.lineWidth = 1
        // Inverts what's underneath, like the original's R2_NOT pen.
        shape.compositingFilter = CIFilter(name: "CIDifferenceBlendMode")
        layer?.addSublayer(shape)
        animationLayer = shape
        pendingRoot = node

        var visible = Set<Int>()
        var tick = 0
        classicTimer = Timer.scheduledTimer(withTimeInterval: 0.025, repeats: true) { [weak self] _ in
            guard let self else { return }
            if tick < 8 { visible.insert(tick) } else { visible.remove(tick - 8) }
            tick += 1
            let path = CGMutablePath()
            for s in visible.sorted() { path.addRect(rect(s).offsetBy(dx: 0.5, dy: 0.5)) }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = path
            CATransaction.commit()
            if tick >= 16 { self.finishZoomAnimation() }
        }
    }

    /// Smooth zoom: zooming in, the new view grows out of the clicked tile;
    /// zooming out, the old view shrinks back into the folder's real position
    /// in its parent (not the view's center). Snapshot-based, ~0.25 s.
    private func smoothZoom(to node: Node, from oldRoot: Node, transition: ZoomTransition) {
        guard let oldImage = snapshot() else { displayedRoot = node; return }
        let startTile = tile(for: node.url, in: layoutTree)?.frame

        displayedRoot = node
        layoutSubtreeIfNeeded()
        guard let newImage = snapshot() else { return }

        let full = bounds
        let center = CGRect(x: full.midX - 1, y: full.midY - 1, width: 2, height: 2)
        func imageLayer(_ image: CGImage) -> CALayer {
            let l = CALayer()
            l.frame = full
            l.contents = image
            l.contentsGravity = .resize
            return l
        }
        /// Transform that maps the full view onto `r` (anchor is the center).
        func transform(to r: CGRect) -> CATransform3D {
            let scale = CATransform3DMakeScale(max(r.width, 1) / full.width,
                                               max(r.height, 1) / full.height, 1)
            return CATransform3DConcat(scale, CATransform3DMakeTranslation(r.midX - full.midX,
                                                                          r.midY - full.midY, 0))
        }

        let container = CALayer()
        container.frame = full
        let moving: CALayer
        let from: CATransform3D, to: CATransform3D
        let fromOpacity: Float, toOpacity: Float
        switch transition {
        case .zoomIn:
            container.addSublayer(imageLayer(oldImage))
            moving = imageLayer(newImage)
            from = transform(to: startTile ?? center); to = CATransform3DIdentity
            fromOpacity = 0.4; toOpacity = 1
        case .zoomOut:
            container.addSublayer(imageLayer(newImage))
            moving = imageLayer(oldImage)
            let target = nearestTile(for: oldRoot.url, in: layoutTree)?.frame ?? center
            from = CATransform3DIdentity; to = transform(to: target)
            fromOpacity = 1; toOpacity = 0.3
        }
        container.addSublayer(moving)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.addSublayer(container)
        moving.transform = to
        moving.opacity = toOpacity
        CATransaction.commit()
        animationLayer = container

        let duration: CFTimeInterval = 0.25
        let timing = CAMediaTimingFunction(name: .easeInEaseOut)
        let move = CABasicAnimation(keyPath: "transform")
        move.fromValue = from
        move.toValue = to
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = toOpacity
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.timingFunction = timing

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak container] in
            guard let self, let container, self.animationLayer === container else { return }
            container.removeFromSuperlayer()
            self.animationLayer = nil
        }
        moving.add(group, forKey: "zoom")
        CATransaction.commit()
    }

    /// Bitmap of what the view currently shows.
    private func snapshot() -> CGImage? {
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        let p = convert(event.locationInWindow, from: nil)
        // Like the original (OnLButtonDown → OnMouseMove with lastcur = NULL),
        // re-evaluate the tips so they pick up the new selection.
        defer { hoverTile = nil; updateHover(at: p) }
        if let hit = nodeHitTest(p) {
            selectedNode = hit.file
            selectionFrame = hit.frame
            onSelection?(hit.file)
            if event.clickCount == 2, hit.file.isDirectory, !hit.file.isLeaf {
                onZoomIn?(hit.file)
            }
        } else {
            // Clicking empty space clears the selection.
            selectedNode = nil
            selectionFrame = nil
            onSelection?(nil)
        }
        needsDisplay = true
    }

    /// Right-click: select the tile under the mouse, then show its menu
    /// (original: OnRButtonUp → SelectFolder → TrackPopupMenuEx).
    override func menu(for event: NSEvent) -> NSMenu? {
        let p = convert(event.locationInWindow, from: nil)
        hideTips()
        let hit = nodeHitTest(p)
        selectedNode = hit?.file
        selectionFrame = hit?.frame
        onSelection?(hit?.file)
        needsDisplay = true
        return contextMenuProvider?(hit?.file)
    }

    /// Clears the current selection (used when a new tree replaces the display).
    func clearSelection() {
        selectedNode = nil
        selectionFrame = nil
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    private func nodeHitTest(_ point: CGPoint) -> LayoutNode? {
        guard let root = layoutTree else { return nil }
        var best: LayoutNode?
        func visit(_ ln: LayoutNode) {
            guard ln.frame.contains(point) else { return }
            best = ln
            for c in ln.children where c.frame.contains(point) {
                visit(c)
                return
            }
        }
        visit(root)
        return best
    }

}

// MARK: - Hover: rollover boxes, name tips, info tips

extension TreemapView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .mouseEnteredAndExited,
                                            .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        hoverTile = nil
        hideTips()
        if !hoverChain.isEmpty { hoverChain = []; needsDisplay = true }
    }

    /// Settings changed: re-lay out (density, bias, free space) and redraw
    /// (colors, rollover); tips pick up their new options on the next hover.
    func settingsChanged() {
        hideTips()
        hoverTile = nil
        hoverChain = []
        needsLayout = true
        needsDisplay = true
    }

    /// Drawn tiles under `point`, outermost first (the displayed root itself
    /// is not a tile). Index + 1 is the tile's drawing depth.
    private func tileChain(at point: CGPoint) -> [LayoutNode] {
        var chain: [LayoutNode] = []
        var level = layoutTree?.children ?? []
        while let hit = level.first(where: { $0.frame.contains(point) }) {
            chain.append(hit)
            level = hit.children
        }
        return chain
    }

    /// Port of `CFolderView::OnMouseMove`: rollover highlight, then (re)arm
    /// the name and info tips when the tile under the mouse changes.
    func updateHover(at point: CGPoint) {
        let s = Settings.shared
        let chain = tileChain(at: point)

        // Rollover boxes light every tile containing the point (the original's
        // HighlightPathAtPoint marks each display folder the point is inside).
        let ids = s.rolloverBox ? Set(chain.map(ObjectIdentifier.init)) : []
        if ids != hoverChain { hoverChain = ids; needsDisplay = true }

        // The free-space tile gets no tips (original: names starting with '<').
        let tile = chain.last.flatMap { $0.file.isFreeSpace ? nil : $0 }
        let onBadge = tile.flatMap { sparseBadgeRect(for: $0) }?.contains(point) ?? false
        guard tile !== hoverTile || onBadge != hoverOnBadge else { return }
        hoverTile = tile
        hoverOnBadge = onBadge
        hideTips()
        guard let tile, window != nil else { return }
        let depth = chain.count

        // The sparse badge always explains itself, whatever the tip settings.
        if onBadge {
            schedule(&infoTipTimer, afterMs: s.infoTipDelay) { [weak self] in
                self?.showInfoTip(self?.sparseExplanation(for: tile.file) ?? "", icon: nil)
            }
            return
        }
        if s.showInfoTips {
            let (text, icon) = infoTipContent(for: tile.file, fields: s.infoTipFields)
            if !text.isEmpty || icon != nil {
                schedule(&infoTipTimer, afterMs: s.infoTipDelay) { [weak self] in
                    self?.showInfoTip(text, icon: icon)
                }
            }
        }
        // Name tip only where the label couldn't be drawn (SetupNameTip bails
        // out when the name fits: `if (failed == 2) return`).
        if s.showNameTips, fittedLabel(for: tile, in: labelRect(for: tile)) == nil {
            schedule(&nameTipTimer, afterMs: s.nameTipDelay) { [weak self] in
                self?.showNameTip(for: tile, depth: depth)
            }
        }
    }

    private func schedule(_ timer: inout Timer?, afterMs ms: Int, _ body: @escaping () -> Void) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Double(ms) / 1000, repeats: false) { _ in body() }
    }

    func hideTips() {
        nameTipTimer?.invalidate(); nameTipTimer = nil
        infoTipTimer?.invalidate(); infoTipTimer = nil
        nameTip.hide()
        infoTip.hide()
    }

    /// Original SetupNameTip: the full name in a small box over the tile's
    /// label spot, in the tile's own color (black when selected, bright when
    /// rolled over).
    private func showNameTip(for tile: LayoutNode, depth: Int) {
        guard let window else { return }
        let s = Settings.shared
        let colors = Palette.colors(scheme: tile.file.isDirectory ? s.folderColor : s.fileColor,
                                    depth: depth)
        var bg = colors.fill, fg = NSColor.black
        if selectedNode?.url == tile.file.url {
            bg = .black; fg = .white
        } else if s.rolloverBox, hoverChain.contains(ObjectIdentifier(tile)) {
            bg = colors.bright
        }
        let font = NSFont.systemFont(ofSize: 11, weight: tile.file.isDirectory ? .medium : .regular)
        let r = tile.frame
        let textH = (tile.file.name as NSString).size(withAttributes: [.font: font]).height + 2
        // Folders: at the title bar; files: vertically centered when the text
        // is shorter than the tile (the original's tx/ty rules).
        let top = tile.file.isDirectory || textH > r.height - 2 ? r.maxY : r.midY + textH / 2
        let screen = window.convertPoint(toScreen: convert(CGPoint(x: r.minX, y: top), to: nil))
        nameTip.show(tile.file.name, font: font, background: bg, textColor: fg,
                     padding: NSSize(width: 2, height: 1), topLeft: screen, parent: window)
    }

    /// Original SetupInfoTip: shown near the mouse, the tooltip-yellow box.
    private func showInfoTip(_ text: String, icon: NSImage?) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        infoTip.show(text, icon: icon, font: NSFont.systemFont(ofSize: 11),
                     background: NSColor(calibratedRed: 1, green: 1, blue: 0.88, alpha: 1),
                     topLeft: CGPoint(x: mouse.x + 12, y: mouse.y - 20), parent: window)
    }

    /// The info tip's lines, in the original's order: path + name, size /
    /// attributes, date; the icon goes on the left.
    private func infoTipContent(for file: Node, fields f: Settings.InfoTipFields) -> (String, NSImage?) {
        var lines: [String] = []
        var first = ""
        if f.contains(.path) { first += file.url.deletingLastPathComponent().path + "/" }
        if f.contains(.name) { first += file.name }
        if !first.isEmpty { lines.append(first) }

        var second = ""
        if f.contains(.size) {
            let exact = NumberFormatter.localizedString(from: NSNumber(value: file.size), number: .decimal)
            second = "\(Format.bytes(file.size)) on disk (\(exact) bytes)"
        }
        if f.contains(.attrib) {
            let attrs = attributes(of: file)
            if !attrs.isEmpty { second += (second.isEmpty ? "" : "  /  ") + attrs.joined(separator: " ") }
        }
        if !second.isEmpty { lines.append(second) }
        if f.contains(.size), file.logicalSize != file.size, file.isSparse || !file.isDirectory {
            lines.append("Finder shows \(Format.bytes(file.logicalSize))\(file.isSparse ? " (sparse file)" : "")")
        }
        if f.contains(.date), let date = file.modificationDate {
            lines.append(Self.tipDateFormatter.string(from: date))
        }
        var icon: NSImage?
        if f.contains(.icon) {
            icon = NSWorkspace.shared.icon(forFile: file.url.path)
            icon?.size = NSSize(width: 32, height: 32)
        }
        return (lines.joined(separator: "\n"), icon)
    }

    /// Original PrintDate: "dd Mon yyyy   h:mm:ss".
    private static let tipDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd MMM yyyy   H:mm:ss"
        return f
    }()

    /// macOS equivalents of the original's FILE_ATTRIBUTE_* names, read at
    /// hover time like the original's FindFirstFile call.
    private func attributes(of file: Node) -> [String] {
        var st = stat()
        guard lstat(file.url.path, &st) == 0 else { return [] }
        let flags = UInt32(st.st_flags)
        var out: [String] = []
        if file.isDirectory { out.append("Folder") }
        if flags & UInt32(UF_COMPRESSED) != 0 { out.append("Compress") }
        if flags & UInt32(UF_HIDDEN) != 0 || file.name.hasPrefix(".") { out.append("Hidden") }
        if flags & UInt32(SF_DATALESS) != 0 { out.append("Offline") }
        if st.st_mode & S_IWUSR == 0 { out.append("Read-Only") }
        if flags & (UInt32(UF_IMMUTABLE) | UInt32(SF_IMMUTABLE)) != 0 { out.append("Locked") }
        if file.isSparse { out.append("Sparse") }
        return out
    }
}
