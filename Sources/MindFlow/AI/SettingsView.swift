import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("通用", systemImage: "gearshape") }
            ProvidersSettings()
                .tabItem { Label("AI 服务商", systemImage: "server.rack") }
        }
        .frame(width: 760, height: 520)
    }
}

struct GeneralSettings: View {
    @Bindable private var updater = Updater.shared
    @Environment(\.openWindow) private var openWindow
    @State private var auto = Updater.shared.autoCheck

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MindFlow").font(.system(size: 15, weight: .semibold))
                        Text("版本 \(Updater.currentVersion)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Link("GitHub", destination: URL(string: "https://github.com/\(Updater.repo)")!)
                        .font(.system(size: 12))
                }
                .padding(.vertical, 4)
            }
            Section("软件更新") {
                Toggle("自动检查更新", isOn: $auto)
                    .onChange(of: auto) { _, v in updater.autoCheck = v }
                HStack {
                    Text(updater.lastCheck.map { "上次检查：" + $0.formatted(date: .abbreviated, time: .shortened) } ?? "尚未检查")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button("立即检查") {
                        openWindow(id: "updater")
                        Task { await updater.check(userInitiated: true) }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct ProvidersSettings: View {
    @Bindable private var store = ProviderStore.shared
    @State private var selection: UUID?
    @State private var showImport = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(store.providers) { p in
                        HStack(spacing: 10) {
                            ProviderIcon(kind: p.kind)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                Text("\(p.kind.short) · \(p.host)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 3)
                        .tag(p.id)
                    }
                    .onMove { store.providers.move(fromOffsets: $0, toOffset: $1) }
                }
                .listStyle(.sidebar)
                .overlay {
                    if store.providers.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "tray").font(.system(size: 26)).foregroundStyle(.tertiary)
                            Text("还没有服务商").foregroundStyle(.secondary)
                            Button("导入…") { showImport = true }
                        }
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { addProvider() } label: { Image(systemName: "plus").frame(width: 26, height: 22) }
                        .help("手动添加")
                    Button { removeSelected() } label: { Image(systemName: "minus").frame(width: 26, height: 22) }
                        .disabled(selection == nil)
                        .help("删除")
                    Spacer()
                    Button("导入…") { showImport = true }
                        .controlSize(.small)
                        .padding(.trailing, 8)
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 250)

            Divider()

            Group {
                if let id = selection, let i = store.providers.firstIndex(where: { $0.id == id }) {
                    ProviderEditor(provider: $store.providers[i])
                        .id(id)
                } else {
                    VStack(spacing: 6) {
                        Text("选择或添加一个服务商").foregroundStyle(.secondary)
                        Text("支持 Anthropic、OpenAI 及其兼容接口（如各类中转、DeepSeek、Kimi、通义、OpenRouter 等）")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .sheet(isPresented: $showImport) { ImportSheet(isPresented: $showImport) }
        .onAppear { if selection == nil { selection = store.providers.first?.id } }
    }

    private func addProvider() {
        let p = AIProvider(name: "新服务商", kind: .openaiChat, baseURL: "https://api.openai.com/v1", apiKey: "", models: [])
        store.providers.append(p)
        selection = p.id
    }

    private func removeSelected() {
        guard let id = selection, let i = store.providers.firstIndex(where: { $0.id == id }) else { return }
        store.providers.remove(at: i)
        selection = store.providers.indices.contains(i) ? store.providers[i].id : store.providers.last?.id
        store.normalizeSelection()
    }
}

struct ProviderIcon: View {
    let kind: APIKind
    var body: some View {
        let (sym, color): (String, Color) = switch kind {
        case .anthropic: ("asterisk", Color(hex: 0xD97757))
        case .openaiChat: ("circle.hexagongrid", Color(hex: 0x10A37F))
        case .openaiResponses: ("circle.hexagonpath", Color(hex: 0x3B82F6))
        }
        Image(systemName: sym)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
    }
}

struct ProviderEditor: View {
    @Binding var provider: AIProvider
    @State private var modelsText = ""
    @State private var showKey = false
    @State private var testState: TestState = .idle
    @State private var testModel = ""

    enum TestState: Equatable { case idle, running, ok(String), failed(String) }

    var body: some View {
        Form {
            Section {
                TextField("名称", text: $provider.name)
                Picker("接口类型", selection: $provider.kind) {
                    ForEach(APIKind.allCases) { Text($0.name).tag($0) }
                }
                TextField("接口地址", text: $provider.baseURL, prompt: Text(placeholderURL))
                HStack {
                    Group {
                        if showKey { TextField("API Key", text: $provider.apiKey) }
                        else { SecureField("API Key", text: $provider.apiKey) }
                    }
                    Button { showKey.toggle() } label: { Image(systemName: showKey ? "eye.slash" : "eye") }
                        .buttonStyle(.borderless)
                }
            } footer: {
                Text("实际请求：\((try? LLMClient.endpoint(for: provider).absoluteString) ?? "—")")
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
            }

            Section {
                TextField("模型", text: $modelsText, prompt: Text("每行一个，或用逗号分隔"), axis: .vertical)
                    .lineLimit(2...6)
                    .onChange(of: modelsText) { _, v in
                        provider.models = v.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == "，" })
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
                if provider.kind == .anthropic {
                    Button("填入 Claude 默认模型") {
                        modelsText = ProviderImporter.defaultAnthropicModels.joined(separator: "\n")
                    }
                    .buttonStyle(.link)
                }
            } header: { Text("模型") }

            Section {
                HStack {
                    Picker("测试模型", selection: $testModel) {
                        ForEach(provider.models, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220)
                    Button(testState == .running ? "测试中…" : "测试连接") { runTest() }
                        .disabled(testState == .running || provider.models.isEmpty || provider.apiKey.isEmpty)
                    Spacer()
                }
                switch testState {
                case .ok(let s):
                    Label("连接成功：\(s)", systemImage: "checkmark.circle.fill").foregroundStyle(.green).font(.system(size: 12))
                case .failed(let s):
                    Label(s, systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.system(size: 12)).textSelection(.enabled)
                default: EmptyView()
                }
            }

            if let src = provider.source {
                Text("来源：\(src)").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            modelsText = provider.models.joined(separator: "\n")
            testModel = provider.models.first ?? ""
        }
        .onChange(of: provider.models) { _, m in if !m.contains(testModel) { testModel = m.first ?? "" } }
    }

    private var placeholderURL: String {
        provider.kind == .anthropic ? "https://api.anthropic.com" : "https://api.openai.com/v1"
    }

    private func runTest() {
        testState = .running
        let p = provider, m = testModel.isEmpty ? (provider.models.first ?? "") : testModel
        Task {
            do {
                let r = try await LLMClient.test(provider: p, model: m)
                testState = .ok(String(r.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)))
            } catch {
                testState = .failed(error.localizedDescription)
            }
        }
    }
}

// MARK: - Import sheet

struct ImportSheet: View {
    @Binding var isPresented: Bool
    private let store = ProviderStore.shared
    @State private var sources: [ImportSource] = []
    @State private var preview: ImportSource?
    @State private var imported: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let src = preview {
                PreviewList(source: src, onBack: { preview = nil }, onImport: { list in
                    store.add(list)
                    imported = list.count
                    reload()
                    preview = nil
                })
            } else {
                main
            }
        }
        .frame(width: 560)
        .onAppear(perform: reload)
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("导入服务商").font(.system(size: 17, weight: .semibold))
                    Text("从本机的 magpie 或 cc-switch 读取服务商配置，不会发送到网络。")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { isPresented = false } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 18)

            VStack(spacing: 0) {
                ForEach(sources) { src in
                    HStack(spacing: 14) {
                        Image(systemName: src.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                            .frame(width: 40, height: 40)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.06)))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(src.name).font(.system(size: 14, weight: .semibold))
                            Text(src.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("预览") { preview = src }.disabled(!src.found || src.candidates.isEmpty)
                    }
                    .padding(.vertical, 10)
                }
                Divider().padding(.vertical, 8)
                HStack(spacing: 14) {
                    Image(systemName: "doc").font(.system(size: 18)).foregroundStyle(.secondary).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("从文件导入").font(.system(size: 14, weight: .semibold))
                        Text("支持 magpie JSON、cc-switch 数据库或 config.json").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择文件…") { pickFile() }
                }
                .padding(.vertical, 6)
            }

            HStack {
                if let n = imported {
                    Label("已导入 \(n) 个服务商", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12)).foregroundStyle(.green)
                }
                Spacer()
                Button(imported == nil ? "取消" : "完成") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                    .controlSize(.large)
            }
            .padding(.top, 18)
        }
        .padding(24)
    }

    private func reload() {
        sources = [ProviderImporter.magpie(store: store), ProviderImporter.ccSwitch(store: store)]
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let src = ProviderImporter.fromFile(url, store: store)
        if src.candidates.isEmpty {
            let a = NSAlert()
            a.messageText = "没有在文件中找到服务商配置"
            a.informativeText = url.lastPathComponent
            a.runModal()
        } else {
            preview = src
        }
    }
}

private struct PreviewList: View {
    @State var source: ImportSource
    let onBack: () -> Void
    let onImport: ([AIProvider]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Button { onBack() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless)
                Text(source.name).font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(source.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 12)

            List {
                ForEach($source.candidates) { $c in
                    HStack(spacing: 10) {
                        Toggle("", isOn: $c.selected).labelsHidden().disabled(!c.importable)
                        ProviderIcon(kind: c.provider.kind).opacity(c.importable ? 1 : 0.4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.provider.name).font(.system(size: 13, weight: .medium))
                            Text(line(c)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        statusBadge(c)
                    }
                    .padding(.vertical, 2)
                    .opacity(c.importable ? 1 : 0.65)
                }
            }
            .frame(height: 320)

            HStack {
                Button("全选") { setAll(true) }.controlSize(.small)
                Button("全不选") { setAll(false) }.controlSize(.small)
                Spacer()
                let n = source.candidates.filter { $0.selected && $0.importable }.count
                Button("导入 \(n) 个") {
                    onImport(source.candidates.filter { $0.selected && $0.importable }.map(\.provider))
                }
                .buttonStyle(.borderedProminent)
                .disabled(n == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
    }

    private func line(_ c: ImportCandidate) -> String {
        var parts: [String] = []
        if let d = c.detail { parts.append(d) }
        if !c.provider.baseURL.isEmpty { parts.append(c.provider.host) }
        if !c.provider.models.isEmpty { parts.append(c.provider.models.prefix(2).joined(separator: ", ") + (c.provider.models.count > 2 ? "…" : "")) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func statusBadge(_ c: ImportCandidate) -> some View {
        switch c.status {
        case .ok: EmptyView()
        case .duplicate: Text("已存在").font(.system(size: 11)).foregroundStyle(.secondary)
        case .invalid(let why): Text(why).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(1)
        }
    }

    private func setAll(_ v: Bool) {
        for i in source.candidates.indices where source.candidates[i].importable { source.candidates[i].selected = v }
    }
}
