import AppKit
import AuditorCore
import SwiftUI

// MARK: colour

/// Colour that means something, after disktree's palette: every hue at the
/// same muted saturation and lightness so no block shouts by accident,
/// lifting with depth so nesting reads without borders. One strong colour,
/// amber, is kept for the selection and what can be had back.
enum Theme {
    static let canvas = Color(red: 0.082, green: 0.086, blue: 0.118)
    static let amber = Color(red: 0.878, green: 0.686, blue: 0.408)
    static let danger = Color(red: 0.93, green: 0.42, blue: 0.47)
    static let hatch = Color.white.opacity(0.15)
    static let free = hsl(0.40, 0.34, 0.46)

    static func hsl(_ h: Double, _ s: Double, _ l: Double) -> Color {
        let c = (1 - abs(2 * l - 1)) * s
        let x = c * (1 - abs((h * 6).truncatingRemainder(dividingBy: 2) - 1))
        let m = l - c / 2
        let (r, g, b): (Double, Double, Double)
        switch h * 6 {
        case ..<1: (r, g, b) = (c, x, 0)
        case ..<2: (r, g, b) = (x, c, 0)
        case ..<3: (r, g, b) = (0, c, x)
        case ..<4: (r, g, b) = (0, x, c)
        case ..<5: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        return Color(red: r + m, green: g + m, blue: b + m)
    }
}

extension AuditorCore.Category {
    /// The hue, and how much colour it carries: the neutral kinds almost none.
    private var hue: (Double, Double) {
        switch self {
        case .code: return (0.605, 1.0)
        case .agent: return (0.065, 1.0)
        case .toolchain: return (0.415, 1.0)
        case .synced: return (0.535, 1.0)
        case .git: return (0.955, 1.0)
        case .media: return (0.745, 1.0)
        case .cache: return (0.125, 0.95)
        case .apps: return (0.68, 0.55)
        case .documents: return (0.60, 0.18)
        case .other: return (0.60, 0.08)
        }
    }

    /// A tile's fill, `depth` levels into the view.
    func fill(_ depth: Int) -> Color {
        let (h, chroma) = hue
        return Theme.hsl(h, 0.26 * chroma, 0.215 + 0.028 * Double(min(depth, 4)))
    }

    /// The saturated version: legend swatches, strips and bars.
    var accent: Color {
        let (h, chroma) = hue
        return Theme.hsl(h, 0.42 * chroma, 0.52)
    }
}

// MARK: layout

/// One painted rectangle, with its label already fitted to it.
struct Tile {
    let rect: CGRect
    let node: Node?
    let depth: Int
    let category: AuditorCore.Category
    let reclaimable: Bool
    let marked: Bool
    let dim: Bool
    /// The band holding an opened folder's name, when it is drawn open.
    let header: CGRect?
    let name: String
    let size: String?
}

/// Layout after disktree's: 3 px between top-level folders, 1 px inside,
/// a 20 px band for a top-level folder's name and 15 px deeper, tiles under
/// 5 px dropped, and past 96 entries the rest merged into one.
@MainActor
enum Layout {
    static let outer: CGFloat = 1.5
    static let inner: CGFloat = 0.5
    static let header: CGFloat = 20
    static let headerInner: CGFloat = 15
    static let minTile: CGFloat = 5
    static let maxChildren = 96
    static let nameFont = NSFont.systemFont(ofSize: 11.5)
    static let boldFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let sizeFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    struct Context {
        let model: Model
        let maxDepth: Int
        let filter: String
    }

    static func tiles(_ node: Node, in rect: CGRect, _ c: Context, depth: Int = 0, reclaimable: Bool, marked: Bool, matched: Bool = false) -> [Tile] {
        var entries: [(Node?, String, UInt64)] = node.children.prefix(maxChildren).filter { $0.bytes > 0 }.map { ($0, $0.name, $0.bytes) }
        let restCount = max(0, node.children.count - maxChildren)
        let rest = node.children.dropFirst(maxChildren).reduce(UInt64(0)) { $0 + $1.bytes } + node.looseBytes
        if rest > 0 { entries.append((nil, restCount > 0 ? "\(restCount) more" : "files", rest)) }

        var out: [Tile] = []
        for (entry, raw) in zip(entries, Treemap.layout(entries.map { Double($0.2) }, in: rect)) {
            let box = raw.insetBy(dx: depth == 0 ? outer : inner, dy: depth == 0 ? outer : inner)
            guard box.width >= minTile, box.height >= minTile else { continue }
            let child = entry.0
            let finding = child.flatMap { c.model.finding(for: $0) }
            let hatch = reclaimable || (finding?.safe ?? false)
            let isMarked = marked || (child.map { c.model.marks.contains($0.path) } ?? false)
            // Filtering: a match, anything inside one, and the folders on
            // the way down to one keep their colour.
            let hit = matched || (child.map { c.model.matches($0) } ?? false)
            let dim = !c.model.onPath.isEmpty && !hit && !(child.map { c.model.onPath.contains(ObjectIdentifier($0)) } ?? false)
            let band = depth == 0 ? header : headerInner
            let opens = child.map { $0.isDir && !$0.children.isEmpty } ?? false
                && depth < c.maxDepth - 1 && box.width > 40 && box.height > band + 12
            let headerRect = opens ? CGRect(x: box.minX, y: box.minY, width: box.width, height: band) : nil
            let font = depth == 0 && opens ? boldFont : nameFont
            let sizeText = Format.size(entry.2)
            let labelWidth = box.width - 10
            var name = fit(entry.1, font, labelWidth)
            var size: String? = nil
            if let name2 = name, opens {
                // In a band: name left, size right when both fit.
                let sizeW = width(sizeText, sizeFont) + 10
                if width(name2, font) + sizeW <= labelWidth { size = sizeText } else { name = fit(entry.1, font, labelWidth) }
            } else if name != nil, box.height >= 32 {
                size = width(sizeText, sizeFont) <= labelWidth ? sizeText : nil
            }
            out.append(Tile(
                rect: box, node: child, depth: depth, category: child?.category ?? node.category,
                reclaimable: hatch, marked: isMarked, dim: dim, header: headerRect,
                name: box.height >= 14 ? (name ?? "") : "", size: size
            ))
            if opens, let child {
                let body = CGRect(x: box.minX, y: box.minY + band, width: box.width, height: box.height - band)
                out += tiles(child, in: body, c, depth: depth + 1, reclaimable: hatch, marked: isMarked, matched: hit)
            }
        }
        return out
    }

    static func width(_ text: String, _ font: NSFont) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font]).width
    }

    /// The name, shortened with an ellipsis to fit; nil when not even three
    /// letters would, so a tile shows nothing rather than a stub.
    static func fit(_ text: String, _ font: NSFont, _ available: CGFloat) -> String? {
        if width(text, font) <= available { return text }
        var low = 0
        var high = text.count
        while low < high {
            let mid = (low + high + 1) / 2
            if width(String(text.prefix(mid)) + "…", font) <= available { low = mid } else { high = mid - 1 }
        }
        return low >= 3 ? String(text.prefix(low)) + "…" : nil
    }
}

/// Tiles for one view, kept until something that changes them changes.
@MainActor
final class TileCache {
    struct Key: Hashable {
        let node: ObjectIdentifier
        let size: CGSize
        let depth: Int
        let filter: String
        let marks: Marks
        let findings: Int
        let matched: Int
        let scan: ObjectIdentifier
    }

    private var key: Key?
    private(set) var tiles: [Tile] = []

    func tiles(for model: Model, size: CGSize) -> [Tile] {
        guard let current = model.current, let scan = model.scan else { return [] }
        let key = Key(node: ObjectIdentifier(current), size: size, depth: model.depth, filter: model.filter,
                      marks: model.marks, findings: model.findings.count &* 31 &+ Int(model.reclaimable % 1_000_003),
                      matched: model.onPath.count &* 31 &+ model.matchCount,
                      scan: ObjectIdentifier(scan.root))
        if key != self.key {
            let context = Layout.Context(model: model, maxDepth: model.depth, filter: model.filter)
            let covering = model.covering(current)
            tiles = Layout.tiles(current, in: CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2), context,
                                 reclaimable: covering?.safe ?? false, marked: model.isMarked(current))
            self.key = key
        }
        return tiles
    }
}

// MARK: view

struct TreemapView: View {
    @ObservedObject var model: Model
    @State private var cache = TileCache()

    var body: some View {
        GeometryReader { geo in
            let tiles = cache.tiles(for: model, size: geo.size)
            ZStack {
                Canvas(rendersAsynchronously: false) { context, _ in
                    for tile in tiles { paint(tile, in: &context) }
                    if let node = model.selected, let tile = tiles.last(where: { $0.node === node }) {
                        context.stroke(Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 1.5),
                                       with: .color(Theme.amber), lineWidth: 2)
                    }
                }
                .id(model.current.map(ObjectIdentifier.init))
                .transition(.opacity)
                HoverOutline(hover: model.hover, tiles: tiles)
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { tap in
                    if let node = hit(tiles, tap.location) { model.open(node.isDir ? node : (node.parent ?? node)) }
                }.exclusively(before: SpatialTapGesture().onEnded { tap in
                    model.selected = hit(tiles, tap.location)
                })
            )
            .onContinuousHover { phase in
                let node: Node? = if case .active(let point) = phase { hit(tiles, point) } else { nil }
                if model.hover.node !== node { model.hover.node = node }
            }
            .contextMenu {
                if let node = model.hover.node ?? model.selected {
                    Button(model.isMarked(node) ? "Unmark" : "Mark for Removal") { model.toggleMark(node) }
                    if node.isDir { Button("Open") { model.open(node) } }
                    if node.isDir { Button("Look Inside") { model.selected = node; model.lookInside() } }
                    Divider()
                    Button("Show in Finder") { model.showInFinder(node.path) }
                    Button("Copy Path") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.path, forType: .string)
                    }
                }
            }
        }
        .background(Theme.canvas)
    }

    /// The deepest real entry under the point.
    private func hit(_ tiles: [Tile], _ point: CGPoint) -> Node? {
        tiles.last { $0.node != nil && $0.rect.contains(point) }?.node
    }

    private func paint(_ tile: Tile, in context: inout GraphicsContext) {
        let r = tile.rect
        let shape = Path(r)
        var fill = tile.category.fill(tile.depth)
        if tile.marked { fill = Theme.danger.opacity(0.55) }
        context.fill(shape, with: .color(fill))
        if tile.node == nil { context.fill(shape, with: .color(.black.opacity(0.18))) }
        if tile.reclaimable && !tile.marked { hatch(r, in: &context) }
        // A top-level folder carries a thin strip of its colour, so the
        // first level of structure reads before any detail.
        if tile.depth == 0 {
            context.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: min(2, r.height))),
                         with: .color(tile.category.accent))
        }
        if tile.dim { context.fill(shape, with: .color(Theme.canvas.opacity(0.72))) }
        guard !tile.name.isEmpty else { return }
        let area = tile.header ?? r
        var label = context
        label.clip(to: Path(area))
        let bold = tile.depth == 0 && tile.header != nil
        let color: Color = tile.marked ? .white : .white.opacity(tile.depth == 0 ? 0.94 : 0.84)
        let name = Text(tile.name).font(.system(size: 11.5, weight: bold ? .semibold : .regular)).foregroundColor(color)
        let top = area.minY + (tile.header == nil ? 4 : (area.height - 14) / 2)
        label.draw(name, at: CGPoint(x: area.minX + 5, y: top), anchor: .topLeading)
        if let size = tile.size {
            let text = Text(size).font(.system(size: 10.5).monospacedDigit()).foregroundColor(.white.opacity(0.48))
            if tile.header != nil {
                label.draw(text, at: CGPoint(x: area.maxX - 5, y: top + 0.5), anchor: .topTrailing)
            } else {
                label.draw(text, at: CGPoint(x: area.minX + 5, y: top + 15), anchor: .topLeading)
            }
        }
    }

    /// Diagonal lines: space that can be had back, whatever its colour.
    private func hatch(_ r: CGRect, in context: inout GraphicsContext) {
        var lines = Path()
        var x = (r.minX - r.height).rounded(.down)
        x -= x.truncatingRemainder(dividingBy: 6)
        while x < r.maxX {
            lines.move(to: CGPoint(x: x, y: r.maxY))
            lines.addLine(to: CGPoint(x: x + r.height, y: r.minY))
            x += 6
        }
        var clipped = context
        clipped.clip(to: Path(r))
        clipped.stroke(lines, with: .color(Theme.hatch), lineWidth: 1)
    }
}

/// The pointer's outline, on its own layer: moving the mouse repaints this
/// and nothing else.
struct HoverOutline: View {
    @ObservedObject var hover: Hover
    let tiles: [Tile]

    var body: some View {
        Canvas { context, _ in
            guard let node = hover.node, let tile = tiles.last(where: { $0.node === node }) else { return }
            context.stroke(Path(tile.rect.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
