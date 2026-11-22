import Foundation

/// Writes a `.xmind` package readable by XMind 2020+ (content.json) and XMind 8 (content.xml).
enum XMindExporter {
    static func export(_ data: MapData, sheetTitle: String = "画布 1") throws -> Data {
        let structure = data.layout == .right ? "org.xmind.ui.logic.right" : "org.xmind.ui.map.clockwise"
        let now = Int(Date().timeIntervalSince1970 * 1000)

        // content.json (XMind 2020+)
        func jsonTopic(_ n: MindNode, root: Bool) -> [String: Any] {
            var t: [String: Any] = ["id": xid(n.id), "class": "topic", "title": n.title]
            if root { t["structureClass"] = structure }
            if !n.children.isEmpty {
                t["children"] = ["attached": n.children.map { jsonTopic($0, root: false) }]
            }
            if n.collapsed && !n.children.isEmpty { t["branch"] = "folded" }
            return t
        }
        let sheet: [String: Any] = [
            "id": xid(UUID()),
            "class": "sheet",
            "title": sheetTitle,
            "rootTopic": jsonTopic(data.root, root: true),
            "topicPositioning": "fixed",
            "extensions": [] as [Any],
        ]
        let contentJSON = try JSONSerialization.data(withJSONObject: [sheet], options: [.sortedKeys])

        let metadata = try JSONSerialization.data(withJSONObject: [
            "creator": ["name": "MindFlow", "version": "1.0"],
            "dataStructureVersion": "2",
            "layoutEngineVersion": "3",
        ], options: [.sortedKeys])
        let manifestJSON = try JSONSerialization.data(withJSONObject: [
            "file-entries": ["content.json": [:], "metadata.json": [:], "content.xml": [:]] as [String: Any],
        ], options: [.sortedKeys])

        // content.xml (XMind 8 / legacy)
        func xmlTopic(_ n: MindNode, root: Bool) -> String {
            var attrs = "id=\"\(xid(n.id))\" timestamp=\"\(now)\""
            if root { attrs += " structure-class=\"\(structure)\"" }
            if n.collapsed && !n.children.isEmpty { attrs += " branch=\"folded\"" }
            var s = "<topic \(attrs)><title>\(escape(n.title))</title>"
            if !n.children.isEmpty {
                s += "<children><topics type=\"attached\">"
                s += n.children.map { xmlTopic($0, root: false) }.joined()
                s += "</topics></children>"
            }
            return s + "</topic>"
        }
        let contentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <xmap-content xmlns="urn:xmind:xmap:xmlns:content:2.0" xmlns:fo="http://www.w3.org/1999/XSL/Format" \
        xmlns:svg="http://www.w3.org/2000/svg" xmlns:xhtml="http://www.w3.org/1999/xhtml" \
        xmlns:xlink="http://www.w3.org/1999/xlink" modified-by="MindFlow" timestamp="\(now)" version="2.0">\
        <sheet id="\(xid(UUID()))" timestamp="\(now)">\(xmlTopic(data.root, root: true))<title>\(escape(sheetTitle))</title></sheet>\
        </xmap-content>
        """
        let manifestXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <manifest xmlns="urn:xmind:xmap:xmlns:manifest:1.0" password-hint="">\
        <file-entry full-path="content.xml" media-type="text/xml"/>\
        <file-entry full-path="META-INF/" media-type=""/>\
        <file-entry full-path="META-INF/manifest.xml" media-type="text/xml"/>\
        </manifest>
        """

        var zip = ZipWriter()
        zip.add("content.json", contentJSON)
        zip.add("metadata.json", metadata)
        zip.add("manifest.json", manifestJSON)
        zip.add("content.xml", Data(contentXML.utf8))
        zip.add("META-INF/manifest.xml", Data(manifestXML.utf8))
        return zip.finish()
    }

    private static func xid(_ u: UUID) -> String {
        u.uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(26).description
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Minimal ZIP writer (stored entries, UTF-8 names). Enough for document packages.
struct ZipWriter {
    private var body = Data()
    private var central = Data()
    private var count: UInt16 = 0
    private let dos: (time: UInt16, date: UInt16) = {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date())
        let t = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2)
        let d = UInt16(max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (t, d)
    }()
    private var dosTime: UInt16 { dos.time }
    private var dosDate: UInt16 { dos.date }

    mutating func add(_ name: String, _ data: Data) {
        let nameData = Data(name.utf8)
        let crc = CRC32.checksum(data)
        let offset = UInt32(body.count)

        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(0)
        local.le16(dosTime); local.le16(dosDate)
        local.le32(crc); local.le32(UInt32(data.count)); local.le32(UInt32(data.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        body.append(local); body.append(nameData); body.append(data)

        var cd = Data()
        cd.le32(0x02014b50); cd.le16(20); cd.le16(20); cd.le16(0x0800); cd.le16(0)
        cd.le16(dosTime); cd.le16(dosDate)
        cd.le32(crc); cd.le32(UInt32(data.count)); cd.le32(UInt32(data.count))
        cd.le16(UInt16(nameData.count)); cd.le16(0); cd.le16(0); cd.le16(0); cd.le16(0)
        cd.le32(0); cd.le32(offset)
        central.append(cd); central.append(nameData)
        count += 1
    }

    func finish() -> Data {
        var out = body
        let cdOffset = UInt32(out.count)
        out.append(central)
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0); end.le16(count); end.le16(count)
        end.le32(UInt32(central.count)); end.le32(cdOffset); end.le16(0)
        out.append(end)
        return out
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}
