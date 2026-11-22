import AppKit
import SwiftUI

/// Draws connectors + nodes. Used both for the live editor (model != nil) and static export (model == nil).
struct MapCanvas: View {
    let layout: MapLayout
    let theme: MapTheme
    let transform: MapTransform
    var model: MapViewModel?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in drawEdges(ctx) }
                .allowsHitTesting(false)

            ForEach(layout.nodes) { n in
                let dragging = model?.dragID == n.id
                let c = transform.apply(CGPoint(x: n.frame.midX, y: n.frame.midY))
                NodeView(node: n, theme: theme, model: model)
                    .scaleEffect(transform.scale)
                    .opacity(dragging ? 0.75 : 1)
                    .position(x: c.x + (dragging ? model!.dragOffset.width : 0),
                              y: c.y + (dragging ? model!.dragOffset.height : 0))
                    .zIndex(dragging ? 10 : (n.depth == 0 ? 1 : 0))
            }
        }
    }

    private func drawEdges(_ ctx: GraphicsContext) {
        let s = transform.scale
        for n in layout.nodes {
            guard let pid = n.parentID, let p = layout[pid] else { continue }
            let color = theme.color(n.branch)
            let left = n.side == .left
            let start: CGPoint = p.depth == 0
                ? CGPoint(x: p.frame.midX, y: p.frame.midY)
                : CGPoint(x: left ? p.frame.minX : p.frame.maxX, y: p.frame.midY)
            let end = CGPoint(x: left ? n.frame.maxX : n.frame.minX, y: n.frame.midY)
            let a = transform.apply(start), b = transform.apply(end)

            if n.depth == 1 {
                ctx.fill(Self.tapered(from: a, to: b, w0: 9 * s, w1: 2.6 * s), with: .color(color.opacity(0.9)))
            } else {
                let w: CGFloat = n.depth == 2 ? 2 : 1.5
                ctx.stroke(Self.curve(from: a, to: b), with: .color(color.opacity(0.8)),
                           style: StrokeStyle(lineWidth: w * s, lineCap: .round))
            }
        }
    }

    static func curve(from s: CGPoint, to e: CGPoint) -> Path {
        let mx = (e.x - s.x) * 0.5
        var p = Path()
        p.move(to: s)
        p.addCurve(to: e, control1: CGPoint(x: s.x + mx, y: s.y), control2: CGPoint(x: e.x - mx, y: e.y))
        return p
    }

    static func tapered(from s: CGPoint, to e: CGPoint, w0: CGFloat, w1: CGFloat) -> Path {
        let mx = (e.x - s.x) * 0.55
        var p = Path()
        p.move(to: CGPoint(x: s.x, y: s.y - w0 / 2))
        p.addCurve(to: CGPoint(x: e.x, y: e.y - w1 / 2),
                   control1: CGPoint(x: s.x + mx, y: s.y - w0 / 2),
                   control2: CGPoint(x: e.x - mx, y: e.y - w1 / 2))
        p.addLine(to: CGPoint(x: e.x, y: e.y + w1 / 2))
        p.addCurve(to: CGPoint(x: s.x, y: s.y + w0 / 2),
                   control1: CGPoint(x: e.x - mx, y: e.y + w1 / 2),
                   control2: CGPoint(x: s.x + mx, y: s.y + w0 / 2))
        p.closeSubpath()
        return p
    }
}

// MARK: - Node

struct NodeView: View {
    let node: NodeLayout
    let theme: MapTheme
    var model: MapViewModel?

    private var d: Int { min(node.depth, 2) }
    private var color: Color { theme.color(node.branch) }
    private var selected: Bool { model?.selection == node.id }
    private var editing: Bool { model?.editingID == node.id }
    private var isDrop: Bool { model?.dropTargetID == node.id }
    private var corner: CGFloat { NodeStyle.corner(d) }
    private var textColor: Color { d == 0 ? .white : .primary }
    private var textWidth: CGFloat { node.frame.width - NodeStyle.padding(d).width * 2 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        label
            .frame(width: node.frame.width, height: node.frame.height)
            .background { background(shape) }
            .contentShape(shape)
            .overlay {
                if selected || isDrop {
                    RoundedRectangle(cornerRadius: corner + 4, style: .continuous)
                        .stroke(isDrop ? color : Color.accentColor,
                                style: StrokeStyle(lineWidth: 2.5, dash: isDrop ? [5, 4] : []))
                        .padding(-4)
                }
            }
            .overlay(alignment: node.side == .left ? .leading : .trailing) { badge }
            .modifier(NodeInteractions(node: node, model: model))
    }

    @ViewBuilder private var label: some View {
        if editing, let model {
            EditField(model: model, nodeID: node.id, depth: d, width: textWidth, color: textColor)
        } else {
            Text(node.title.isEmpty ? NodeStyle.placeholder : node.title)
                .font(NodeStyle.font(d))
                .foregroundStyle(textColor.opacity(node.title.isEmpty ? 0.45 : 1))
                .multilineTextAlignment(.center)
                .frame(width: textWidth)
        }
    }

    @ViewBuilder private func background(_ shape: RoundedRectangle) -> some View {
        switch d {
        case 0:
            shape.fill(LinearGradient(colors: theme.root, startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: theme.root[0].opacity(0.35), radius: 12, y: 5)
        case 1:
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.fill(color.opacity(0.13)))
                .overlay(shape.strokeBorder(color, lineWidth: 1.6))
                .shadow(color: .black.opacity(0.07), radius: 3, y: 1)
        default:
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay(shape.strokeBorder(color.opacity(0.5), lineWidth: 1))
        }
    }

    @ViewBuilder private var badge: some View {
        if node.collapsed && node.childCount > 0 {
            Text("\(node.childCount)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 18, minHeight: 18)
                .background(Capsule().fill(d == 0 ? theme.root[0] : color))
                .overlay(Capsule().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                .offset(x: node.side == .left ? -24 : 24)
                .onTapGesture { model?.toggleCollapse(node.id) }
                .help("展开 \(node.childCount) 个子主题")
        } else if selected && !editing && model?.dragID == nil, let model {
            AddChildButton(color: d == 0 ? theme.root[0] : color) {
                model.select(node.id)
                model.addChild()
            }
            .offset(x: node.side == .left ? -32 : 32)
        }
    }
}

/// The little "+" that appears beside the selected topic.
private struct AddChildButton: View {
    let color: Color
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(hover ? .white : color)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hover ? color : Color(nsColor: .controlBackgroundColor)))
                .overlay(Circle().strokeBorder(color.opacity(hover ? 0 : 0.55), lineWidth: 1.2))
                .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                .scaleEffect(hover ? 1.12 : 1)
                .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
        .help("添加子主题 (Tab)")
    }
}

struct NodeInteractions: ViewModifier {
    let node: NodeLayout
    let model: MapViewModel?

    func body(content: Content) -> some View {
        if let model, model.editingID != node.id {
            content
                .onTapGesture(count: 2) { model.beginEdit(node.id) }
                .simultaneousGesture(TapGesture().onEnded {
                    model.select(node.id)
                    model.requestFocus()
                })
                .gesture(
                    DragGesture(minimumDistance: 4, coordinateSpace: .named("map"))
                        .onChanged { v in model.dragChanged(node.id, translation: v.translation, location: v.location) }
                        .onEnded { _ in model.dragEnded() },
                    including: node.depth > 0 ? .all : .subviews)
                .contextMenu { NodeMenu(model: model, id: node.id) }
        } else {
            content
        }
    }
}

struct EditField: View {
    @Bindable var model: MapViewModel
    let nodeID: UUID
    let depth: Int
    let width: CGFloat
    let color: Color
    @FocusState private var focused: Bool

    var body: some View {
        TextField(NodeStyle.placeholder, text: $model.draft, axis: .vertical)
            .textFieldStyle(.plain)
            .font(NodeStyle.font(depth))
            .foregroundStyle(color)
            .multilineTextAlignment(.center)
            .frame(width: width)
            .focused($focused)
            .onSubmit { model.commitEdit() }
            .onExitCommand { model.cancelEdit() }
            .onAppear { DispatchQueue.main.async { focused = true } }
            .onChange(of: focused) { _, f in
                if !f && model.editingID == nodeID { model.commitEdit() }
            }
    }
}

struct NodeMenu: View {
    let model: MapViewModel
    let id: UUID

    var body: some View {
        let node = model.data.root.find(id)
        let isRoot = id == model.data.root.id
        Button("添加子主题") { model.select(id); model.addChild() }
        Button("添加同级主题") { model.select(id); model.addSibling() }.disabled(isRoot)
        Button("编辑文字") { model.beginEdit(id) }
        if let node, !node.children.isEmpty {
            Button(node.collapsed ? "展开" : "折叠") { model.toggleCollapse(id) }
        }
        Menu("分支颜色") {
            Button("自动") { model.setColor(nil, for: id) }
            Divider()
            ForEach(model.theme.colorNames.indices, id: \.self) { i in
                Button(model.theme.colorNames[i]) { model.setColor(i, for: id) }
            }
        }
        .disabled(isRoot)
        Divider()
        Button("删除", role: .destructive) { model.select(id); model.deleteSelection() }.disabled(isRoot)
    }
}

// MARK: - Background

struct DotGrid: View {
    let origin: CGPoint
    let scale: CGFloat

    var body: some View {
        Canvas { ctx, size in
            let step = 26 * scale
            guard step >= 9 else { return }
            let r = max(0.8, min(1.3, scale))
            let ox = origin.x.truncatingRemainder(dividingBy: step) - step
            let oy = origin.y.truncatingRemainder(dividingBy: step) - step
            var path = Path()
            var x = ox
            while x < size.width + step {
                var y = oy
                while y < size.height + step {
                    path.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    y += step
                }
                x += step
            }
            ctx.fill(path, with: .color(Color.primary.opacity(0.09)))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Trackpad / wheel events

struct ScrollCatcher: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onKey: (NSEvent) -> Bool = { _ in false }

    func makeNSView(context: Context) -> CatcherView { CatcherView() }

    func updateNSView(_ v: CatcherView, context: Context) {
        v.onScroll = onScroll
        v.onMagnify = onMagnify
        v.onKey = onKey
    }

    final class CatcherView: NSView {
        var onScroll: ((NSEvent, CGPoint) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onKey: ((NSEvent) -> Bool)?
        private var monitor: Any?
        private var keyMonitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            guard window != nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                let consumed: Bool = MainActor.assumeIsolated {
                    guard let self, let w = self.window, e.window === w, w.isKeyWindow, w.attachedSheet == nil,
                          !(w.firstResponder is NSText) else { return false }
                    return self.onKey?(e) ?? false
                }
                return consumed ? nil : e
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] e in
                let consumed: Bool = MainActor.assumeIsolated {
                    guard let self, let w = self.window, e.window === w, w.attachedSheet == nil else { return false }
                    let p = self.convert(e.locationInWindow, from: nil)
                    guard self.bounds.contains(p) else { return false }
                    if e.type == .magnify { self.onMagnify?(e.magnification, p) } else { self.onScroll?(e, p) }
                    return true
                }
                return consumed ? nil : e
            }
        }
    }
}
