import AppKit
import CryptoKit
import Foundation
import SwiftUI

struct ChatImage: Codable {
    let filename: String
    let bytes: Int
    let sha256: String
    let size: String
    let quality: String

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.astrachat.desktop", isDirectory: true)
            .appendingPathComponent("Images", isDirectory: true)
    }

    var url: URL? {
        guard filename.hasSuffix(".png"), UUID(uuidString: String(filename.dropLast(4))) != nil else { return nil }
        return Self.directory.appendingPathComponent(filename)
    }

    static func save(_ bytes: Data, size: String, quality: String) throws -> Self {
        guard let source = NSImage(data: bytes), source.isValid else {
            throw ChatError(message: "OpenAI 返回的图片无法打开。")
        }
        let image = Self(filename: UUID().uuidString.lowercased() + ".png", bytes: bytes.count,
                         sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                         size: size, quality: quality)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard let location = image.url else { throw ChatError(message: "无法确定图片保存位置。") }
        try bytes.write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
        return image
    }
}

struct ChatEntry: Identifiable, Codable {
    var id = UUID()
    var date = Date()
    let role: String
    let text: String
    let model: String
    var image: ChatImage? = nil
    var imagePrompt = false
}

struct Conversation: Identifiable, Codable {
    var id = UUID()
    var createdAt = Date()
    var messages: [ChatEntry] = []
    var changedAt: Date { messages.last?.date ?? createdAt }
    var title: String {
        let first = messages.first(where: { $0.role == "user" })?.text ?? "新对话"
        let collapsed = first.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count > 48 ? String(collapsed.prefix(48)) + "…" : collapsed
    }

    var markdown: String {
        let formatter = ISO8601DateFormatter()
        var result = "# Astra Chat 对话原文\n\n- 对话 ID：`\(id.uuidString.lowercased())`\n- 创建：\(formatter.string(from: createdAt))\n"
        for message in messages {
            let role = message.role == "user" ? "用户" : "助手"
            result += "\n## \(role) · \(formatter.string(from: message.date)) · `\(message.model)`\n\n"
            if message.imagePrompt { result += "图片生成提示词\n\n" }
            if let image = message.image {
                result += "- 本机 PNG：`Images/\(image.filename)`\n- 尺寸：\(image.size)；画质：\(image.quality)；大小：\(image.bytes) 字节\n- SHA-256：`\(image.sha256)`\n"
            } else {
                let longest = message.text.split(whereSeparator: { $0 != "~" }).map(\.count).max() ?? 0
                let fence = String(repeating: "~", count: max(3, longest + 1))
                result += "\(fence)text\n\(message.text)\n\(fence)\n"
            }
        }
        return result
    }
}

@MainActor
final class ChatState: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case chat = "对话"
        case image = "生图"
        var id: Self { self }
    }

    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var prompt = ""
    @Published var mode: Mode = .chat
    @Published var textModel: TextModel = .astra
    @Published var imageModel: ImageModel = .flare
    @Published var size = "1024x1024"
    @Published var quality = "medium"
    @Published var modelIDs: Set<String>?
    @Published var busy = false
    @Published var syncBusy = false
    @Published var errorMessage: String?
    @Published var syncStatus = "仅保存到本机"
    @Published var configuredRepo: String?
    private let client = AstraClient()
    private let archive = ChatArchive.shared
    private var unsaved: Set<UUID> = []
    private var syncAgain = false
    private var retry: Task<Void, Never>?
    private var started = false

    var current: Conversation? { conversations.first { $0.id == currentID } }
    var sortedChats: [Conversation] { conversations.filter { !$0.messages.isEmpty }.sorted { $0.changedAt > $1.changedAt } }
    var hasUnsaved: Bool { !unsaved.isEmpty }

    func start() {
        guard !started else { return }
        started = true
        configuredRepo = archive.repository
        do {
            let decoder = JSONDecoder()
            let stored = try archive.loadAll()
            conversations = stored.compactMap { try? decoder.decode(Conversation.self, from: $0) }
            if stored.count != conversations.count { errorMessage = "有历史记录无法读取，原文件仍保存在本机。" }
            currentID = sortedChats.first?.id
        } catch {
            errorMessage = "无法读取本地聊天记录。"
        }
        if configuredRepo != nil { sync() }
        Task { _ = try? await refreshModels() }
    }

    func select(_ id: UUID?) {
        guard !busy else { return }
        currentID = id
        prompt = ""
        errorMessage = nil
    }

    func refreshModels() async throws -> Int {
        let ids = try await client.availableModelIDs()
        modelIDs = ids
        if !ids.contains(textModel.rawValue),
           let model = TextModel.allCases.first(where: { ids.contains($0.rawValue) }) { textModel = model }
        if !ids.contains(imageModel.rawValue),
           let model = ImageModel.allCases.first(where: { ids.contains($0.rawValue) }) { imageModel = model }
        return TextModel.allCases.filter { ids.contains($0.rawValue) }.count
             + ImageModel.allCases.filter { ids.contains($0.rawValue) }.count
    }

    func setRepository(_ value: String) throws {
        try archive.setRepository(value)
        configuredRepo = archive.repository
        if configuredRepo == nil {
            retry?.cancel()
            syncStatus = "仅保存到本机"
        } else {
            sync()
        }
    }

    @discardableResult private func persist(_ chat: Conversation) -> Bool {
        do {
            try archive.save(id: chat.id, createdAt: chat.createdAt,
                             json: JSONEncoder().encode(chat), markdown: chat.markdown)
            unsaved.remove(chat.id)
            return true
        } catch {
            unsaved.insert(chat.id)
            errorMessage = "本机保存失败。请检查磁盘空间和权限，然后点「重试保存」。"
            return false
        }
    }

    func retrySave() {
        errorMessage = nil
        for chat in conversations where unsaved.contains(chat.id) { _ = persist(chat) }
        sync()
    }

    func sync() {
        guard configuredRepo != nil else { syncStatus = "仅保存到本机"; return }
        retry?.cancel()
        if syncBusy { syncAgain = true; return }
        syncBusy = true
        syncStatus = "正在同步 GitHub…"
        let target = configuredRepo
        archive.syncPending { [weak self] result in
            guard let self else { return }
            self.syncBusy = false
            if self.configuredRepo == nil {
                self.syncStatus = "仅保存到本机"
            } else if self.configuredRepo == target {
                switch result {
                case .success(let count):
                    self.syncStatus = count == 0 ? "GitHub 已是最新" : "已验证同步 · \(count) 个对话"
                case .failure(let error):
                    self.syncStatus = error.localizedDescription
                    self.retry = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 120_000_000_000)
                        guard !Task.isCancelled else { return }
                        self?.sync()
                    }
                }
            }
            if self.syncAgain {
                self.syncAgain = false
                self.sync()
            }
        }
    }

    func send() {
        let text = prompt
        guard !busy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let sendMode = mode, chatModel = textModel, pictureModel = imageModel, dimensions = size, detail = quality
        let model = sendMode == .chat ? chatModel.rawValue : pictureModel.rawValue
        var chat = current ?? Conversation()
        chat.messages.append(ChatEntry(role: "user", text: text, model: model, imagePrompt: sendMode == .image))
        errorMessage = nil
        guard persist(chat) else { unsaved.remove(chat.id); return }
        put(chat)
        prompt = ""
        busy = true
        sync()
        Task {
            defer { busy = false }
            do {
                if sendMode == .image {
                    let bytes = try await client.generateImage(text, model: pictureModel, size: dimensions, quality: detail)
                    let image = try ChatImage.save(bytes, size: dimensions, quality: detail)
                    chat.messages.append(ChatEntry(role: "assistant", text: "", model: model, image: image))
                } else {
                    let messages = chat.messages.filter { !$0.imagePrompt && $0.image == nil }
                        .map { Message(role: $0.role, content: $0.text) }
                    let reply = try await client.send(messages, model: chatModel)
                    chat.messages.append(ChatEntry(role: "assistant", text: reply.text, model: reply.model))
                }
                put(chat)
                if persist(chat) { sync() }
            } catch {
                errorMessage = error.localizedDescription
                if prompt.isEmpty { prompt = text }
            }
        }
    }

    private func put(_ chat: Conversation) {
        if let index = conversations.firstIndex(where: { $0.id == chat.id }) { conversations[index] = chat }
        else { conversations.append(chat) }
        currentID = chat.id
    }
}
