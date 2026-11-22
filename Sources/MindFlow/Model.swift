import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let mindMap = UTType(exportedAs: "com.tiantian.mindflow.mindmap", conformingTo: .json)
}

// MARK: - Node

struct MindNode: Identifiable, Equatable, Codable {
    var id: UUID
    var title: String
    var children: [MindNode]
    var collapsed: Bool
    var colorIndex: Int?

    init(id: UUID = UUID(), title: String, children: [MindNode] = [], collapsed: Bool = false, colorIndex: Int? = nil) {
        self.id = id
        self.title = title
        self.children = children
        self.collapsed = collapsed
        self.colorIndex = colorIndex
    }

    enum CodingKeys: String, CodingKey { case id, title, children, collapsed, colorIndex = "color" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        children = try c.decodeIfPresent([MindNode].self, forKey: .children) ?? []
        collapsed = try c.decodeIfPresent(Bool.self, forKey: .collapsed) ?? false
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        if !children.isEmpty { try c.encode(children, forKey: .children) }
        if collapsed { try c.encode(collapsed, forKey: .collapsed) }
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
    }
}

extension MindNode {
    func find(_ id: UUID) -> MindNode? {
        if self.id == id { return self }
        for c in children { if let f = c.find(id) { return f } }
        return nil
    }

    func parentID(of id: UUID) -> UUID? {
        for c in children {
            if c.id == id { return self.id }
            if let p = c.parentID(of: id) { return p }
        }
        return nil
    }

    func contains(_ id: UUID) -> Bool { find(id) != nil }

    @discardableResult
    mutating func modify(_ id: UUID, _ body: (inout MindNode) -> Void) -> Bool {
        if self.id == id { body(&self); return true }
        for i in children.indices where children[i].modify(id, body) { return true }
        return false
    }

    mutating func remove(_ id: UUID) -> MindNode? {
        if let i = children.firstIndex(where: { $0.id == id }) { return children.remove(at: i) }
        for i in children.indices { if let r = children[i].remove(id) { return r } }
        return nil
    }
}

// MARK: - Document data

enum LayoutStyle: String, Codable, CaseIterable, Identifiable {
    case balanced, right
    var id: String { rawValue }
    var name: String { self == .balanced ? "平衡布局" : "向右布局" }
    var symbol: String { self == .balanced ? "arrow.left.and.right" : "arrow.right" }
}

struct MapData: Codable, Equatable {
    var version = 1
    var root: MindNode
    var theme = 0
    var layout: LayoutStyle = .balanced

    init(root: MindNode, theme: Int = 0, layout: LayoutStyle = .balanced) {
        self.root = root; self.theme = theme; self.layout = layout
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        root = try c.decode(MindNode.self, forKey: .root)
        theme = try c.decodeIfPresent(Int.self, forKey: .theme) ?? 0
        layout = (try? c.decodeIfPresent(LayoutStyle.self, forKey: .layout)) ?? .balanced
    }

    static var sample: MapData {
        MapData(root: MindNode(title: "中心主题", children: (1...4).map { MindNode(title: "分支主题 \($0)") }))
    }
}

struct MindMapDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.mindMap] }

    var data: MapData

    init(data: MapData = .sample) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        data = try JSONDecoder().decode(MapData.self, from: d)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try enc.encode(data))
    }
}
