import CryptoKit
import Darwin
import Foundation

final class ChatArchive {
    static let shared = ChatArchive(
        root: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.astrachat.desktop", isDirectory: true)
    )

    private struct Record: Codable {
        let id: UUID
        let createdAt: Date
        let json: Data
        let markdown: String

        var path: String { ChatArchive.remotePath(id: id, createdAt: createdAt) }
    }

    private struct Receipt: Codable {
        var uploadedDigest: String?
        var verifiedBlob: String?
        var attemptedBlob: String?
    }

    private struct Pending {
        let record: Record
        let digest: String
    }

    private struct ArchiveError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private struct GitHubRepository: Decodable, Equatable {
        let id: Int64
        let fullName: String
        let isPrivate: Bool
        let visibility: String
        let defaultBranch: String

        enum CodingKeys: String, CodingKey {
            case id, visibility
            case fullName = "full_name"
            case isPrivate = "private"
            case defaultBranch = "default_branch"
        }
    }

    private struct Remote {
        let url: String
        let branch: String
        let receiptNamespace: String
        let gitOptions: [String]
        let verifyPrivate: () throws -> Void

        static func github(_ repository: String) throws -> Remote {
            guard let cli = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first(where: {
                FileManager.default.isExecutableFile(atPath: $0)
            }) else {
                throw ArchiveError(message: "找不到 GitHub CLI，聊天已留在本机。")
            }
            func verify() throws -> GitHubRepository {
                let identity = try ChatArchive.run(
                    cli, ["api", "--hostname", "github.com", "repos/\(repository)",
                          "--jq", "{id, full_name, private, visibility, default_branch}"],
                    failure: "无法核验 GitHub 私有仓库，请检查网络和 GitHub CLI 登录。"
                )
                guard let metadata = try? JSONDecoder().decode(GitHubRepository.self, from: Data(identity.utf8)),
                      metadata.id > 0,
                      ChatArchive.validRepository(metadata.fullName),
                      metadata.fullName.lowercased() == repository.lowercased(),
                      metadata.isPrivate, metadata.visibility == "private",
                      metadata.defaultBranch.range(of: #"\A[A-Za-z0-9_][A-Za-z0-9._/-]{0,254}\z"#,
                                                   options: .regularExpression) != nil else {
                    throw ArchiveError(message: "GitHub 仓库身份、私有状态或默认分支验证失败，聊天已留在本机。")
                }
                _ = try ChatArchive.run("/usr/bin/git", ["check-ref-format", "refs/heads/" + metadata.defaultBranch],
                                        failure: "GitHub 仓库默认分支无效，聊天已留在本机。")
                return metadata
            }
            let metadata = try verify()
            let namespace = ChatArchive.digest("\(metadata.id)\n\(metadata.defaultBranch)")
            return Remote(
                url: "https://github.com/\(metadata.fullName).git",
                branch: metadata.defaultBranch,
                receiptNamespace: namespace,
                gitOptions: [
                    "-c", "credential.helper=",
                    "-c", "credential.https://github.com.helper=!\(cli) auth git-credential",
                    "-c", "http.followRedirects=false"
                ]
            ) {
                guard try verify() == metadata else {
                    throw ArchiveError(message: "GitHub 仓库设置已变化，聊天已留在本机。")
                }
            }
        }
    }

    private let root: URL
    private let defaults: UserDefaults
    private let makeRemote: (String?) throws -> Remote?
    private let files = FileManager.default
    private let queue = DispatchQueue(label: "app.astrachat.desktop.archive", qos: .utility)
    private var records: URL { root.appendingPathComponent("Conversations", isDirectory: true) }
    private var receipts: URL { root.appendingPathComponent("Synced", isDirectory: true) }
    private static let repositoryKey = "archiveRepository"

    var repository: String? {
        guard let value = defaults.string(forKey: Self.repositoryKey), Self.validRepository(value) else { return nil }
        return value.lowercased()
    }

    private init(
        root: URL, defaults: UserDefaults = .standard,
        makeRemote: @escaping (String?) throws -> Remote? = { try $0.map(Remote.github) }
    ) {
        self.root = root
        self.defaults = defaults
        self.makeRemote = makeRemote
    }

    #if ARCHIVE_TESTING
    convenience init(testRoot: URL, localRemote: URL? = nil, branch: String = "main",
                     testDefaults: UserDefaults = .standard, verifyPrivate: @escaping () throws -> Void = {}) {
        self.init(root: testRoot, defaults: testDefaults) { _ in
            guard let localRemote else { return nil }
            let namespace = Self.digest("\(localRemote.absoluteString)\n\(branch)")
            return Remote(url: localRemote.absoluteString, branch: branch, receiptNamespace: namespace,
                          gitOptions: [], verifyPrivate: verifyPrivate)
        }
    }
    #endif

    private static func validRepository(_ value: String) -> Bool {
        value.range(of: #"\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?/[A-Za-z0-9._-]{1,100}\z"#,
                    options: .regularExpression) != nil && !value.hasSuffix("/.") && !value.hasSuffix("/..")
    }

    func setRepository(_ repository: String?) throws {
        let value = repository?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if value.isEmpty {
            defaults.removeObject(forKey: Self.repositoryKey)
        } else {
            guard Self.validRepository(value) else {
                throw ArchiveError(message: "请输入 GitHub 仓库的所有者和仓库名，格式如 owner/repository。")
            }
            defaults.set(value.lowercased(), forKey: Self.repositoryKey)
        }
    }

    static func remotePath(id: UUID, createdAt: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.dateComponents([.year, .month], from: createdAt)
        let year = String(format: "%04d", date.year ?? 0)
        let month = String(format: "%02d", date.month ?? 0)
        return "raw/astra-chat/\(year)/\(month)/\(id.uuidString.lowercased()).md"
    }

    func save(id: UUID, createdAt: Date, json: Data, markdown: String) throws {
        try prepareDirectories()
        let record = Record(id: id, createdAt: createdAt, json: json, markdown: markdown)
        try write(JSONEncoder().encode(record), to: recordURL(id, in: records))
    }

    func loadAll() throws -> [Data] {
        try readRecords().map(\.json)
    }

    func syncPending(completion: @escaping (Result<Int, Error>) -> Void = { _ in }) {
        queue.async {
            let result = Result { try self.uploadPending() }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func recordURL(_ id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased()).appendingPathExtension("json")
    }

    private func prepareDirectories() throws {
        for directory in [root, records, receipts] {
            try files.createDirectory(at: directory, withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func readRecords() throws -> [Record] {
        try prepareDirectories()
        return try files.contentsOfDirectory(at: records, includingPropertiesForKeys: nil,
                                             options: [.skipsHiddenFiles]).compactMap { path in
            guard path.pathExtension == "json",
                  let id = UUID(uuidString: path.deletingPathExtension().lastPathComponent) else { return nil }
            let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: path))
            guard record.id == id else {
                throw ArchiveError(message: "本地聊天记录的 ID 与文件名不一致。")
            }
            return record
        }
    }

    private static func digest(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func readPending(_ records: [Record], receipts: URL) throws -> [Pending] {
        try records.sorted { $0.createdAt < $1.createdAt }.compactMap { record in
            let digest = Self.digest(record.markdown)
            guard digest != (try loadReceipt(record.id, in: receipts)).uploadedDigest else { return nil }
            return Pending(record: record, digest: digest)
        }
    }

    private func loadReceipt(_ id: UUID, in directory: URL) throws -> Receipt {
        let url = recordURL(id, in: directory)
        guard files.fileExists(atPath: url.path) else { return Receipt() }
        return try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
    }

    private func saveReceipt(_ receipt: Receipt, for id: UUID, in directory: URL) throws {
        try write(JSONEncoder().encode(receipt), to: recordURL(id, in: directory))
    }

    private func uploadPending() throws -> Int {
        try prepareDirectories()
        let lockURL = root.appendingPathComponent("sync.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ArchiveError(message: "无法打开本地同步锁。") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw ArchiveError(message: "另一进程正在同步。稍后会重试。")
        }

        let selection = repository
        let records = try readRecords()
        guard !records.isEmpty, let remote = try makeRemote(selection) else { return 0 }
        let receipts = self.receipts.appendingPathComponent(remote.receiptNamespace, isDirectory: true)
        try files.createDirectory(at: receipts, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let pending = try readPending(records, receipts: receipts)
        guard !pending.isEmpty else { return 0 }
        var count = 0
        for start in stride(from: 0, to: pending.count, by: 24) {
            let batch = pending[start..<min(start + 24, pending.count)]
            for attempt in 0..<2 {
                do {
                    try upload(batch, to: remote, receipts: receipts, selection: selection)
                    count += batch.count
                    break
                } catch let error as RetryablePushError {
                    if attempt == 1 { throw error }
                }
            }
        }
        return count
    }

    private struct RetryablePushError: LocalizedError {
        var errorDescription: String? { "GitHub 上传尚未确认，聊天已留在本机，稍后可重试。" }
    }

    private func verifySelection(_ selected: String?) throws {
        guard repository == selected else {
            throw ArchiveError(message: "同步设置已变化，聊天已留在本机。")
        }
    }

    private func upload(_ batch: ArraySlice<Pending>, to remote: Remote, receipts: URL,
                        selection: String?) throws {
        try verifySelection(selection)
        try remote.verifyPrivate()
        let scratch = root.appendingPathComponent(".git-sync-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: scratch, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: scratch) }
        let repository = scratch.appendingPathComponent("archive.git", isDirectory: true)
        let failure = "无法准备 GitHub 同步，请检查网络和 GitHub CLI 登录。"
        let options = remote.gitOptions + ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"]
        _ = try Self.run("/usr/bin/git", options + [
            "clone", "--quiet", "--bare", "--depth", "1", "--filter=blob:none",
            "--single-branch", "--branch", remote.branch, "--no-tags", "--", remote.url, repository.path
        ], failure: failure)

        func git(_ args: [String], failure: String = "无法准备 GitHub 归档提交。") throws -> String {
            try Self.run("/usr/bin/git", ["--git-dir", repository.path] + options + args, failure: failure)
        }

        func existingBlob(_ path: String) throws -> String? {
            let entry = try git(["ls-tree", "HEAD", "--", path])
            guard !entry.isEmpty else { return nil }
            let fields = entry.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 4, fields[0] == "100644", fields[1] == "blob" else {
                throw ArchiveError(message: "GitHub 上已有不同类型的归档条目，聊天已留在本机。")
            }
            return String(fields[2])
        }

        let payload = scratch.appendingPathComponent("payload")
        func hash(_ text: String) throws -> String {
            try write(Data(text.utf8), to: payload)
            return try git(["hash-object", "-w", "--no-filters", "--", payload.path])
        }

        func stage(_ blob: String, at path: String) throws {
            _ = try git(["update-index", "--add", "--cacheinfo", "100644,\(blob),\(path)"])
        }

        let parent = try git(["rev-parse", "HEAD"])
        _ = try git(["read-tree", parent])
        var changed = false
        var verifiedReceipts: [(UUID, Receipt)] = []
        for item in batch {
            let record = item.record
            let path = record.path
            let previous = try existingBlob(path)
            let candidate = try hash(record.markdown)
            if previous != candidate {
                var receipt = try loadReceipt(record.id, in: receipts)
                guard previous == nil || previous == receipt.verifiedBlob || previous == receipt.attemptedBlob else {
                    throw ArchiveError(message: "GitHub 上的同一聊天已有未知版本，聊天已留在本机。")
                }
                receipt.verifiedBlob = previous
                receipt.attemptedBlob = candidate
                try saveReceipt(receipt, for: record.id, in: receipts)
                try stage(candidate, at: path)
                changed = true
            }
            verifiedReceipts.append((record.id, Receipt(uploadedDigest: item.digest, verifiedBlob: candidate)))
        }

        let indexPath = "raw/astra-chat/README.md"
        if try existingBlob(indexPath) == nil {
            let index = """
            # Astra 对话原始记录

            本目录由 Astra 对话应用同步。各对话按 UTC 创建月份存放，文件名为对话 ID。
            每份记录保存对话原文、来源和现有消息时间。图片原件保存在本机，索引见对应对话。

            """
            try stage(hash(index), at: indexPath)
            changed = true
        }
        if changed {
            let tree = try git(["write-tree", "--missing-ok"])
            let commit = try git([
                "-c", "user.name=Astra Chat", "-c", "user.email=astra-chat@users.noreply.github.com",
                "commit-tree", tree, "-p", parent, "-m", "Archive Astra conversations"
            ])
            try remote.verifyPrivate()
            try verifySelection(selection)
            let ref = "refs/heads/" + remote.branch
            do {
                _ = try git(["push", "--quiet", "--no-verify", "--no-tags", "origin", "\(commit):\(ref)"])
                let remoteHead = try git(["ls-remote", "--exit-code", "origin", ref])
                guard remoteHead == "\(commit)\t\(ref)" else { throw RetryablePushError() }
            } catch {
                throw RetryablePushError()
            }
        }
        for (id, receipt) in verifiedReceipts { try saveReceipt(receipt, for: id, in: receipts) }
    }

    private static func run(_ executable: String, _ arguments: [String], failure: String) throws -> String {
        let process = Process()
        let output = Pipe()
        let finished = DispatchSemaphore(value: 0)
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "TMPDIR": NSTemporaryDirectory(),
            "LANG": "en_US.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
            "GH_PROMPT_DISABLED": "1",
            "GH_NO_UPDATE_NOTIFIER": "1",
            "GH_NO_EXTENSION_UPDATE_NOTIFIER": "1"
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            throw ArchiveError(message: failure)
        }
        guard process.terminationStatus == 0 else { throw ArchiveError(message: failure) }
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
