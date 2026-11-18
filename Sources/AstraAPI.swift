import Foundation
import Security

struct Message: Encodable, Sendable {
    let role: String
    let content: String
}

enum TextModel: String, CaseIterable, Sendable {
    case astra = "gpt-6.2-astra"
    case sol = "gpt-6.2-sol"
    case terra = "gpt-6.1-terra"
    case luna = "gpt-6-luna"

    var title: String {
        switch self {
        case .astra: "GPT-6.2 Astra"
        case .sol: "GPT-6.2 Sol"
        case .terra: "GPT-6.1 Terra"
        case .luna: "GPT-6 Luna"
        }
    }
}

enum ImageModel: String, CaseIterable, Sendable {
    case flare = "gpt-image-2.6-flare"
    case sunburst = "gpt-image-2.6-sunburst"
    case flare25 = "gpt-image-2.5-flare"
    case sunburst25 = "gpt-image-2.5-sunburst"
    case image2 = "gpt-image-2"

    var title: String {
        switch self {
        case .flare: "GPT-Image-2.6 Flare"
        case .sunburst: "GPT-Image-2.6 Sunburst"
        case .flare25: "GPT-Image-2.5 Flare"
        case .sunburst25: "GPT-Image-2.5 Sunburst"
        case .image2: "GPT-Image-2"
        }
    }
}

struct ChatError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum APIKeyStore {
    private static var item: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "org.astrachat.credentials.openai",
            kSecAttrAccount as String: "OpenAI API Key"
        ]
    }

    static func validatedKey(_ rawKey: String) throws -> String {
        let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.utf8.count <= 1024,
              key.range(of: #"^sk-[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else {
            throw ChatError(message: "请输入有效的 OpenAI API 密钥。")
        }
        return key
    }

    static func load() throws -> String? {
        var query = item
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status, action: "读取")
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw ChatError(message: "钥匙串里的 OpenAI API 密钥无法读取，请重新设置。")
        }
        return try validatedKey(key)
    }

    static func save(_ rawKey: String) throws {
        let key = try validatedKey(rawKey)
        let data = Data(key.utf8)
        var attributes = item
        attributes[kSecAttrLabel as String] = "Astra Chat – OpenAI API Key"
        attributes[kSecValueData as String] = data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let updatedValue = [kSecValueData as String: data]
            try check(SecItemUpdate(item as CFDictionary, updatedValue as CFDictionary), action: "更新")
        } else {
            try check(status, action: "保存")
        }
    }

    static func remove() throws {
        let status = SecItemDelete(item as CFDictionary)
        if status != errSecItemNotFound { try check(status, action: "删除") }
    }

    private static func check(_ status: OSStatus, action: String) throws {
        guard status == errSecSuccess else {
            throw ChatError(message: "无法从钥匙串\(action) OpenAI API 密钥（\(status)）。")
        }
    }
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class AstraClient: Sendable {
    private struct TextRequest: Encodable {
        let model: String
        let store = false
        let max_output_tokens = 8192
        let input: [Message]
    }

    private struct TextReply: Decodable {
        struct Item: Decodable {
            struct Part: Decodable {
                let type: String
                let text: String?
                let refusal: String?
            }
            let type: String
            let content: [Part]?
        }
        let model: String
        let status: String
        let output: [Item]
    }

    private struct ImageRequest: Encodable {
        let model: String
        let prompt: String
        let size: String
        let quality: String
        let n = 1
        let output_format = "png"
    }

    private struct ImageReply: Decodable {
        struct Item: Decodable {
            let b64_json: Data?
        }
        let data: [Item]
    }

    private struct ModelList: Decodable {
        struct Model: Decodable {
            let id: String
        }
        let data: [Model]
    }

    private struct APIError: Decodable {
        struct Details: Decodable {
            let code: String?
        }
        let error: Details
    }

    private enum Endpoint: String {
        case responses = "responses"
        case images = "images/generations"
        case models = "models"
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 240
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
    }()

    func send(_ messages: [Message], model: TextModel = .astra) async throws -> (text: String, model: String) {
        let payload = try JSONEncoder().encode(TextRequest(model: model.rawValue, input: messages))
        let data = try await request(.responses, timeout: 120, body: payload, modelTitle: model.title)
        guard let reply = try? JSONDecoder().decode(TextReply.self, from: data),
              reply.model == model.rawValue || reply.model.hasPrefix(model.rawValue + "-") else {
            throw ChatError(message: "无法识别 \(model.title) 的响应。")
        }
        guard reply.status == "completed" else {
            throw ChatError(message: "这一轮回复没有完成。可以缩短问题后重试。")
        }
        let parts = reply.output.filter { $0.type == "message" }.flatMap { $0.content ?? [] }
        let text = parts.filter { $0.type == "output_text" || $0.type == "refusal" }
            .compactMap { $0.text ?? $0.refusal }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw ChatError(message: "\(model.title) 这次没有返回可显示的文字。")
        }
        return (text, reply.model)
    }

    func generateImage(_ prompt: String, model: ImageModel = .flare, size: String = "1024x1024",
                       quality: String = "medium") async throws -> Data {
        guard ["1024x1024", "1536x1024", "1024x1536"].contains(size), ["low", "medium", "high"].contains(quality) else {
            throw ChatError(message: "请选择支持的图片尺寸和画质。")
        }
        let payload = try JSONEncoder().encode(ImageRequest(model: model.rawValue, prompt: prompt, size: size, quality: quality))
        let data = try await request(.images, timeout: 210, body: payload, modelTitle: model.title)
        let pngSignature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]
        guard let reply = try? JSONDecoder().decode(ImageReply.self, from: data),
              let image = reply.data.first?.b64_json, image.starts(with: pngSignature) else {
            throw ChatError(message: "OpenAI 没有返回有效的 PNG 图片。")
        }
        return image
    }

    func availableModelIDs() async throws -> Set<String> {
        let data = try await request(.models, timeout: 20)
        guard let reply = try? JSONDecoder().decode(ModelList.self, from: data) else {
            throw ChatError(message: "无法读取 OpenAI 返回的模型列表。")
        }
        return Set(reply.data.map(\.id))
    }

    private func request(_ endpoint: Endpoint, timeout: TimeInterval, body: Data? = nil,
                         modelTitle: String? = nil) async throws -> Data {
        guard let key = try APIKeyStore.load() else {
            throw ChatError(message: "请在设置中添加 OpenAI API 密钥。")
        }
        let url = URL(string: "https://api.openai.com/v1/" + endpoint.rawValue)!
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ChatError(message: "连不上 OpenAI API，或请求超时。请检查网络后重试。")
        }
        guard let http = response as? HTTPURLResponse else {
            throw ChatError(message: "没有收到有效的 API 响应。")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw responseError(status: http.statusCode, data: data, modelTitle: modelTitle)
        }
        return data
    }

    private func responseError(status: Int, data: Data, modelTitle: String?) -> ChatError {
        let code = try? JSONDecoder().decode(APIError.self, from: data).error.code
        let hint: String
        switch (status, code) {
        case (_, "moderation_blocked"), (_, "content_policy_violation"):
            hint = "这条提示词触发了 OpenAI 的内容限制，请修改后重试。"
        case (401, _):
            hint = "本机密钥无法通过认证。"
        case (403, _), (404, _):
            hint = modelTitle.map { "请检查 API 项目能否使用 \($0)。" } ?? "请检查 API 密钥是否有读取模型列表的权限。"
        case (429, "insufficient_quota"):
            hint = "API 项目额度不足，请检查计费设置。"
        case (429, _):
            hint = "API 请求达到用量限制，请稍后再试。"
        case (500...599, _):
            hint = "OpenAI 服务暂时不可用，请稍后再试。"
        default:
            hint = "请求未完成，可以修改输入后重试。"
        }
        return ChatError(message: "API 返回 HTTP \(status)。" + hint)
    }
}
