import Foundation

enum ChatMode: String, CaseIterable, Identifiable {
    case agent, ask
    var id: String { rawValue }
    var name: String { self == .agent ? "代理" : "问答" }
    var detail: String { self == .agent ? "可直接添加、改写和整理导图" : "只回答问题，不修改导图" }
    var symbol: String { self == .agent ? "wand.and.stars" : "bubble.left.and.text.bubble.right" }
}

/// Snapshot of the map handed to the model, with short ids (n0, n1…) mapped back to real node ids.
struct MapContext {
    var outline: String
    var ids: [String: UUID]
    var selectionRef: String?
    var selectionTitle: String?

    func uuid(_ ref: Any?) -> UUID? {
        guard var s = ref as? String else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        return ids[s] ?? UUID(uuidString: s)
    }
}

struct OpsResult {
    var added = 0, renamed = 0, deleted = 0, moved = 0
    var replaced = false
    var failures = 0

    var isEmpty: Bool { added + renamed + deleted + moved == 0 && !replaced }

    var summary: String {
        if replaced { return "重新生成了导图（\(added) 个主题）" }
        var parts: [String] = []
        if added > 0 { parts.append("添加 \(added) 个主题") }
        if renamed > 0 { parts.append("改写 \(renamed) 个") }
        if moved > 0 { parts.append("移动 \(moved) 个") }
        if deleted > 0 { parts.append("删除 \(deleted) 个") }
        return parts.isEmpty ? "没有可应用的修改" : parts.joined(separator: "，")
    }
}

enum MapAgent {
    static let fence = "mindmap-ops"

    // MARK: Context

    static func context(for data: MapData, selection: UUID?) -> MapContext {
        var lines: [String] = []
        var ids: [String: UUID] = [:]
        var selRef: String?
        var selTitle: String?
        var counter = 0
        func walk(_ n: MindNode, _ level: Int) {
            let ref = "n\(counter)"; counter += 1
            ids[ref] = n.id
            if n.id == selection { selRef = ref; selTitle = n.title }
            let title = n.title.isEmpty ? "（空）" : n.title.replacingOccurrences(of: "\n", with: " ")
            lines.append(String(repeating: "  ", count: level) + "- [\(ref)] " + title + (n.collapsed ? "（已折叠）" : ""))
            for c in n.children { walk(c, level + 1) }
        }
        walk(data.root, 0)
        return MapContext(outline: lines.joined(separator: "\n"), ids: ids, selectionRef: selRef, selectionTitle: selTitle)
    }

    static func systemPrompt(mode: ChatMode, context: MapContext, includeSelection: Bool) -> String {
        var s = """
        你是 MindFlow（一款 macOS 思维导图软件）内置的 AI 助手，帮助用户发散思路、组织结构、提炼要点。
        使用与用户相同的语言回复，简洁、具体，避免空话。

        当前导图（缩进大纲，方括号内是节点 ID）：
        \(context.outline)
        """
        if includeSelection, let ref = context.selectionRef {
            s += "\n\n用户当前选中的主题：[\(ref)] \(context.selectionTitle ?? "")"
        } else {
            s += "\n\n用户当前没有选中主题。"
        }

        switch mode {
        case .agent:
            s += """


            ## 你可以直接修改导图
            当用户的请求需要修改导图时，先用一两句话说明你做了什么（不要在正文里逐条重复所有节点），然后在回复末尾输出**一个**代码块，语言标记为 \(fence)，内容是 JSON：

            ```\(fence)
            {"ops": [
              {"op": "add", "parent": "n0", "nodes": [{"title": "主题", "children": [{"title": "子主题"}]}]},
              {"op": "rename", "id": "n3", "title": "新标题"},
              {"op": "move", "id": "n5", "parent": "n2"},
              {"op": "delete", "id": "n4"},
              {"op": "replace", "root": {"title": "中心主题", "children": []}}
            ]}
            ```

            规则：
            - 只能引用上面大纲中已有的节点 ID；新节点之间的层级用嵌套的 children 表达。
            - 用户没指定位置时，新内容加到选中的主题下；没有选中则加到中心主题 [n0] 下。
            - 主题标题要短（通常不超过 16 个字），像关键词而不是句子；层级一般不超过 4 层，每层 3–7 个为宜。
            - "replace" 会替换整张导图，只在用户明确要求重新生成/从头整理时使用。
            - 如果用户只是提问、不需要修改，就正常回答，不要输出代码块。
            """
        case .ask:
            s += """


            当前是问答模式：你不能修改导图，只回答问题。使用 Markdown；如果给出适合放进导图的结构，请用嵌套的无序列表，用户可以一键插入导图。
            """
        }
        return s
    }

    // MARK: Parsing the reply

    /// Splits the visible prose from the ops block. While streaming, an unfinished block is hidden.
    static func split(_ text: String) -> (display: String, opsJSON: String?, pending: Bool) {
        guard let start = text.range(of: "```" + fence) ?? jsonOpsFence(in: text) else {
            return (text, nil, false)
        }
        let display = String(text[..<start.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rest = text[start.upperBound...]
        guard let end = rest.range(of: "```") else { return (display, nil, true) }
        let json = String(rest[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = String(rest[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (tail.isEmpty ? display : display + "\n\n" + tail, json, false)
    }

    private static func jsonOpsFence(in text: String) -> Range<String.Index>? {
        guard let r = text.range(of: "```json") else { return nil }
        let after = text[r.upperBound...].prefix(80)
        return after.contains("\"ops\"") ? r : nil
    }

    static func parseOps(_ json: String) -> [[String: Any]]? {
        guard let d = json.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) else { return nil }
        if let dict = obj as? [String: Any], let ops = dict["ops"] as? [[String: Any]] { return ops }
        if let arr = obj as? [[String: Any]] { return arr }
        return nil
    }

    // MARK: Applying

    static func apply(_ ops: [[String: Any]], context: MapContext, selection: UUID?, to data: inout MapData) -> OpsResult {
        var r = OpsResult()
        for op in ops {
            let kind = ((op["op"] ?? op["type"] ?? op["action"]) as? String)?.lowercased() ?? ""
            switch kind {
            case "add", "insert", "append":
                let parent = context.uuid(op["parent"] ?? op["id"]) ?? selection ?? data.root.id
                var specs = (op["nodes"] ?? op["children"]) as? [Any] ?? []
                if specs.isEmpty, let n = op["node"] { specs = [n] }
                if specs.isEmpty, let t = op["title"] as? String { specs = [t] }
                let nodes = specs.compactMap(node(from:))
                guard !nodes.isEmpty, data.root.contains(parent) else { r.failures += 1; continue }
                let index = op["index"] as? Int
                data.root.modify(parent) { p in
                    if let index, index >= 0, index <= p.children.count {
                        p.children.insert(contentsOf: nodes, at: index)
                    } else {
                        p.children.append(contentsOf: nodes)
                    }
                    p.collapsed = false
                }
                r.added += nodes.reduce(0) { $0 + count($1) }
            case "rename", "update", "edit":
                guard let id = context.uuid(op["id"]), let title = (op["title"] ?? op["text"]) as? String,
                      data.root.modify(id, { $0.title = clean(title) }) else { r.failures += 1; continue }
                r.renamed += 1
            case "delete", "remove":
                guard let id = context.uuid(op["id"]), id != data.root.id, data.root.remove(id) != nil else { r.failures += 1; continue }
                r.deleted += 1
            case "move":
                guard let id = context.uuid(op["id"]), let parent = context.uuid(op["parent"] ?? op["to"]),
                      id != data.root.id, let moving = data.root.find(id), !moving.contains(parent),
                      let n = data.root.remove(id) else { r.failures += 1; continue }
                data.root.modify(parent) { p in
                    if let index = op["index"] as? Int, index >= 0, index <= p.children.count {
                        p.children.insert(n, at: index)
                    } else {
                        p.children.append(n)
                    }
                    p.collapsed = false
                }
                r.moved += 1
            case "replace", "set", "generate":
                guard let spec = op["root"] ?? op["node"], let n = node(from: spec) else { r.failures += 1; continue }
                data.root = n
                r.replaced = true
                r.added = count(n)
            default:
                r.failures += 1
            }
        }
        return r
    }

    static func node(from any: Any) -> MindNode? {
        if let s = any as? String { return MindNode(title: clean(s)) }
        guard let d = any as? [String: Any] else { return nil }
        let title = ((d["title"] ?? d["text"] ?? d["name"] ?? d["topic"]) as? String).map(clean) ?? ""
        let kids = ((d["children"] ?? d["nodes"]) as? [Any] ?? []).compactMap(node(from:))
        return MindNode(title: title, children: kids)
    }

    private static func count(_ n: MindNode) -> Int { 1 + n.children.reduce(0) { $0 + count($1) } }

    private static func clean(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Markdown → nodes (for "插入导图")

    static func nodes(fromMarkdown md: String) -> [MindNode] {
        struct Item { var level: Int; var title: String }
        var items: [Item] = []
        var inCode = false
        var sawList = false
        for raw in md.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            let expanded = raw.replacingOccurrences(of: "\t", with: "    ")
            let indent = expanded.prefix { $0 == " " }.count
            var line = expanded.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            var level: Int
            if line.hasPrefix("#") {
                let hashes = line.prefix { $0 == "#" }.count
                line = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                level = -10 + hashes   // headings sit above list items
            } else if let r = line.range(of: #"^([-*+]|\d+[.)])\s+"#, options: .regularExpression) {
                line = String(line[r.upperBound...])
                level = indent / 2
                sawList = true
            } else {
                continue
            }
            line = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
            if line.hasSuffix(":") || line.hasSuffix("：") { line.removeLast() }
            if !line.isEmpty { items.append(Item(level: level, title: line)) }
        }
        if !sawList && items.isEmpty {
            items = md.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("```") }
                .map { Item(level: 0, title: $0) }
        }

        // Build the tree with a stack.
        var roots: [MindNode] = []
        var stack: [(level: Int, path: [Int])] = []
        func insert(_ node: MindNode, at path: [Int]) {
            func go(_ list: inout [MindNode], _ p: ArraySlice<Int>) {
                if p.isEmpty { list.append(node); return }
                go(&list[p.first!].children, p.dropFirst())
            }
            go(&roots, path[...])
        }
        func childCount(at path: [Int]) -> Int {
            var list = roots
            for i in path { list = list[i].children }
            return list.count
        }
        for item in items {
            while let last = stack.last, last.level >= item.level { stack.removeLast() }
            let parentPath = stack.last?.path ?? []
            let idx = childCount(at: parentPath)
            insert(MindNode(title: item.title), at: parentPath)
            stack.append((item.level, parentPath + [idx]))
        }
        return roots
    }
}
