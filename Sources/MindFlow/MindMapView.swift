import SwiftUI

struct MindMapView: View {
    @Binding var document: MindMapDocument
    @State private var model: MapViewModel
    @State private var chat: ChatModel
    @AppStorage("ai.sidebar") private var showAI = true
    @AppStorage("ai.sidebarWidth") private var aiWidth: Double = 360

    init(document: Binding<MindMapDocument>) {
        _document = document
        let m = MapViewModel()
        _model = State(initialValue: m)
        _chat = State(initialValue: ChatModel(map: m))
    }
    @State private var panStart: CGSize?

    var body: some View {
        let theme = Themes.at(document.data.theme)
        let layout = LayoutEngine.compute(document.data.root, style: document.data.layout, override: model.editingOverride)
        let transform = model.transform

        HStack(spacing: 0) {
            mapArea(layout: layout, theme: theme, transform: transform)
            if showAI {
                SidebarDivider(width: $aiWidth)
                AISidebar(chat: chat, isPresented: $showAI)
                    .frame(width: aiWidth)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.28), value: showAI)
        .onAppear {
            model.document = $document
            model.selection = document.data.root.id
        }
        .onChange(of: document.data) { _, d in
            if let s = model.selection, d.root.find(s) == nil { model.selection = d.root.id }
        }
        .focusedSceneValue(\.mapModel, model)
        .focusedSceneValue(\.toggleAI, { showAI.toggle() })
        .toolbar { toolbar }
    }

    private func mapArea(layout: MapLayout, theme: MapTheme, transform: MapTransform) -> some View {
        GeometryReader { geo in
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                DotGrid(origin: transform.origin, scale: transform.scale)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if panStart == nil { panStart = model.pan }
                                model.pan = CGSize(width: panStart!.width + v.translation.width,
                                                   height: panStart!.height + v.translation.height)
                            }
                            .onEnded { _ in panStart = nil }
                    )
                    .onTapGesture(count: 2) { model.select(nil); model.fit() }
                    .simultaneousGesture(TapGesture().onEnded {
                        model.select(nil)
                    })

                MapCanvas(layout: layout, theme: theme, transform: transform, model: model)
            }
            .coordinateSpace(name: "map")
            .background(ScrollCatcher(onScroll: { model.handleScroll($0, at: $1) },
                                      onMagnify: { model.handleMagnify($0, at: $1) },
                                      onKey: { handleKey($0) }))
            .clipped()
            .onAppear { model.viewSize = geo.size }
            .onChange(of: geo.size) { _, s in model.viewSize = s }
        }
    }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        guard model.editingID == nil else { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control])
        guard mods.isEmpty else { return false }
        switch e.keyCode {
        case 48: model.addChild()                 // tab
        case 36, 76: model.addSibling()           // return / enter
        case 49: model.beginEdit()                // space
        case 51, 117: model.deleteSelection()     // delete / fwd delete
        case 126: model.navigate(.up)
        case 125: model.navigate(.down)
        case 123: model.navigate(.left)
        case 124: model.navigate(.right)
        case 53: model.select(nil)                // esc
        default:
            switch e.charactersIgnoringModifiers {
            case "/": model.toggleCollapse()
            case "=", "+": model.zoomIn()
            case "-": model.zoomOut()
            default: return false
            }
        }
        return true
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.addChild() } label: { Label("子主题", systemImage: "arrow.turn.down.right") }
                .help("添加子主题 (Tab)")
            Button { model.addSibling() } label: { Label("同级主题", systemImage: "plus.rectangle.on.rectangle") }
                .help("添加同级主题 (Return)")
            Button { model.deleteSelection() } label: { Label("删除", systemImage: "trash") }
                .help("删除主题 (Delete)")
                .disabled(model.selection == nil || model.selection == document.data.root.id)
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.toggleCollapse() } label: { Label("折叠", systemImage: "rectangle.compress.vertical") }
                .help("折叠 / 展开 (/)")

            Menu {
                Picker("布局", selection: Binding(get: { document.data.layout }, set: { model.setLayout($0) })) {
                    ForEach(LayoutStyle.allCases) { Label($0.name, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label("布局", systemImage: "point.3.connected.trianglepath.dotted") }
            .help("布局")

            Menu {
                Picker("配色", selection: Binding(get: { document.data.theme }, set: { model.setTheme($0) })) {
                    ForEach(Themes.all.indices, id: \.self) { Text(Themes.all[$0].name).tag($0) }
                }
                .pickerStyle(.inline)
            } label: { Label("配色", systemImage: "paintpalette") }
            .help("配色方案")

            Menu {
                Button("放大") { model.zoomIn() }
                Button("缩小") { model.zoomOut() }
                Button("实际大小") { model.actualSize() }
                Divider()
                Button("适应窗口") { model.fit() }
                Button("回到中心") { model.centerRoot() }
            } label: {
                Text("\(Int((model.scale * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .help("缩放")

            Menu {
                Button("导出为图片…") { model.exportPNG() }
                Button("导出为 XMind…") { model.exportXMind() }
                Button("导出为 Markdown…") { model.exportMarkdown() }
                Button("复制为文本大纲") { model.copyOutline() }
            } label: { Label("导出", systemImage: "square.and.arrow.up") }
            .help("导出")
        }

        ToolbarItem(placement: .primaryAction) {
            Button { showAI.toggle() } label: {
                Label("AI 助手", systemImage: showAI ? "sidebar.trailing" : "sparkles")
            }
            .help(showAI ? "隐藏 AI 助手 (⌘J)" : "显示 AI 助手 (⌘J)")
        }
    }
}

private struct SidebarDivider: View {
    @Binding var width: Double
    @State private var start: Double?
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                Color.clear
                    .frame(width: 9)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside && !hovering { NSCursor.resizeLeftRight.push() }
                        if !inside && hovering { NSCursor.pop() }
                        hovering = inside
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { v in
                                if start == nil { start = width }
                                width = min(max(start! - v.translation.width, 300), 600)
                            }
                            .onEnded { _ in start = nil }
                    )
            }
            .zIndex(1)
    }
}
