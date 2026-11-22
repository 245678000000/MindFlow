import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MapTransform {
    var origin: CGPoint
    var scale: CGFloat
    func apply(_ p: CGPoint) -> CGPoint { CGPoint(x: origin.x + p.x * scale, y: origin.y + p.y * scale) }
}

@MainActor
@Observable
final class MapViewModel {
    var document: Binding<MindMapDocument>?
    var selection: UUID?
    var editingID: UUID?
    var draft = ""
    var pan: CGSize = .zero
    var scale: CGFloat = 1
    var viewSize: CGSize = .zero
    var dragID: UUID?
    var dragOffset: CGSize = .zero
    var dropTargetID: UUID?
    var focusTick = 0
    /// Bumped on every edit made through `mutate`; observable, unlike the document binding.
    var revision = 0

    // MARK: Data

    var data: MapData { document?.wrappedValue.data ?? .sample }
    var theme: MapTheme { Themes.at(data.theme) }
    var editingOverride: (UUID, String)? { editingID.map { ($0, draft) } }
    var layout: MapLayout { LayoutEngine.compute(data.root, style: data.layout, override: editingOverride) }

    func mutate(_ body: (inout MapData) -> Void) {
        guard let document else { return }
        var d = document.wrappedValue.data
        body(&d)
        if d != document.wrappedValue.data {
            document.wrappedValue.data = d
            revision += 1
        }
    }

    // MARK: Coordinates

    var transform: MapTransform {
        MapTransform(origin: CGPoint(x: viewSize.width / 2 + pan.width, y: viewSize.height / 2 + pan.height), scale: scale)
    }

    func toContent(_ p: CGPoint) -> CGPoint {
        let o = transform.origin
        return CGPoint(x: (p.x - o.x) / scale, y: (p.y - o.y) / scale)
    }

    func requestFocus() { focusTick += 1 }

    // MARK: Selection & editing

    func select(_ id: UUID?) {
        if editingID != nil && editingID != id { commitEdit() }
        selection = id
    }

    func beginEdit(_ id: UUID? = nil) {
        guard let id = id ?? selection, let n = data.root.find(id) else { return }
        selection = id
        draft = n.title
        editingID = id
        ensureVisible(id)
    }

    func commitEdit() {
        guard let id = editingID else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        mutate { d in d.root.modify(id) { if $0.title != text { $0.title = text } } }
        requestFocus()
    }

    func cancelEdit() {
        editingID = nil
        requestFocus()
    }

    // MARK: Structure edits

    private func depth(of id: UUID) -> Int { layout[id]?.depth ?? 0 }

    func addChild() {
        commitEdit()
        let target = selection ?? data.root.id
        let new = MindNode(title: depth(of: target) == 0 ? "分支主题" : "子主题")
        mutate { d in d.root.modify(target) { $0.children.append(new); $0.collapsed = false } }
        selection = new.id
        beginEditSoon(new.id)
    }

    func addSibling() {
        commitEdit()
        guard let sel = selection, let pid = data.root.parentID(of: sel) else { addChild(); return }
        let new = MindNode(title: depth(of: sel) == 1 ? "分支主题" : "子主题")
        mutate { d in
            d.root.modify(pid) { p in
                let i = p.children.firstIndex { $0.id == sel } ?? (p.children.count - 1)
                p.children.insert(new, at: i + 1)
            }
        }
        selection = new.id
        beginEditSoon(new.id)
    }

    private func beginEditSoon(_ id: UUID) {
        DispatchQueue.main.async { self.beginEdit(id) }
    }

    func deleteSelection() {
        if editingID != nil { return }
        guard let sel = selection, sel != data.root.id,
              let pid = data.root.parentID(of: sel), let parent = data.root.find(pid),
              let i = parent.children.firstIndex(where: { $0.id == sel }) else { return }
        let sib = parent.children
        let next = i + 1 < sib.count ? sib[i + 1].id : (i > 0 ? sib[i - 1].id : pid)
        mutate { d in _ = d.root.remove(sel) }
        selection = next
    }

    func toggleCollapse(_ id: UUID? = nil) {
        guard let id = id ?? selection, let n = data.root.find(id), !n.children.isEmpty else { return }
        commitEdit()
        mutate { d in d.root.modify(id) { $0.collapsed.toggle() } }
    }

    func setColor(_ index: Int?, for id: UUID? = nil) {
        guard let id = id ?? selection else { return }
        mutate { d in d.root.modify(id) { $0.colorIndex = index } }
    }

    func setTheme(_ i: Int) { mutate { $0.theme = i } }
    func setLayout(_ l: LayoutStyle) { mutate { $0.layout = l } }

    func move(_ id: UUID, to target: UUID) {
        guard id != data.root.id, id != target,
              let moving = data.root.find(id), !moving.contains(target) else { return }
        mutate { d in
            if let n = d.root.remove(id) {
                d.root.modify(target) { $0.children.append(n); $0.collapsed = false }
            }
        }
        selection = id
    }

    // MARK: Drag & drop reparenting

    func dragChanged(_ id: UUID, translation: CGSize, location: CGPoint) {
        if dragID != id { commitEdit(); dragID = id; selection = id }
        dragOffset = translation
        let p = toContent(location)
        let moving = data.root.find(id)
        dropTargetID = layout.nodes.first { n in
            n.id != id && !(moving?.contains(n.id) ?? false) && n.frame.insetBy(dx: -8, dy: -8).contains(p)
        }?.id
    }

    func dragEnded() {
        if let id = dragID, let t = dropTargetID { move(id, to: t) }
        dragID = nil
        dragOffset = .zero
        dropTargetID = nil
    }

    // MARK: Keyboard navigation

    enum Direction { case up, down, left, right }

    func navigate(_ dir: Direction) {
        let L = layout
        guard let sel = selection, let cur = L[sel] else { selection = data.root.id; return }
        var target: UUID?
        switch dir {
        case .left, .right:
            let outward = cur.side == .center || (dir == .right) == (cur.side == .right)
            if outward {
                let wanted: Side = dir == .right ? .right : .left
                target = L.nodes
                    .filter { $0.parentID == sel && (cur.side != .center || $0.side == wanted) }
                    .min { abs($0.frame.midY - cur.frame.midY) < abs($1.frame.midY - cur.frame.midY) }?.id
            } else {
                target = cur.parentID
            }
        case .up, .down:
            let up = dir == .up
            target = L.nodes
                .filter { n in
                    n.id != sel && n.side == cur.side && n.side != .center &&
                    (up ? n.frame.midY < cur.frame.midY - 1 : n.frame.midY > cur.frame.midY + 1)
                }
                .min { a, b in score(a, cur) < score(b, cur) }?.id
        }
        if let target { selection = target; ensureVisible(target) }
    }

    private func score(_ n: NodeLayout, _ cur: NodeLayout) -> CGFloat {
        abs(n.frame.midY - cur.frame.midY) + abs(n.frame.midX - cur.frame.midX) * 1.5
            + (n.depth == cur.depth ? 0 : 40)
    }

    // MARK: Viewport

    func zoom(to newScale: CGFloat, anchor: CGPoint? = nil) {
        let s = min(max(newScale, 0.2), 3)
        let a = anchor ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let p = toContent(a)
        scale = s
        pan = CGSize(width: a.x - viewSize.width / 2 - p.x * s, height: a.y - viewSize.height / 2 - p.y * s)
    }

    func zoomIn() { withAnimation(.easeOut(duration: 0.18)) { zoom(to: scale * 1.2) } }
    func zoomOut() { withAnimation(.easeOut(duration: 0.18)) { zoom(to: scale / 1.2) } }
    func actualSize() { withAnimation(.easeOut(duration: 0.2)) { zoom(to: 1) } }

    func fit() {
        let b = layout.bounds.insetBy(dx: -60, dy: -60)
        guard viewSize.width > 0, b.width > 0 else { return }
        let s = min(max(min(viewSize.width / b.width, viewSize.height / b.height, 1.5), 0.2), 3)
        withAnimation(.easeInOut(duration: 0.25)) {
            scale = s
            pan = CGSize(width: -b.midX * s, height: -b.midY * s)
        }
    }

    func centerRoot() {
        withAnimation(.easeInOut(duration: 0.25)) { pan = .zero }
    }

    func ensureVisible(_ id: UUID) {
        guard let f = layout[id]?.frame, viewSize.width > 0 else { return }
        let t = transform
        let tl = t.apply(f.origin), br = t.apply(CGPoint(x: f.maxX, y: f.maxY))
        let m: CGFloat = 40
        var dx: CGFloat = 0, dy: CGFloat = 0
        if tl.x < m { dx = m - tl.x } else if br.x > viewSize.width - m { dx = viewSize.width - m - br.x }
        if tl.y < m { dy = m - tl.y } else if br.y > viewSize.height - m { dy = viewSize.height - m - br.y }
        guard dx != 0 || dy != 0 else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            pan.width += dx
            pan.height += dy
        }
    }

    func handleScroll(_ e: NSEvent, at p: CGPoint) {
        if e.modifierFlags.contains(.command) || e.modifierFlags.contains(.control) {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            zoom(to: scale * exp(dy * 0.01), anchor: p)
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 12
            pan.width += e.scrollingDeltaX * k
            pan.height += e.scrollingDeltaY * k
        }
    }

    func handleMagnify(_ m: CGFloat, at p: CGPoint) {
        zoom(to: scale * (1 + m), anchor: p)
    }

    // MARK: Export

    private var baseName: String {
        let t = data.root.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? "思维导图" : t
    }

    func exportPNG() {
        commitEdit()
        let L = LayoutEngine.compute(data.root, style: data.layout)
        let margin: CGFloat = 56
        let b = L.bounds
        let size = CGSize(width: b.width + margin * 2, height: b.height + margin * 2)
        let t = MapTransform(origin: CGPoint(x: -b.minX + margin, y: -b.minY + margin), scale: 1)
        let content = MapCanvas(layout: L, theme: theme, transform: t, model: nil)
            .frame(width: size.width, height: size.height)
            .background(Color.white)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { NSSound.beep(); return }
        save(png, name: baseName + ".png", type: .png)
    }

    func exportXMind() {
        commitEdit()
        do {
            let d = try XMindExporter.export(data)
            save(d, name: baseName + ".xmind",
                 type: UTType(filenameExtension: "xmind") ?? UTType(exportedAs: "net.xmind.workbook", conformingTo: .zip))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func exportMarkdown() {
        commitEdit()
        var out = "# \(data.root.title)\n\n"
        func walk(_ n: MindNode, _ level: Int) {
            for c in n.children {
                out += String(repeating: "  ", count: level) + "- " + c.title + "\n"
                walk(c, level + 1)
            }
        }
        walk(data.root, 0)
        save(Data(out.utf8), name: baseName + ".md", type: UTType(filenameExtension: "md") ?? .plainText)
    }

    func copyOutline() {
        var out = ""
        func walk(_ n: MindNode, _ level: Int) {
            out += String(repeating: "\t", count: level) + n.title + "\n"
            for c in n.children { walk(c, level + 1) }
        }
        walk(data.root, 0)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(out, forType: .string)
    }

    private func save(_ data: Data, name: String, type: UTType) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try data.write(to: url) } catch { NSAlert(error: error).runModal() }
    }
}

struct MapModelKey: FocusedValueKey { typealias Value = MapViewModel }

extension FocusedValues {
    var mapModel: MapViewModel? {
        get { self[MapModelKey.self] }
        set { self[MapModelKey.self] = newValue }
    }
}

struct ToggleAIKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var toggleAI: (() -> Void)? {
        get { self[ToggleAIKey.self] }
        set { self[ToggleAIKey.self] = newValue }
    }
}
