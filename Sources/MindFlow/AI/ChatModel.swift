import Foundation
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    enum OpsState { case applied, reverted, pending, failed }

    let id = UUID()
    var role: Role
    var text: String
    var streaming = false
    var error: String?
    var context: MapContext?
    var opsJSON: String?
    var opsState: OpsState?
    var opsSummary: String?
    var before: MapData?
    var after: MapData?
    var revision: Int?
    var model: String?
}

struct ChatSession: Identifiable {
    let id = UUID()
    var title = "新对话"
    var messages: [ChatMessage] = []
    var date = Date()
}

@MainActor
@Observable
final class ChatModel {
    let map: MapViewModel
    let store = ProviderStore.shared

    var sessions: [ChatSession]
    var currentID: UUID
    var input = ""
    var mode: ChatMode = .agent {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "ai.mode") }
    }
    var autoApply = true {
        didSet { UserDefaults.standard.set(autoApply, forKey: "ai.autoApply") }
    }
    var includeSelection = true
    var focusInput = 0
    private var task: Task<Void, Never>?

    init(map: MapViewModel) {
        self.map = map
        let first = ChatSession()
        sessions = [first]
        currentID = first.id
        if let m = UserDefaults.standard.string(forKey: "ai.mode"), let mode = ChatMode(rawValue: m) { self.mode = mode }
        if UserDefaults.standard.object(forKey: "ai.autoApply") != nil {
            autoApply = UserDefaults.standard.bool(forKey: "ai.autoApply")
        }
    }

    var isStreaming: Bool { task != nil }

    private var index: Int { sessions.firstIndex { $0.id == currentID } ?? 0 }
    var messages: [ChatMessage] { sessions[index].messages }

    var selectionTitle: String? {
        guard let s = map.selection, let n = map.data.root.find(s) else { return nil }
        return n.title.isEmpty ? NodeStyle.placeholder : n.title
    }

    // MARK: Sessions

    func newSession() {
        stop()
        if sessions[index].messages.isEmpty { input = ""; focusInput += 1; return }
        let s = ChatSession()
        sessions.insert(s, at: 0)
        currentID = s.id
        input = ""
        focusInput += 1
    }

    func open(_ id: UUID) {
        stop()
        currentID = id
    }

    var history: [ChatSession] { sessions.filter { !$0.messages.isEmpty } }

    // MARK: Sending

    func send(_ override: String? = nil) {
        let text = (override ?? input).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming else { return }
        map.commitEdit()
        input = ""

        let i = index
        if sessions[i].messages.isEmpty { sessions[i].title = String(text.prefix(24)) }
        sessions[i].messages.append(ChatMessage(role: .user, text: text))

        guard let (provider, model) = store.current else {
            sessions[i].messages.append(ChatMessage(role: .assistant, text: "",
                error: "还没有可用的模型。请在「设置 › AI 服务商」中添加或导入一个服务商。"))
            return
        }

        let ctx = MapAgent.context(for: map.data, selection: map.selection)
        let system = MapAgent.systemPrompt(mode: mode, context: ctx, includeSelection: includeSelection)
        let history = sessions[i].messages.compactMap { m -> LLMMessage? in
            if m.error != nil && m.text.isEmpty { return nil }
            return LLMMessage(role: m.role == .user ? "user" : "assistant", content: m.text)
        }

        var reply = ChatMessage(role: .assistant, text: "", streaming: true)
        reply.context = ctx
        reply.model = model
        let replyID = reply.id
        let sessionID = sessions[i].id
        let mode = self.mode
        sessions[i].messages.append(reply)

        task = Task { [weak self] in
            do {
                for try await chunk in LLMClient.stream(provider: provider, model: model, system: system, messages: history) {
                    self?.update(sessionID, replyID) { $0.text += chunk }
                }
                self?.finish(sessionID, replyID, mode: mode)
            } catch is CancellationError {
                self?.update(sessionID, replyID) { $0.streaming = false }
            } catch {
                let msg = (error as? URLError)?.code == .cancelled ? nil : error.localizedDescription
                self?.update(sessionID, replyID) { $0.streaming = false; $0.error = msg }
            }
            self?.task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        for s in sessions.indices {
            for m in sessions[s].messages.indices where sessions[s].messages[m].streaming {
                sessions[s].messages[m].streaming = false
            }
        }
    }

    func retry(_ id: UUID) {
        let i = index
        guard let mi = sessions[i].messages.firstIndex(where: { $0.id == id }),
              let lastUser = sessions[i].messages[..<mi].last(where: { $0.role == .user }) else { return }
        sessions[i].messages.removeSubrange(sessions[i].messages.firstIndex { $0.id == lastUser.id }!...)
        send(lastUser.text)
    }

    private func update(_ session: UUID, _ id: UUID, _ body: (inout ChatMessage) -> Void) {
        guard let s = sessions.firstIndex(where: { $0.id == session }),
              let m = sessions[s].messages.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[s].messages[m])
    }

    private func finish(_ session: UUID, _ id: UUID, mode: ChatMode) {
        update(session, id) { m in
            m.streaming = false
            let parts = MapAgent.split(m.text)
            if let json = parts.opsJSON {
                m.opsJSON = json
                m.opsState = .pending
            }
        }
        if mode == .agent && autoApply { apply(id, in: session) }
    }

    // MARK: Map edits

    func apply(_ id: UUID, in session: UUID? = nil) {
        let sid = session ?? currentID
        guard let s = sessions.firstIndex(where: { $0.id == sid }),
              let mi = sessions[s].messages.firstIndex(where: { $0.id == id }) else { return }
        let msg = sessions[s].messages[mi]
        guard let json = msg.opsJSON, let ctx = msg.context else { return }
        guard let ops = MapAgent.parseOps(json) else {
            update(sid, id) { $0.opsState = .failed; $0.opsSummary = "无法解析模型返回的修改" }
            return
        }
        map.commitEdit()
        let before = map.data
        var after = before
        let result = MapAgent.apply(ops, context: ctx, selection: map.selection, to: &after)
        let snapshot = after
        map.mutate { $0 = snapshot }
        update(sid, id) { m in
            m.before = before
            m.after = after
            m.revision = map.revision
            m.opsSummary = result.summary + (result.failures > 0 ? "（\(result.failures) 项未能应用）" : "")
            m.opsState = result.isEmpty ? .failed : .applied
        }
        if result.replaced { map.fit() }
    }

    func revert(_ id: UUID) {
        guard let m = messages.first(where: { $0.id == id }), let before = m.before else { return }
        map.mutate { $0 = before }
        update(currentID, id) { $0.opsState = .reverted }
    }

    func canRevert(_ m: ChatMessage) -> Bool {
        m.opsState == .applied && m.revision == map.revision
    }

    func insertIntoMap(_ id: UUID) {
        guard let m = messages.first(where: { $0.id == id }) else { return }
        let nodes = MapAgent.nodes(fromMarkdown: MapAgent.split(m.text).display)
        guard !nodes.isEmpty else { NSSound.beep(); return }
        let target = map.selection ?? map.data.root.id
        map.mutate { d in d.root.modify(target) { $0.children.append(contentsOf: nodes); $0.collapsed = false } }
        map.selection = nodes.first?.id
    }
}
