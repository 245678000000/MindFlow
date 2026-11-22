import AppKit
import SwiftUI

/// Lightweight GitHub-Releases based updater: check → download → replace bundle → relaunch.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()
    static let repo = "245678000000/MindFlow"

    struct Release: Equatable {
        var version: String
        var name: String
        var notes: String
        var page: URL
        var asset: URL?
        var assetSize: Int
        var date: Date?
    }

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case downloading(Release, Double)
        case installing(Release)
        case failed(String)
    }

    var phase: Phase = .idle
    var windowRequest = 0

    var autoCheck: Bool {
        get { UserDefaults.standard.object(forKey: "update.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "update.auto") }
    }

    var lastCheck: Date? { UserDefaults.standard.object(forKey: "update.last") as? Date }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    private var downloadTask: Task<Void, Never>?

    // MARK: Checking

    /// Called at launch: silent, at most once a day, only surfaces UI when an update exists.
    func checkIfDue() {
        guard autoCheck else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 20 * 3600 { return }
        Task { await check(userInitiated: false) }
    }

    func check(userInitiated: Bool) async {
        if case .downloading = phase { return }
        if userInitiated { phase = .checking; windowRequest += 1 }
        do {
            let r = try await fetchLatest()
            UserDefaults.standard.set(Date(), forKey: "update.last")
            let skipped = UserDefaults.standard.string(forKey: "update.skip")
            if Self.compare(r.version, Self.currentVersion) > 0 {
                if userInitiated || skipped != r.version {
                    phase = .available(r)
                    windowRequest += 1
                }
            } else if userInitiated {
                phase = .upToDate
            }
        } catch {
            if userInitiated { phase = .failed(error.localizedDescription) }
        }
    }

    private func fetchLatest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MindFlow/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw UpdateError("还没有发布任何版本") }
        guard code == 200, let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String else { throw UpdateError("无法获取版本信息（HTTP \(code)）") }

        let assets = j["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(".zip") == true }
        let iso = ISO8601DateFormatter()
        return Release(
            version: tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV")),
            name: (j["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? tag,
            notes: j["body"] as? String ?? "",
            page: URL(string: j["html_url"] as? String ?? "https://github.com/\(Self.repo)/releases")!,
            asset: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)),
            assetSize: zip?["size"] as? Int ?? 0,
            date: (j["published_at"] as? String).flatMap { iso.date(from: $0) })
    }

    static func compare(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x < y ? -1 : 1 }
        }
        return 0
    }

    func skip(_ r: Release) {
        UserDefaults.standard.set(r.version, forKey: "update.skip")
        phase = .idle
    }

    // MARK: Installing

    func install(_ r: Release) {
        guard let url = r.asset else { NSWorkspace.shared.open(r.page); return }
        phase = .downloading(r, 0)
        downloadTask = Task {
            do {
                let zip = try await download(url, total: r.assetSize) { [weak self] p in
                    self?.phase = .downloading(r, p)
                }
                phase = .installing(r)
                try await replaceAndRelaunch(with: zip)
            } catch is CancellationError {
                phase = .available(r)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    func cancelDownload() { downloadTask?.cancel() }

    private func download(_ url: URL, total: Int, progress: @escaping (Double) -> Void) async throws -> URL {
        let (bytes, resp) = try await URLSession.shared.bytes(from: url)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("下载失败") }
        let expected = max(Int(resp.expectedContentLength), total, 1)
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MindFlow-update-\(UUID().uuidString).zip")
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dest)
        defer { try? handle.close() }
        var buffer = Data(); buffer.reserveCapacity(1 << 16)
        var received = 0
        for try await b in bytes {
            buffer.append(b)
            if buffer.count >= 1 << 16 {
                try Task.checkCancellation()
                handle.write(buffer); received += buffer.count; buffer.removeAll(keepingCapacity: true)
                progress(min(Double(received) / Double(expected), 1))
            }
        }
        handle.write(buffer)
        progress(1)
        return dest
    }

    private func replaceAndRelaunch(with zip: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MindFlow-update-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        try await run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
        guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else { throw UpdateError("安装包里没有找到 App") }

        let current = Bundle.main.bundleURL
        let parent = current.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            NSWorkspace.shared.activateFileViewerSelecting([newApp])
            throw UpdateError("没有权限替换 \(parent.path) 中的 App，已在 Finder 中打开新版本，请手动拖入。")
        }

        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        DEST=\(shellQuote(current.path)); NEW=\(shellQuote(newApp.path))
        rm -rf "$DEST.old"
        if mv "$DEST" "$DEST.old" && /usr/bin/ditto "$NEW" "$DEST"; then rm -rf "$DEST.old"; else rm -rf "$DEST"; mv "$DEST.old" "$DEST"; fi
        /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        /usr/bin/open "$DEST"
        rm -rf \(shellQuote(work.path)) \(shellQuote(zip.path))
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        try p.run()
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ args: [String]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: tool)
            p.arguments = args
            p.terminationHandler = { p in
                p.terminationStatus == 0 ? c.resume() : c.resume(throwing: UpdateError("解压失败"))
            }
            do { try p.run() } catch { c.resume(throwing: error) }
        }
    }

    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Window

struct UpdateWindow: View {
    @Bindable var updater = Updater.shared
    @Environment(\.dismissWindow) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                    Text(subtitle).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 16)

            content
        }
        .frame(width: 480)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch updater.phase {
        case .available(let r), .downloading(let r, _), .installing(let r):
            notes(r)
            Divider()
            footer(r)
        case .checking:
            ProgressView().controlSize(.small).padding(.bottom, 24)
        case .upToDate, .failed, .idle:
            HStack {
                Toggle("自动检查更新", isOn: Binding(get: { updater.autoCheck }, set: { updater.autoCheck = $0 }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
                Spacer()
                Button("好") { dismiss(id: "updater") }.keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24).padding(.bottom, 20)
        }
    }

    private func notes(_ r: Release) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(r.name).font(.system(size: 13, weight: .semibold))
                    if let d = r.date {
                        Text(d.formatted(date: .abbreviated, time: .omitted)).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    }
                }
                MarkdownView(text: r.notes.isEmpty ? "此版本没有更新说明。" : r.notes)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(height: 200)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private typealias Release = Updater.Release

    @ViewBuilder private func footer(_ r: Release) -> some View {
        HStack(spacing: 10) {
            switch updater.phase {
            case .downloading(_, let p):
                ProgressView(value: p).progressViewStyle(.linear).frame(maxWidth: .infinity)
                Text("\(Int(p * 100))%").font(.system(size: 11.5).monospacedDigit()).foregroundStyle(.secondary).frame(width: 36)
                Button("取消") { updater.cancelDownload() }
            case .installing:
                ProgressView().controlSize(.small)
                Text("正在安装，MindFlow 将自动重新打开…").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            default:
                Button("跳过此版本") { updater.skip(r); dismiss(id: "updater") }
                Spacer()
                Button("稍后提醒") { updater.phase = .idle; dismiss(id: "updater") }
                    .keyboardShortcut(.cancelAction)
                Button(r.asset == nil ? "前往下载" : "下载并安装") { updater.install(r) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var title: String {
        switch updater.phase {
        case .checking: return "正在检查更新…"
        case .upToDate: return "已是最新版本"
        case .failed: return "检查更新失败"
        case .available(let r), .downloading(let r, _), .installing(let r): return "MindFlow \(r.version) 现已推出"
        case .idle: return "MindFlow"
        }
    }

    private var subtitle: String {
        let cur = Updater.currentVersion
        switch updater.phase {
        case .checking: return "正在连接 GitHub…"
        case .upToDate: return "MindFlow \(cur) 是目前的最新版本。"
        case .failed(let e): return e
        case .available(let r), .downloading(let r, _), .installing(let r):
            let size = r.assetSize > 0 ? " · \(ByteCountFormatter.string(fromByteCount: Int64(r.assetSize), countStyle: .file))" : ""
            return "你当前使用的是 \(cur)。要现在更新吗？\(size)"
        case .idle: return "版本 \(cur)"
        }
    }
}
