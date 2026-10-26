import CoreGraphics

/// Maps any point of the key area to a key. Regions are the key caps grown so that the gaps between keys are split
/// at their midpoint (nearest-key behaviour like the system keyboard), edge keys extend to the container edge and
/// the first/last row extend to the strip / container bottom, so the regions tile the key area with no holes.
///
/// Lookups do not allocate (touch path budget, ROADMAP §6).
public struct HitModel: Sendable, Equatable {
    struct Cell: Sendable, Equatable {
        var minX: CGFloat
        var maxX: CGFloat
        var keyIndex: Int
    }

    struct Row: Sendable, Equatable {
        var minY: CGFloat
        var maxY: CGFloat
        var cells: [Cell]
    }

    let rows: [Row]
    public let keyArea: CGRect

    /// Strict lookup: nil when `point` is outside the key area.
    public func keyIndex(at point: CGPoint) -> Int? {
        guard keyArea.minX <= point.x, point.x <= keyArea.maxX,
              keyArea.minY <= point.y, point.y <= keyArea.maxY else { return nil }
        return lookup(clamped: point)
    }

    /// Lookup that clamps `point` into the key area first (a finger that drifted off the keyboard still maps to the
    /// nearest key).
    public func nearestKeyIndex(to point: CGPoint) -> Int? {
        let p = CGPoint(
            x: min(max(point.x, keyArea.minX), keyArea.maxX),
            y: min(max(point.y, keyArea.minY), keyArea.maxY)
        )
        return lookup(clamped: p)
    }

    func lookup(clamped p: CGPoint) -> Int? {
        guard !rows.isEmpty else { return nil }
        var rowIndex = rows.count - 1
        for i in 0..<rows.count where p.y < rows[i].maxY {
            rowIndex = i
            break
        }
        let cells = rows[rowIndex].cells
        for c in cells where p.x < c.maxX { return c.keyIndex }
        return cells.last?.keyIndex
    }

    static func build(frames: [CGRect], rowOfKey: [Int], keyArea: CGRect) -> (model: HitModel, regions: [CGRect]) {
        var byRow: [Int: [Int]] = [:]
        for (i, r) in rowOfKey.enumerated() { byRow[r, default: []].append(i) }
        let rowIDs = byRow.keys.sorted()

        // Vertical bands: split each inter-row gap at its midpoint.
        let spans: [(top: CGFloat, bottom: CGFloat)] = rowIDs.map { r in
            let idx = byRow[r]!
            return (idx.map { frames[$0].minY }.min()!, idx.map { frames[$0].maxY }.max()!)
        }
        var rows: [Row] = []
        var regions = [CGRect](repeating: .zero, count: frames.count)
        for (n, r) in rowIDs.enumerated() {
            let top = n == 0 ? keyArea.minY : (spans[n - 1].bottom + spans[n].top) / 2
            let bottom = n == rowIDs.count - 1 ? keyArea.maxY : (spans[n].bottom + spans[n + 1].top) / 2
            let sorted = byRow[r]!.sorted { frames[$0].minX < frames[$1].minX }
            var cells: [Cell] = []
            for (k, idx) in sorted.enumerated() {
                let minX = k == 0 ? keyArea.minX : (frames[sorted[k - 1]].maxX + frames[idx].minX) / 2
                let maxX = k == sorted.count - 1 ? keyArea.maxX : (frames[idx].maxX + frames[sorted[k + 1]].minX) / 2
                cells.append(Cell(minX: minX, maxX: maxX, keyIndex: idx))
                regions[idx] = CGRect(x: minX, y: top, width: maxX - minX, height: bottom - top)
            }
            rows.append(Row(minY: top, maxY: bottom, cells: cells))
        }
        return (HitModel(rows: rows, keyArea: keyArea), regions)
    }
}
