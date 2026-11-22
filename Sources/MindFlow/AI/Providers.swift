import Foundation
import SwiftUI

enum APIKind: String, Codable, CaseIterable, Identifiable {
    case anthropic, openaiChat, openaiResponses
    var id: String { rawValue }
    var name: String {
        switch self {
        case .anthropic: return "Anthropic Messages"
        case .openaiChat: return "OpenAI Chat Completions"
        case .openaiResponses: return "OpenAI Responses"
        }
    }
    var short: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openaiChat: return "OpenAI"
        case .openaiResponses: return "Responses"
        }
    }
}

struct AIProvider: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var kind: APIKind
    var baseURL: String
    var apiKey: String
    var models: [String]
    var source: String?

    var host: String { URLComponents(string: baseURL)?.host ?? baseURL }

    /// Used for duplicate detection on import.
    var fingerprint: String {
        "\(kind.rawValue)|\(baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased())|\(apiKey)"
    }
}

@MainActor
@Observable
final class ProviderStore {
    static let shared = ProviderStore()

    var providers: [AIProvider] = [] { didSet { if loaded { save() } } }
    var currentProviderID: UUID? {
        didSet { UserDefaults.standard.set(currentProviderID?.uuidString, forKey: "ai.provider") }
    }
    var currentModel: String = "" {
        didSet { UserDefaults.standard.set(currentModel, forKey: "ai.model") }
    }

    private var loaded = false

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MindFlow", isDirectory: true)
        return dir.appendingPathComponent("providers.json")
    }

    private init() {
        if let d = try? Data(contentsOf: fileURL), let list = try? JSONDecoder().decode([AIProvider].self, from: d) {
            providers = list
        }
        if let s = UserDefaults.standard.string(forKey: "ai.provider") { currentProviderID = UUID(uuidString: s) }
        currentModel = UserDefaults.standard.string(forKey: "ai.model") ?? ""
        loaded = true
        normalizeSelection()
    }

    var current: (provider: AIProvider, model: String)? {
        guard let p = providers.first(where: { $0.id == currentProviderID }) ?? providers.first else { return nil }
        let m = p.models.contains(currentModel) ? currentModel : (p.models.first ?? "")
        return m.isEmpty ? nil : (p, m)
    }

    func select(_ p: AIProvider, model: String) {
        currentProviderID = p.id
        currentModel = model
    }

    func normalizeSelection() {
        if let c = current {
            if currentProviderID != c.provider.id { currentProviderID = c.provider.id }
            if currentModel != c.model { currentModel = c.model }
        }
    }

    func add(_ list: [AIProvider]) {
        let existing = Set(providers.map(\.fingerprint))
        providers.append(contentsOf: list.filter { !existing.contains($0.fingerprint) })
        normalizeSelection()
    }

    func contains(_ p: AIProvider) -> Bool { providers.contains { $0.fingerprint == p.fingerprint } }

    private func save() {
        do {
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(providers).write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("MindFlow: failed to save providers: \(error)")
        }
    }
}
