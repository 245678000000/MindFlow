import SwiftUI

@main
struct MindFlowApp: App {
    init() {
        // Launch straight into a new map instead of showing the Open panel.
        UserDefaults.standard.register(defaults: ["NSShowAppCentricOpenPanelInsteadOfUntitledFile": false])
    }

    var body: some Scene {
        DocumentGroup(newDocument: MindMapDocument()) { file in
            MindMapView(document: file.$document)
                .frame(minWidth: 640, minHeight: 420)
        }
        .defaultSize(width: 1200, height: 780)
        .windowToolbarStyle(.unified)
        .commands { MapCommands() }

        Settings { SettingsView() }
    }
}

struct MapCommands: Commands {
    @FocusedValue(\.mapModel) private var model
    @FocusedValue(\.toggleAI) private var toggleAI

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            Button("导出为图片…") { model?.exportPNG() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model == nil)
            Button("导出为 XMind…") { model?.exportXMind() }
                .disabled(model == nil)
            Button("导出为 Markdown…") { model?.exportMarkdown() }
                .disabled(model == nil)
        }

        CommandMenu("节点") {
            Button("添加子主题") { model?.addChild() }
                .keyboardShortcut(.return, modifiers: [.command])
            Button("添加同级主题") { model?.addSibling() }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("编辑文字") { model?.beginEdit() }
            Button("折叠 / 展开") { model?.toggleCollapse() }
                .keyboardShortcut("/", modifiers: [.command])
            Divider()
            Button("删除主题") { model?.deleteSelection() }
        }

        CommandGroup(after: .toolbar) {
            Button("放大") { model?.zoomIn() }.keyboardShortcut("=", modifiers: [.command])
            Button("缩小") { model?.zoomOut() }.keyboardShortcut("-", modifiers: [.command])
            Button("实际大小") { model?.actualSize() }.keyboardShortcut("0", modifiers: [.command])
            Button("适应窗口") { model?.fit() }.keyboardShortcut("9", modifiers: [.command])
            Divider()
            Button("AI 助手") { toggleAI?() }.keyboardShortcut("j", modifiers: [.command])
                .disabled(toggleAI == nil)
            Divider()
        }
    }
}
