import AppKit
import SwiftUI

enum Side { case center, right, left }

struct NodeLayout: Identifiable {
    let id: UUID
    let title: String
    let depth: Int
    let branch: Int
    let side: Side
    let parentID: UUID?
    let frame: CGRect
    let collapsed: Bool
    let childCount: Int
}

struct MapLayout {
    private(set) var nodes: [NodeLayout] = []
    private(set) var index: [UUID: Int] = [:]
    private(set) var bounds: CGRect = .zero

    subscript(id: UUID) -> NodeLayout? { index[id].map { nodes[$0] } }

    mutating func append(_ n: NodeLayout) {
        index[n.id] = nodes.count
        nodes.append(n)
        bounds = nodes.count == 1 ? n.frame : bounds.union(n.frame)
    }
}

enum NodeStyle {
    static let placeholder = "主题"
    static let maxTextWidth: CGFloat = 260

    static func fontSize(_ d: Int) -> CGFloat { d == 0 ? 22 : d == 1 ? 16 : 14 }
    static func weight(_ d: Int) -> NSFont.Weight { d == 0 ? .semibold : d == 1 ? .medium : .regular }
    static func nsFont(_ d: Int) -> NSFont { .systemFont(ofSize: fontSize(d), weight: weight(d)) }
    static func font(_ d: Int) -> Font { Font(nsFont(d) as CTFont) }
    static func padding(_ d: Int) -> CGSize {
        d == 0 ? CGSize(width: 26, height: 15) : d == 1 ? CGSize(width: 16, height: 9) : CGSize(width: 11, height: 6)
    }
    static func corner(_ d: Int) -> CGFloat { d == 0 ? 16 : d == 1 ? 11 : 8 }
    static func minWidth(_ d: Int) -> CGFloat { d == 0 ? 120 : d == 1 ? 64 : 44 }
}

@MainActor
enum LayoutEngine {
    private static var cache: [String: CGSize] = [:]

    static func measure(_ text: String, depth: Int) -> CGSize {
        let d = min(depth, 2)
        let t = text.isEmpty ? NodeStyle.placeholder : text
        let key = "\(d)|\(t)"
        if let s = cache[key] { return s }
        let rect = (t as NSString).boundingRect(
            with: CGSize(width: NodeStyle.maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NodeStyle.nsFont(d)])
        let pad = NodeStyle.padding(d)
        let size = CGSize(width: max(ceil(rect.width) + 4 + pad.width * 2, NodeStyle.minWidth(d)),
                          height: ceil(rect.height) + pad.height * 2)
        if cache.count > 4000 { cache.removeAll() }
        cache[key] = size
        return size
    }

    static func compute(_ root: MindNode, style: LayoutStyle, override: (UUID, String)? = nil) -> MapLayout {
        var sizes: [UUID: CGSize] = [:]
        var subH: [UUID: CGFloat] = [:]

        func title(_ n: MindNode) -> String {
            if let o = override, o.0 == n.id { return o.1 }
            return n.title
        }
        func vGap(_ childDepth: Int) -> CGFloat { childDepth == 1 ? 26 : 12 }
        func hGap(_ childDepth: Int) -> CGFloat { childDepth == 1 ? 64 : 40 }

        @discardableResult
        func measureTree(_ n: MindNode, _ depth: Int) -> CGFloat {
            let s = measure(title(n), depth: depth)
            sizes[n.id] = s
            var h = s.height
            if !n.collapsed && !n.children.isEmpty {
                let total = n.children.reduce(0) { $0 + measureTree($1, depth + 1) }
                    + vGap(depth + 1) * CGFloat(n.children.count - 1)
                h = max(h, total)
            }
            subH[n.id] = h
            return h
        }
        measureTree(root, 0)

        var layout = MapLayout()

        func place(_ n: MindNode, depth: Int, side: Side, anchorX: CGFloat, centerY: CGFloat, branch: Int, parent: UUID) {
            let s = sizes[n.id]!
            let x = side == .left ? anchorX - s.width : anchorX
            let frame = CGRect(x: x, y: centerY - s.height / 2, width: s.width, height: s.height)
            layout.append(NodeLayout(id: n.id, title: title(n), depth: depth, branch: branch, side: side,
                                     parentID: parent, frame: frame, collapsed: n.collapsed, childCount: n.children.count))
            if !n.collapsed && !n.children.isEmpty {
                placeChildren(n.children, depth: depth + 1, side: side, from: frame, branch: { _, k in k.colorIndex ?? branch }, parent: n.id)
            }
        }

        func placeChildren(_ kids: [MindNode], depth: Int, side: Side, from frame: CGRect,
                           branch: (Int, MindNode) -> Int, parent: UUID) {
            guard !kids.isEmpty else { return }
            let g = vGap(depth)
            let total = kids.reduce(0) { $0 + subH[$1.id]! } + g * CGFloat(kids.count - 1)
            var y = frame.midY - total / 2
            let ax = side == .left ? frame.minX - hGap(depth) : frame.maxX + hGap(depth)
            for (i, k) in kids.enumerated() {
                let h = subH[k.id]!
                place(k, depth: depth, side: side, anchorX: ax, centerY: y + h / 2, branch: branch(i, k), parent: parent)
                y += h + g
            }
        }

        let rs = sizes[root.id]!
        let rootFrame = CGRect(x: -rs.width / 2, y: -rs.height / 2, width: rs.width, height: rs.height)
        layout.append(NodeLayout(id: root.id, title: title(root), depth: 0, branch: 0, side: .center, parentID: nil,
                                 frame: rootFrame, collapsed: root.collapsed, childCount: root.children.count))

        if !root.collapsed && !root.children.isEmpty {
            let kids = root.children
            var branchOf: [UUID: Int] = [:]
            for (i, k) in kids.enumerated() { branchOf[k.id] = k.colorIndex ?? i }
            let pick: (Int, MindNode) -> Int = { _, k in branchOf[k.id]! }

            if style == .right {
                placeChildren(kids, depth: 1, side: .right, from: rootFrame, branch: pick, parent: root.id)
            } else {
                let heights = kids.map { subH[$0.id]! }
                let total = heights.reduce(0, +)
                var acc: CGFloat = 0, rc = 0
                for h in heights {
                    if rc > 0 && acc >= total / 2 { break }
                    acc += h; rc += 1
                }
                placeChildren(Array(kids[..<rc]), depth: 1, side: .right, from: rootFrame, branch: pick, parent: root.id)
                placeChildren(Array(kids[rc...].reversed()), depth: 1, side: .left, from: rootFrame, branch: pick, parent: root.id)
            }
        }
        return layout
    }
}
