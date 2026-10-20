import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing, van Wijk): rectangles whose
/// areas are proportional to their sizes and as close to square as the
/// order allows, so small things stay clickable.
public enum Treemap {
    /// One rectangle per size, in the same order. Zero sizes get `.zero`.
    public static func layout(_ sizes: [Double], in rect: CGRect) -> [CGRect] {
        var out = Array(repeating: CGRect.zero, count: sizes.count)
        let total = sizes.reduce(0) { $0 + max($1, 0) }
        guard total > 0, rect.width > 0, rect.height > 0 else { return out }
        let scale = Double(rect.width * rect.height) / total
        let order = sizes.indices.filter { sizes[$0] > 0 }.sorted { sizes[$0] > sizes[$1] }
        let area = sizes.map { max($0, 0) * scale }
        var free = rect
        var i = 0
        while i < order.count {
            let side = Double(min(free.width, free.height))
            var row = [order[i]]
            var rowArea = area[order[i]]
            var best = worst(row.map { area[$0] }, rowArea, side)
            var j = i + 1
            // Grow the row while that keeps its worst aspect ratio improving.
            while j < order.count {
                let candidate = worst(row.map { area[$0] } + [area[order[j]]], rowArea + area[order[j]], side)
                if candidate > best { break }
                row.append(order[j])
                rowArea += area[order[j]]
                best = candidate
                j += 1
            }
            let thickness = CGFloat(rowArea / side)
            var offset: CGFloat = 0
            if free.width >= free.height {
                for k in row {
                    let length = CGFloat(area[k]) / thickness
                    out[k] = CGRect(x: free.minX, y: free.minY + offset, width: thickness, height: length)
                    offset += length
                }
                free = CGRect(x: free.minX + thickness, y: free.minY, width: max(0, free.width - thickness), height: free.height)
            } else {
                for k in row {
                    let length = CGFloat(area[k]) / thickness
                    out[k] = CGRect(x: free.minX + offset, y: free.minY, width: length, height: thickness)
                    offset += length
                }
                free = CGRect(x: free.minX, y: free.minY + thickness, width: free.width, height: max(0, free.height - thickness))
            }
            i = j
        }
        return out
    }

    /// The worst aspect ratio in a row laid along a side of this length.
    private static func worst(_ areas: [Double], _ sum: Double, _ side: Double) -> Double {
        guard let big = areas.max(), let small = areas.min(), small > 0, sum > 0 else { return .infinity }
        let s2 = side * side
        return max(s2 * big / (sum * sum), (sum * sum) / (s2 * small))
    }
}
