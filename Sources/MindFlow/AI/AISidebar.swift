import SwiftUI

struct AISidebar: View {
    @Bindable var chat: ChatModel
    @Binding var isPresented: Bool
    @Environment(\.openSettings) private var openSettings
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if chat.messages.isEmpty {
                emptyState
            } else {
                conversation
            }
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: chat.focusInput) { inputFocused = true }
        .onAppear { DispatchQueue.main.async { inputFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 9) {
            AIMark(size: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("AI 助手").font(.system(size: 13, weight: .semibold))
                if let c = chat.store.current {
                    Text(c.model).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            HeaderButton(symbol: "square.and.pencil", help: "新对话") { chat.newSession() }
            Menu {
                if chat.history.isEmpty {
                    Text("暂无历史对话")
                } else {
                    ForEach(chat.history) { s in
                        Button {
                            chat.open(s.id)
                        } label: {
                            Text(s.title) + Text("  ·  " + s.date.formatted(date: .omitted, time: .shortened))
                        }
                    }
                }
            } label: {
                HeaderIcon(symbol: "clock")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("历史对话")
            HeaderButton(symbol: "xmark", help: "关闭 (⌘J)") { isPresented = false }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .frame(height: 50)
    }

    // MARK: Empty state

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 14) {
                Spacer(minLength: 60)
                AIMark(size: 52, glow: true)
                    .padding(.bottom, 4)
                Text("和 AI 一起发散与整理").font(.system(size: 16, weight: .semibold))
                Text(chat.store.providers.isEmpty
                     ? "先添加一个 AI 服务商。可以从本机的 magpie 或 cc-switch 一键导入。"
                     : "助手能看到当前导图的结构。代理模式下，它会直接为你添加、改写和整理主题；问答模式下只回答问题。")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 8)

                if chat.store.providers.isEmpty {
                    Button("添加服务商…") { openSettings() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .padding(.top, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(suggestions, id: \.self) { s in
                            SuggestionRow(text: s) { chat.send(s) }
                        }
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 16)
        }
    }

    private var suggestions: [String] {
        var list = ["围绕中心主题做一次头脑风暴", "帮我精简并重新归类这张导图", "总结这张导图的核心要点"]
        if let t = chat.selectionTitle, chat.map.selection != chat.map.data.root.id {
            list.insert("把「\(t)」拆解成更具体的子主题", at: 0)
        }
        return list
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(chat.messages) { m in
                        MessageView(message: m, chat: chat).id(m.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.text) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { withAnimation { proxy.scrollTo("bottom", anchor: .bottom) } }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = chat.selectionTitle {
                HStack(spacing: 4) {
                    Image(systemName: chat.includeSelection ? "scope" : "circle.slash")
                        .font(.system(size: 10, weight: .semibold))
                    Text(chat.includeSelection ? "选中：\(title)" : "不使用选中主题")
                        .lineLimit(1)
                }
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(chat.includeSelection ? Color.accentColor : .secondary)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill((chat.includeSelection ? Color.accentColor : Color.secondary).opacity(0.12)))
                .onTapGesture { chat.includeSelection.toggle() }
                .help("点击切换是否把选中的主题作为上下文")
            }

            TextField(chat.mode == .agent ? "让 AI 帮你扩展、改写或整理导图…" : "问点什么…",
                      text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .lineLimit(1...8)
                .focused($inputFocused)
                .onSubmit { chat.send() }
                .padding(.vertical, 2)

            HStack(spacing: 6) {
                modeMenu
                ModelMenu(store: chat.store)
                Spacer(minLength: 0)
                sendButton
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.06), radius: 6, y: 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(inputFocused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
        )
        .padding(10)
    }

    private var modeMenu: some View {
        Menu {
            Picker("模式", selection: $chat.mode) {
                ForEach(ChatMode.allCases) { m in
                    Label { Text(m.name) + Text("  " + m.detail).foregroundStyle(.secondary) } icon: { Image(systemName: m.symbol) }
                        .tag(m)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle("代理模式下自动应用修改", isOn: $chat.autoApply)
        } label: {
            Pill(symbol: chat.mode.symbol, text: chat.mode.name, highlighted: chat.mode == .agent)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(chat.mode.detail)
    }

    private var sendButton: some View {
        Button {
            chat.isStreaming ? chat.stop() : chat.send()
        } label: {
            Image(systemName: chat.isStreaming ? "stop.fill" : "arrow.up")
                .font(.system(size: chat.isStreaming ? 10 : 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(canSend || chat.isStreaming ? Color.accentColor : Color.secondary.opacity(0.35)))
        }
        .buttonStyle(.plain)
        .disabled(!canSend && !chat.isStreaming)
        .help(chat.isStreaming ? "停止" : "发送 (Return)")
    }

    private var canSend: Bool { !chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Pieces

private struct HeaderButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { HeaderIcon(symbol: symbol) }
            .buttonStyle(.plain)
            .help(help)
    }
}

private struct HeaderIcon: View {
    let symbol: String
    @State private var hover = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(hover ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(hover ? 0.07 : 0)))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
    }
}

/// The app's AI brand mark: a soft gradient squircle with a white four-point star.
struct AIMark: View {
    var size: CGFloat = 22
    var glow = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Color(hex: 0x6E8BFF), Color(hex: 0x7B5CF0), Color(hex: 0x9A5CF0)],
                                      startPoint: .topLeading, endPoint: .bottomTrailing))
            shape.fill(LinearGradient(colors: [.white.opacity(0.28), .clear], startPoint: .top, endPoint: .center))
            StarShape()
                .fill(.white)
                .frame(width: size * 0.5, height: size * 0.5)
                .shadow(color: Color(hex: 0x3B2A9A).opacity(0.35), radius: size * 0.04, y: size * 0.02)
            StarShape()
                .fill(.white.opacity(0.9))
                .frame(width: size * 0.17, height: size * 0.17)
                .offset(x: size * 0.22, y: -size * 0.22)
        }
        .frame(width: size, height: size)
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .shadow(color: Color(hex: 0x6E5CF0).opacity(glow ? 0.35 : 0.18), radius: glow ? size * 0.3 : 2, y: glow ? size * 0.1 : 1)
    }
}

/// Four-point star with concave sides.
struct StarShape: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY)
        let k: CGFloat = 0.16
        var p = Path()
        p.move(to: CGPoint(x: c.x, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: c.y), control: CGPoint(x: c.x + r.width * k, y: c.y - r.height * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.maxY), control: CGPoint(x: c.x + r.width * k, y: c.y + r.height * k))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: c.y), control: CGPoint(x: c.x - r.width * k, y: c.y + r.height * k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: r.minY), control: CGPoint(x: c.x - r.width * k, y: c.y - r.height * k))
        p.closeSubpath()
        return p
    }
}

private struct SuggestionRow: View {
    let text: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(text).font(.system(size: 13, weight: .medium)).multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(hover ? 1 : 0.7)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(hover ? 0.12 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct Pill: View {
    var symbol: String?
    let text: String
    var highlighted = false

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10.5, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(highlighted ? Color.accentColor : .secondary)
        .padding(.horizontal, 9).padding(.vertical, 5)
        .background(Capsule().fill((highlighted ? Color.accentColor : Color.primary).opacity(highlighted ? 0.12 : 0.06)))
        .contentShape(Capsule())
    }
}

struct ModelMenu: View {
    let store: ProviderStore
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            ForEach(store.providers) { p in
                Section(p.name) {
                    ForEach(p.models, id: \.self) { m in
                        Button {
                            store.select(p, model: m)
                        } label: {
                            if store.current?.provider.id == p.id && store.current?.model == m {
                                Label(m, systemImage: "checkmark")
                            } else {
                                Text(m)
                            }
                        }
                    }
                }
            }
            Divider()
            Button("管理服务商…") { openSettings() }
        } label: {
            Pill(symbol: "cpu", text: store.current?.model ?? "选择模型")
                .frame(maxWidth: 170, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: false, vertical: true)
        .help(store.current.map { "\($0.provider.name) · \($0.model)" } ?? "选择模型")
    }
}

// MARK: - Message

struct MessageView: View {
    let message: ChatMessage
    let chat: ChatModel

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.14)))
            }
        case .assistant:
            assistant
        }
    }

    private var assistant: some View {
        let parts = MapAgent.split(message.text)
        return VStack(alignment: .leading, spacing: 10) {
            if !parts.display.isEmpty {
                MarkdownView(text: parts.display)
            }
            if message.streaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(parts.pending ? "正在生成导图修改…" : (message.text.isEmpty ? "思考中…" : ""))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            if message.opsState != nil { opsCard }
            if let err = message.error {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(err).font(.system(size: 12)).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.1)))
                Button("重试") { chat.retry(message.id) }.controlSize(.small)
            }
            if !message.streaming && message.error == nil && !parts.display.isEmpty {
                actions(parts.display)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var opsCard: some View {
        let state = message.opsState!
        let icon: String, tint: Color, title: String
        switch state {
        case .applied: (icon, tint, title) = ("checkmark.circle.fill", .green, "已修改导图")
        case .pending: (icon, tint, title) = ("wand.and.stars", .accentColor, "建议的修改")
        case .reverted: (icon, tint, title) = ("arrow.uturn.backward.circle.fill", .secondary, "已撤销")
        case .failed: (icon, tint, title) = ("exclamationmark.circle.fill", .orange, "修改未能应用")
        }
        return HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                if let s = message.opsSummary, state != .pending {
                    Text(s).font(.system(size: 11.5)).foregroundStyle(.secondary)
                } else if state == .pending {
                    Text("点击应用到导图").font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            switch state {
            case .applied:
                Button("撤销") { chat.revert(message.id) }
                    .controlSize(.small)
                    .disabled(!chat.canRevert(message))
                    .help(chat.canRevert(message) ? "恢复到修改前" : "导图之后又有改动，请用 ⌘Z 撤销")
            case .pending, .reverted:
                Button("应用") { chat.apply(message.id) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            case .failed:
                EmptyView()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }

    private func actions(_ text: String) -> some View {
        HStack(spacing: 2) {
            SmallAction(symbol: "doc.on.doc", help: "复制") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            SmallAction(symbol: "rectangle.badge.plus", help: "插入到选中主题下") { chat.insertIntoMap(message.id) }
            SmallAction(symbol: "arrow.clockwise", help: "重新生成") { chat.retry(message.id) }
            if let m = message.model {
                Text(m).font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.leading, 4).lineLimit(1)
            }
        }
    }
}

private struct SmallAction: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hover ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - Lightweight Markdown

struct MarkdownView: View {
    let text: String

    private enum Block: Hashable {
        case heading(String, Int), bullet(String, Int, String), paragraph(String), code(String), rule
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                switch b {
                case .heading(let s, let level):
                    inline(s).font(.system(size: level <= 1 ? 16 : level == 2 ? 14.5 : 13.5, weight: .semibold))
                        .padding(.top, 4)
                case .bullet(let s, let indent, let marker):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        inline(s)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .paragraph(let s):
                    inline(s)
                case .code(let s):
                    Text(s)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
                case .rule:
                    Divider()
                }
            }
        }
        .font(.system(size: 13.5))
        .lineSpacing(2.5)
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    private var blocks: [Block] {
        var out: [Block] = []
        var para: [String] = []
        var code: [String]? = nil
        func flush() {
            if !para.isEmpty { out.append(.paragraph(para.joined(separator: "\n"))); para = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil }
                else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if t.isEmpty { flush(); continue }
            if t == "---" || t == "***" { flush(); out.append(.rule); continue }
            if t.hasPrefix("#") {
                flush()
                let n = t.prefix { $0 == "#" }.count
                out.append(.heading(t.dropFirst(n).trimmingCharacters(in: .whitespaces), n))
                continue
            }
            let indent = raw.replacingOccurrences(of: "\t", with: "    ").prefix { $0 == " " }.count / 2
            if let r = t.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flush(); out.append(.bullet(String(t[r.upperBound...]), indent, "•")); continue
            }
            if let r = t.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) {
                flush()
                let marker = String(t[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
                out.append(.bullet(String(t[r.upperBound...]), indent, marker)); continue
            }
            para.append(t)
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }
}
