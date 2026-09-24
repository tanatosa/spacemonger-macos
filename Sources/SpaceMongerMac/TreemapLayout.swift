import Foundation
import CoreGraphics

/// Layout node used by the renderer: pairs a data `Node` with a computed frame
/// and any laid-out children (which draws the nested treemap).
final class LayoutNode {
    let file: Node
    var frame: CGRect = .zero
    var children: [LayoutNode] = []

    init(file: Node) { self.file = file }
}

/// Builds a nested treemap from a `Node` tree into the given rect, using the
/// original's greedy balanced binary-split algorithm (`CFolderView::SizeFolders`):
/// the size-sorted entries are split into two lists whose summed sizes are as
/// equal as possible, the container is split proportionally (horizontally or
/// vertically depending on `bias`), and each half recurses.
///
/// Recursion into a folder happens only when its tile is large enough
/// (`w > hmin && h > vmin`), and the inner area is inset by (+3, top
/// `folderTitleBarHeight`, -6 width, bottom 3) — the original's title-bar
/// reservation, with a slightly taller bar for macOS fonts.
func buildLayout(for node: Node, in rect: CGRect,
                 hmin: CGFloat = 32, vmin: CGFloat = 24,
                 bias: Int = 0, showFreeSpace: Bool = true) -> LayoutNode {
    let ln = LayoutNode(file: node)
    ln.frame = rect
    let indices = Array(0..<node.children.count)
    ln.children = sizeFolders(node, indices, in: rect, depth: 0,
                              bias: bias, showFreeSpace: showFreeSpace,
                              hmin: hmin, vmin: vmin)
    return ln
}

/// Height reserved at the top of a recursed folder tile for its name. The
/// original used 12 px (y+12, h-15); macOS system fonts need a little more.
let folderTitleBarHeight: CGFloat = 15

/// Port of `CFolderView::SizeFolders`. Returns the tiles drawn at this level;
/// a tile that is recursed into carries its nested layout in `children`.
private func sizeFolders(_ folder: Node, _ index: [Int], in rect: CGRect, depth: Int,
                         bias: Int, showFreeSpace: Bool,
                         hmin: CGFloat, vmin: CGFloat) -> [LayoutNode] {
    var list1: [Int] = [], list2: [Int] = []
    var sum1 = 0.0, sum2 = 0.0

    // Split the lists evenly. Entries are sorted descending by size, so this
    // greedy assignment balances the two halves (original logic). Entries with
    // zero weight — including the free-space tile when showFreeSpace is off —
    // are skipped and never drawn.
    for i in index {
        var weight = Double(max(folder.children[i].size, 0))
        if folder.children[i].isFreeSpace && !showFreeSpace { weight = 0 }
        if weight != 0 {
            if sum1 <= sum2 {
                list1.append(i); sum1 += weight
            } else {
                list2.append(i); sum2 += weight
            }
        }
    }

    // Don't bother if the entries have no space.
    guard sum1 + sum2 > 0 else { return [] }

    let x = rect.minX, y = rect.minY, w = rect.width, h = rect.height

    // Split bias (original: wbias/hbias derived from m_settings.bias).
    var wbias = 8.0, hbias = 8.0
    if bias > 0 { wbias = Double(bias) + 8; hbias = 8 }
    else if bias < 0 { hbias = Double(-bias) + 8; wbias = 8 }

    var r1: CGRect, r2: CGRect
    if (Double(w) * wbias / 8) > (Double(h) * hbias / 8) {
        let split = CGFloat((Double(w) * sum1) / (sum1 + sum2))
        r1 = CGRect(x: x, y: y, width: split, height: h)
        r2 = CGRect(x: x + split, y: y, width: w - split, height: h)
    } else {
        let split = CGFloat((Double(h) * sum1) / (sum1 + sum2))
        r1 = CGRect(x: x, y: y, width: w, height: split)
        r2 = CGRect(x: x, y: y + split, width: w, height: h - split)
    }

    // Now if a half contains more than one entry and is large enough to be
    // subdivided again, subdivide again (original recursion gate:
    // numlist > 1 && w > hmin && h > vmin).
    var tiles: [LayoutNode] = []
    for (list, r) in [(list1, r1), (list2, r2)] {
        if list.count > 1 && r.width > hmin && r.height > vmin {
            tiles += sizeFolders(folder, list, in: r, depth: depth,
                                 bias: bias, showFreeSpace: showFreeSpace,
                                 hmin: hmin, vmin: vmin)
        } else if let i = list.first {
            let child = folder.children[i]
            let tile = LayoutNode(file: child)
            tile.frame = r
            // A folder tile large enough shows its children inside an inset
            // area (original: x+3, y+12, w-6, h-15 for the title bar).
            if child.isDirectory && !child.children.isEmpty,
               r.width > hmin && r.height > vmin {
                // The view is not flipped, so the title bar is the top strip
                // (maxY side) and the original's 3 px bottom margin sits at minY.
                let inner = CGRect(x: r.minX + 3, y: r.minY + 3,
                                   width: r.width - 6, height: r.height - folderTitleBarHeight - 3)
                tile.children = sizeFolders(child, Array(0..<child.children.count),
                                            in: inner, depth: depth + 1,
                                            bias: bias, showFreeSpace: showFreeSpace,
                                            hmin: hmin, vmin: vmin)
            }
            tiles.append(tile)
        }
    }
    return tiles
}

/// Stable descending sort of indices `0..<count` by 64-bit `score`, using eight
/// passes of an 8-bit counting sort — a direct port of the original's
/// `EightBitCountingSort` with its `VALUE()` macro (`0xFF - byte`), so entries
/// are ordered size-descending with ties keeping their scan order.
func countingRadixSortDescending(_ count: Int, score: (Int) -> UInt64) -> [Int] {
    guard count > 1 else { return Array(0..<count) }

    var scores = [UInt64](repeating: 0, count: count)
    for i in 0..<count { scores[i] = score(i) }

    var order = Array(0..<count)
    var aux = [Int](repeating: 0, count: count)

    for shift in stride(from: 0, to: 64, by: 8) {
        // 1. Count into buckets keyed by the inverted byte (descending order).
        var start = [Int](repeating: 0, count: 256)
        for s in scores { start[0xFF - Int((s >> shift) & 0xFF)] += 1 }

        // 2. Turn counts into stable starting offsets.
        var running = 0
        for j in 0..<256 { let c = start[j]; start[j] = running; running += c }

        // 3. Place each index into its bucket (stable).
        for i in 0..<count {
            let radix = 0xFF - Int((scores[order[i]] >> shift) & 0xFF)
            aux[start[radix]] = order[i]
            start[radix] += 1
        }
        swap(&order, &aux)
    }
    return order
}