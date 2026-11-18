import Foundation

@main
enum Launch {
    @MainActor static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch (arguments.count, arguments.first ?? "") {
            case (1, "--import-key"):
                let value = FileHandle.standardInput.readData(ofLength: 1024)
                guard value.count < 1024, let key = String(data: value, encoding: .utf8) else {
                    throw ChatError(message: "不能读取密钥。")
                }
                try APIKeyStore.save(key)
                print("API key saved in macOS Keychain.")
            case (1, "--check-models"):
                let ids = try await AstraClient().availableModelIDs()
                let candidates = TextModel.allCases.map(\.rawValue) + ImageModel.allCases.map(\.rawValue)
                print(candidates.filter(ids.contains).joined(separator: "\n"))
            case (1, "--self-test"):
                let client = AstraClient()
                let nonce = "CODE-" + String(UUID().uuidString.prefix(8))
                let first = Message(role: "user", content: "Remember the code \(nonce). Reply with exactly OK.")
                let ready = try await client.send([first])
                guard ready.text == "OK" else { throw ChatError(message: "第一轮测试回复不符。") }
                let reply = try await client.send([first, Message(role: "assistant", content: ready.text),
                    Message(role: "user", content: "What was the code? Output the exact code only.")], model: .sol)
                guard reply.text == nonce else { throw ChatError(message: "切换模型后的追问未通过。") }
                print("PASS: \(ready.model) → \(reply.model), conversation context retained.")
            case (2, "--self-test-image"):
                guard let model = ImageModel(rawValue: arguments[1]) else { throw ChatError(message: "未知图片模型。") }
                let data = try await AstraClient().generateImage(
                    "A single yellow circle on a navy background, flat vector style, no text.",
                    model: model, quality: "low")
                let result = try ChatImage.save(data, size: "1024x1024", quality: "low")
                print("PASS: \(model.rawValue), \(result.bytes) PNG bytes.")
            case (2, "--set-archive"):
                try ChatArchive.shared.setRepository(arguments[1])
                print("Archive destination saved.")
            case (1, "--self-test-archive"):
                guard ChatArchive.shared.repository != nil else {
                    throw ChatError(message: "没有配置私有归档仓库。")
                }
                var sample = Conversation()
                sample.messages = [
                    ChatEntry(role: "user", text: "Astra Chat 自动归档验证：此条是合成测试记录。", model: TextModel.astra.rawValue),
                    ChatEntry(role: "assistant", text: "Local save and private GitHub delivery check.", model: TextModel.astra.rawValue)
                ]
                try ChatArchive.shared.save(id: sample.id, createdAt: sample.createdAt,
                    json: JSONEncoder().encode(sample), markdown: sample.markdown)
                let records = try ChatArchive.shared.loadAll()
                guard records.contains(where: { (try? JSONDecoder().decode(Conversation.self, from: $0))?.id == sample.id }) else {
                    throw ChatError(message: "本机记录回读失败。")
                }
                let outcome = await withCheckedContinuation { continuation in
                    ChatArchive.shared.syncPending { continuation.resume(returning: $0) }
                }
                let count = try outcome.get()
                guard count > 0 else { throw ChatError(message: "没有确认上传新记录。") }
                print("PASS: " + ChatArchive.remotePath(id: sample.id, createdAt: sample.createdAt))
            default:
                AstraChatApp.main()
            }
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
