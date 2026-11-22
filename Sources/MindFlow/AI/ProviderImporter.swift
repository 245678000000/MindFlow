import Foundation
import SQLite3

struct ImportCandidate: Identifiable {
    enum Status: Equatable { case ok, duplicate, invalid(String) }
    let id = UUID()
    var provider: AIProvider
    var status: Status
    var detail: String?
    var selected: Bool

    var importable: Bool { status == .ok }
}

struct ImportSource: Identifiable {
    let id: String
    var name: String
    var symbol: String
    var location: String?
    var candidates: [ImportCandidate]
    var found: Bool { location != nil }
    var importableCount: Int { candidates.filter(\.importable).count }

    var subtitle: String {
        guard found else { return "未在本机找到" }
        return "可导入 \(importableCount) 个，共 \(candidates.count) 个"
    }
}

@MainActor
enum ProviderImporter {
    static let defaultAnthropicModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    // MARK: Sources

    static func ccSwitch(store: ProviderStore) -> ImportSource {
        let dir = home.appendingPathComponent(".cc-switch")
        let db = dir.appendingPathComponent("cc-switch.db")
        let json = dir.appendingPathComponent("config.json")
        var src = ImportSource(id: "cc-switch", name: "cc-switch", symbol: "arrow.triangle.swap", location: nil, candidates: [])
        if FileManager.default.fileExists(atPath: db.path) {
            src.location = db.path
            src.candidates = finalize(readCCSwitchDB(db.path), store: store)
        } else if FileManager.default.fileExists(atPath: json.path) {
            src.location = json.path
            src.candidates = finalize(readJSONFile(json), store: store)
        }
        return src
    }

    static func magpie(store: ProviderStore) -> ImportSource {
        var src = ImportSource(id: "magpie", name: "magpie", symbol: "bird", location: nil, candidates: [])
        let candidates = [
            home.appendingPathComponent(".config/magpie/providers.json"),
            home.appendingPathComponent(".magpie/providers.json"),
            appSupport.appendingPathComponent("magpie/providers.json"),
            appSupport.appendingPathComponent("com.yetone.magpie/providers.json"),
        ]
        guard let file = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return src }
        src.location = file.path
        src.candidates = finalize(readMagpie(file), store: store)
        return src
    }

    private static func readMagpie(_ url: URL) -> [ImportCandidate] {
        guard let d = try? Data(contentsOf: url), let obj = try? JSONSerialization.jsonObject(with: d) else { return [] }
        let list = ((obj as? [String: Any])?["providers"] as? [[String: Any]]) ?? (obj as? [[String: Any]]) ?? []
        guard !list.isEmpty else { var out: [ImportCandidate] = []; scan(obj, hint: nil, app: nil, into: &out); return out }
        return list.map(magpieCandidate)
    }

    static func magpieCandidate(_ p: [String: Any]) -> ImportCandidate {
        let id = p["id"] as? String ?? "magpie"
        let name = (p["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
        let api = (p["baseAPI"] as? String ?? "chat").lowercased()
        let url = [api, "chat", "responses", "anthropic", "messages", "baseURL", "baseUrl"]
            .compactMap { p[$0] as? String }.first { $0.lowercased().hasPrefix("http") }
        let kind: APIKind = api.contains("anthropic") || api.contains("messages") ? .anthropic
            : api.contains("response") ? .openaiResponses : .openaiChat
        guard let key = (p["key"] as? String ?? p["apiKey"] as? String), !key.isEmpty else {
            return invalid(name, "通过 OAuth 登录，无 API Key", kind: kind, base: url ?? "")
        }
        guard let url else { return invalid(name, "缺少接口地址", kind: kind) }
        var models = modelList(p)
        if models.isEmpty && kind == .anthropic { models = defaultAnthropicModels }
        return ok(AIProvider(name: name, kind: kind, baseURL: url, apiKey: key, models: models, source: "magpie"),
                  detail: kind.short)
    }

    static func fromFile(_ url: URL, store: ProviderStore) -> ImportSource {
        let ext = url.pathExtension.lowercased()
        var list: [ImportCandidate]
        if ["db", "sqlite", "sqlite3"].contains(ext) {
            list = readCCSwitchDB(url.path)
            if list.isEmpty { list = readGenericDB(url.path) }
        } else {
            list = readJSONFile(url)
        }
        return ImportSource(id: "file", name: url.lastPathComponent, symbol: "doc", location: url.path,
                            candidates: finalize(dedupe(list), store: store))
    }

    // MARK: cc-switch

    private static func readCCSwitchDB(_ path: String) -> [ImportCandidate] {
        var out: [ImportCandidate] = []
        withDB(path) { db in
            let sql = "SELECT name, app_type, settings_config FROM providers"
            query(db, sql) { row in
                let name = row[0] ?? "未命名"
                let app = row[1] ?? ""
                guard let cfg = row[2], let d = cfg.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
                    out.append(invalid(name, "配置无法解析")); return
                }
                out.append(ccSwitchCandidate(name: name, app: app, settings: obj))
            }
        }
        return out
    }

    static func ccSwitchCandidate(name: String, app: String, settings s: [String: Any]) -> ImportCandidate {
        let env = s["env"] as? [String: Any] ?? [:]
        func e(_ k: String) -> String? { (env[k] as? String).flatMap { $0.isEmpty ? nil : $0 } }

        switch app.lowercased() {
        case "claude":
            let key = e("ANTHROPIC_AUTH_TOKEN") ?? e("ANTHROPIC_API_KEY")
            let base = e("ANTHROPIC_BASE_URL") ?? "https://api.anthropic.com"
            var models = ["ANTHROPIC_MODEL", "ANTHROPIC_DEFAULT_OPUS_MODEL", "ANTHROPIC_DEFAULT_SONNET_MODEL",
                          "ANTHROPIC_DEFAULT_FABLE_MODEL", "ANTHROPIC_DEFAULT_HAIKU_MODEL", "ANTHROPIC_SMALL_FAST_MODEL",
                          "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME", "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
                          "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME"].compactMap(e)
            models = unique(models)
            if models.isEmpty { models = defaultAnthropicModels }
            guard let key else { return invalid(name, "没有 API Key（可能使用官方登录）", kind: .anthropic, base: base) }
            return ok(AIProvider(name: name, kind: .anthropic, baseURL: base, apiKey: key, models: models, source: "cc-switch"),
                      detail: "Claude Code")
        case "codex":
            let auth = s["auth"] as? [String: Any] ?? [:]
            let key = (auth["OPENAI_API_KEY"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let toml = s["config"] as? String ?? ""
            let t = parseCodexTOML(toml)
            let base = t.baseURL ?? "https://api.openai.com/v1"
            let kind: APIKind = (t.wireAPI ?? "responses") == "chat" ? .openaiChat : .openaiResponses
            guard let key else { return invalid(name, "没有 API Key（可能使用 ChatGPT 登录）", kind: kind, base: base) }
            return ok(AIProvider(name: name, kind: kind, baseURL: base, apiKey: key,
                                 models: t.model.map { [$0] } ?? [], source: "cc-switch"), detail: "Codex")
        case "gemini":
            guard let key = e("GEMINI_API_KEY") ?? e("GOOGLE_API_KEY") else { return invalid(name, "没有 API Key") }
            let custom = e("GOOGLE_GEMINI_BASE_URL")
            let base = custom ?? "https://generativelanguage.googleapis.com/v1beta/openai"
            if custom != nil && !base.contains("openai") {
                return invalid(name, "自定义 Gemini 地址不兼容 OpenAI 格式", kind: .openaiChat, base: base)
            }
            return ok(AIProvider(name: name, kind: .openaiChat, baseURL: base, apiKey: key,
                                 models: [e("GEMINI_MODEL") ?? "gemini-2.5-flash"], source: "cc-switch"), detail: "Gemini")
        default:
            // Unknown app type – try the generic heuristics on the settings blob.
            var found: [ImportCandidate] = []
            scan(s, hint: name, app: nil, into: &found)
            guard var c = found.first else { return invalid(name, "没有 API Key 或接口地址") }
            c.provider.name = name
            c.provider.source = "cc-switch"
            c.detail = app
            return c
        }
    }

    private static func parseCodexTOML(_ s: String) -> (model: String?, baseURL: String?, wireAPI: String?) {
        func value(_ key: String, in text: Substring) -> String? {
            let pattern = #"(?m)^\s*"# + key + #"\s*=\s*"([^"]*)""#
            guard let r = text.range(of: pattern, options: .regularExpression) else { return nil }
            let line = text[r]
            guard let q1 = line.firstIndex(of: "\"") else { return nil }
            let rest = line[line.index(after: q1)...]
            return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
        }
        let all = Substring(s)
        let top = all.range(of: "\n[").map { all[..<$0.lowerBound] } ?? all
        let model = value("model", in: top)
        var section = all
        if let provider = value("model_provider", in: all),
           let r = all.range(of: "[model_providers.\(provider)]") {
            section = all[r.upperBound...]
            if let next = section.range(of: "\n[") { section = section[..<next.lowerBound] }
        }
        return (model, value("base_url", in: section), value("wire_api", in: section))
    }

    // MARK: Generic JSON

    private static func readJSONFile(_ url: URL) -> [ImportCandidate] {
        guard let d = try? Data(contentsOf: url), d.count < 20_000_000,
              let obj = try? JSONSerialization.jsonObject(with: d) else { return [] }
        var out: [ImportCandidate] = []
        scan(obj, hint: nil, app: nil, into: &out)
        return out
    }

    private static let keyFields = ["apiKey", "api_key", "apikey", "key", "token", "apiToken", "api_token",
                                    "authToken", "auth_token", "secret", "accessToken", "ANTHROPIC_AUTH_TOKEN",
                                    "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
    private static let urlFields = ["baseURL", "baseUrl", "base_url", "apiBase", "api_base", "apiBaseUrl", "endpoint",
                                    "url", "apiHost", "api_host", "host", "chat", "ANTHROPIC_BASE_URL", "OPENAI_BASE_URL"]
    private static let nameFields = ["name", "title", "label", "displayName", "display_name", "provider", "id"]
    private static let typeFields = ["api", "baseAPI", "npm", "type", "kind", "protocol", "format", "apiType", "api_type", "apiFormat",
                                     "api_format", "wire_api", "provider", "sdk", "compatibility"]

    private static func scan(_ any: Any, hint: String?, app: String?, into out: inout [ImportCandidate]) {
        if let arr = any as? [Any] {
            for v in arr { scan(v, hint: hint, app: app, into: &out) }
            return
        }
        guard var d = any as? [String: Any] else { return }
        if let opts = d["options"] as? [String: Any] { d.merge(opts) { a, _ in a } }

        // cc-switch legacy config.json entries
        if let settings = (d["settingsConfig"] ?? d["settings_config"]) as? [String: Any] {
            let name = (d["name"] as? String) ?? hint ?? "未命名"
            out.append(ccSwitchCandidate(name: name, app: app ?? (d["app_type"] as? String) ?? "", settings: settings))
            return
        }

        func str(_ keys: [String]) -> String? {
            for k in keys { if let s = d[k] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s } }
            return nil
        }
        if let key = str(keyFields), let base = str(urlFields), base.lowercased().hasPrefix("http") {
            let name = str(nameFields) ?? hint ?? URLComponents(string: base)?.host ?? "未命名"
            let typeHint = (str(typeFields) ?? "").lowercased()
            let kind: APIKind
            if typeHint.contains("anthropic") || typeHint.contains("claude") || base.contains("anthropic") { kind = .anthropic }
            else if typeHint.contains("response") { kind = .openaiResponses }
            else { kind = .openaiChat }
            var models = modelList(d)
            if models.isEmpty && kind == .anthropic { models = defaultAnthropicModels }
            let enabled = (d["enabled"] as? Bool) ?? (d["isEnabled"] as? Bool) ?? true
            let p = AIProvider(name: name, kind: kind, baseURL: base, apiKey: key, models: models, source: "import")
            out.append(enabled ? ok(p, detail: kind.short) : ImportCandidate(provider: p, status: .invalid("已停用"), detail: kind.short, selected: false))
            return
        }

        for (k, v) in d {
            let app2 = ["claude", "codex", "gemini"].contains(k.lowercased()) ? k : app
            scan(v, hint: (v is [String: Any]) ? k : hint, app: app2, into: &out)
        }
    }

    private static func modelList(_ d: [String: Any]) -> [String] {
        var out: [String] = []
        for k in ["models", "modelList", "model_list", "availableModels"] {
            if let arr = d[k] as? [Any] {
                for m in arr {
                    if let s = m as? String { out.append(s) }
                    else if let md = m as? [String: Any], let s = (md["id"] ?? md["name"] ?? md["model"]) as? String {
                        if (md["enabled"] as? Bool) != false { out.append(s) }
                    }
                }
            } else if let dict = d[k] as? [String: Any] {
                out += dict.keys.sorted()
            } else if let s = d[k] as? String, let data = s.data(using: .utf8),
                      let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
                out += arr
            } else if let s = d[k] as? String {
                out += s.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }
            }
        }
        for k in ["model", "defaultModel", "default_model", "selectedModel"] {
            if let s = d[k] as? String, !s.isEmpty { out.insert(s, at: 0) }
        }
        return unique(out.filter { !$0.isEmpty })
    }

    // MARK: SQLite helpers

    private static func readGenericDB(_ path: String) -> [ImportCandidate] {
        var out: [ImportCandidate] = []
        withDB(path) { db in
            var tables: [String] = []
            query(db, "SELECT name FROM sqlite_master WHERE type='table'") { if let t = $0[0] { tables.append(t) } }
            for t in tables where t.lowercased().contains("provider") || t.lowercased().contains("config") {
                query(db, "SELECT * FROM \"\(t.replacingOccurrences(of: "\"", with: ""))\" LIMIT 500") { row in
                    for cell in row {
                        guard let c = cell, c.hasPrefix("{") || c.hasPrefix("["),
                              let d = c.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) else { continue }
                        scan(obj, hint: row.first ?? nil, app: nil, into: &out)
                    }
                }
            }
        }
        return out
    }

    private static func withDB(_ path: String, _ body: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return
        }
        sqlite3_busy_timeout(db, 1500)
        body(db)
        sqlite3_close(db)
    }

    private static func query(_ db: OpaquePointer, _ sql: String, _ row: ([String?]) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return }
        defer { sqlite3_finalize(stmt) }
        let n = sqlite3_column_count(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW {
            var values: [String?] = []
            for i in 0..<n {
                if let c = sqlite3_column_text(stmt, i) { values.append(String(cString: c)) } else { values.append(nil) }
            }
            row(values)
        }
    }

    // MARK: Helpers

    private static func configFiles(in root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey],
                                                     options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let url as URL in e {
            if e.level > 3 { e.skipDescendants(); continue }
            let name = url.lastPathComponent.lowercased()
            if ["logs", "log", "cache", "caches", "backups", "node_modules"].contains(name) { e.skipDescendants(); continue }
            let ext = url.pathExtension.lowercased()
            if ["json", "db", "sqlite"].contains(ext) { out.append(url) }
            if out.count > 60 { break }
        }
        return out
    }

    private static func ok(_ p: AIProvider, detail: String?) -> ImportCandidate {
        ImportCandidate(provider: p, status: .ok, detail: detail, selected: true)
    }

    private static func invalid(_ name: String, _ reason: String, kind: APIKind = .openaiChat, base: String = "") -> ImportCandidate {
        ImportCandidate(provider: AIProvider(name: name, kind: kind, baseURL: base, apiKey: "", models: []),
                        status: .invalid(reason), detail: nil, selected: false)
    }

    private static func unique(_ a: [String]) -> [String] {
        var seen = Set<String>()
        return a.filter { seen.insert($0).inserted }
    }

    private static func dedupe(_ list: [ImportCandidate]) -> [ImportCandidate] {
        var seen = Set<String>()
        return list.filter { c in
            guard c.status == .ok else { return true }
            return seen.insert(c.provider.fingerprint).inserted
        }
    }

    private static func finalize(_ list: [ImportCandidate], store: ProviderStore) -> [ImportCandidate] {
        var seen = Set<String>()
        return list.map { c in
            var c = c
            if c.status == .ok, c.provider.host.hasSuffix("example.com") || c.provider.apiKey.contains("your-") {
                c.status = .invalid("示例配置")
                c.selected = false
            }
            if c.status == .ok {
                if store.contains(c.provider) || !seen.insert(c.provider.fingerprint).inserted {
                    c.status = .duplicate
                    c.selected = false
                } else if c.provider.models.isEmpty {
                    c.detail = (c.detail.map { $0 + " · " } ?? "") + "需补充模型名"
                }
            }
            return c
        }
    }
}
