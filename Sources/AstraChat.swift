import AppKit
import SwiftUI

struct AstraChatApp: App {
    @StateObject private var state = ChatState()

    var body: some Scene {
        WindowGroup {
            ChatView(state: state)
                .frame(minWidth: 760, minHeight: 525)
                .onAppear { state.start() }
        }
        .defaultSize(width: 1050, height: 730)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新对话") { state.select(nil) }.keyboardShortcut("n")
            }
        }
        Settings { Preferences(state: state) }
    }
}

private let accent = Color(red: 0.32, green: 0.48, blue: 0.96)

struct ChatView: View {
    @ObservedObject var state: ChatState
    @State private var showSettings = false
    @FocusState private var composing: Bool

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let chat = state.current, !chat.messages.isEmpty {
                    conversation(chat)
                } else {
                    welcome
                }
                composer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .sheet(isPresented: $showSettings) { Preferences(state: state) }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 37, height: 37)
                    .background(RoundedRectangle(cornerRadius: 11).fill(
                        LinearGradient(colors: [accent, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                    ))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Astra Chat").font(.headline)
                    Text("OpenAI API").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(.top, 4)
            Button {
                state.select(nil)
                composing = true
            } label: {
                Label("新对话", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading).padding(9)
                    .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
            }
            .buttonStyle(.plain).foregroundStyle(accent).disabled(state.busy)
            Text("聊天记录")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(state.sortedChats) { chat in
                        Button {
                            state.select(chat.id)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(chat.title).font(.callout.weight(.medium)).lineLimit(1)
                                Text(chat.changedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(state.currentID == chat.id ? accent.opacity(0.16) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(state.busy)
                    }
                }
            }
            Divider()
            HStack {
                Button("设置", systemImage: "gearshape") { showSettings = true }
                Spacer()
                Button { state.sync() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    .help("立即同步 GitHub").accessibilityLabel("立即同步 GitHub")
                    .disabled(state.syncBusy || state.configuredRepo == nil)
            }.buttonStyle(.borderless)
            Text(state.syncStatus)
                .font(.caption2).foregroundStyle(.secondary)
                .lineLimit(2).help(state.syncStatus)
        }
        .padding(15)
        .frame(width: 222)
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var toolbar: some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text(state.current?.title ?? "新对话").font(.headline).lineLimit(1)
                Text(state.mode == .chat ? "文本对话" : "图片工作台")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Picker("模式", selection: $state.mode) {
                ForEach(ChatState.Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.labelsHidden().pickerStyle(.segmented).fixedSize()
            if state.mode == .chat {
                Picker("对话模型", selection: $state.textModel) {
                    ForEach(TextModel.allCases, id: \.self) { model in
                        Text(modelName(model.title, id: model.rawValue)).tag(model)
                    }
                }.labelsHidden().fixedSize()
            } else {
                Picker("图片模型", selection: $state.imageModel) {
                    ForEach(ImageModel.allCases, id: \.self) { model in
                        Text(modelName(model.title, id: model.rawValue)).tag(model)
                    }
                }.labelsHidden().fixedSize()
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .disabled(state.busy)
    }

    private func modelName(_ name: String, id: String) -> String {
        state.modelIDs?.contains(id) == false ? name + "（未列出）" : name
    }

    private var welcome: some View {
        VStack(spacing: 13) {
            Spacer()
            Image(systemName: state.mode == .chat ? "sparkle" : "photo.on.rectangle.angled")
                .font(.system(size: 33, weight: .light)).foregroundStyle(accent)
                .frame(width: 70, height: 70)
                .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
            Text(state.mode == .chat ? "今天想聊点什么？" : "把想法变成一张图")
                .font(.system(size: 26, weight: .semibold))
            Text(state.mode == .chat ? "发一条消息开始。聊天记录会自动保存。" : "描述画面、风格和构图，选择比例后点击生成。")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func conversation(_ chat: Conversation) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 17) {
                    ForEach(chat.messages) { entry in bubble(entry) }
                    if state.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在处理…").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: 820)
                .padding(.horizontal, 23).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.id) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { _ in proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    private func bubble(_ entry: ChatEntry) -> some View {
        let fromUser = entry.role == "user"
        return HStack(alignment: .top, spacing: 10) {
            if fromUser { Spacer(minLength: 45) }
            else {
                Image(systemName: entry.image == nil ? "sparkle" : "photo")
                    .foregroundStyle(accent)
                    .frame(width: 32, height: 32)
                    .background(accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(fromUser ? "你" : cardName(entry.model)).font(.caption.weight(.semibold))
                    if entry.imagePrompt {
                        Text("生图提示词").font(.caption2).foregroundStyle(.secondary)
                    }
                    Text(entry.date, format: .dateTime.hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let image = entry.image {
                    if let location = image.url, let asset = NSImage(contentsOf: location) {
                        Image(nsImage: asset).resizable().scaledToFit()
                            .frame(maxWidth: 448, maxHeight: 450)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("生成的图片")
                        Button("保存图片副本", systemImage: "square.and.arrow.down") { exportImage(location) }
                            .buttonStyle(.borderless)
                    } else {
                        Label("图片原件在本机找不到", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(entry.text).textSelection(.enabled)
                        .font(.system(size: 14)).lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(13)
            .background(fromUser ? accent.opacity(0.13) : Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 13))
            if !fromUser { Spacer(minLength: 30) }
        }
    }

    private func cardName(_ model: String) -> String {
        TextModel.allCases.first(where: { model == $0.rawValue || model.hasPrefix($0.rawValue + "-") })?.title
        ?? ImageModel.allCases.first(where: { model == $0.rawValue })?.title ?? model
    }

    private func exportImage(_ source: URL) {
        let dialog = NSSavePanel()
        dialog.nameFieldStringValue = "Astra 图像.png"
        guard dialog.runModal() == .OK, let destination = dialog.url else { return }
        do { try Data(contentsOf: source).write(to: destination, options: .atomic) }
        catch { state.errorMessage = "无法保存图片副本。" }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = state.errorMessage {
                HStack {
                    Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        .font(.caption).textSelection(.enabled)
                    if state.hasUnsaved { Button("重试保存") { state.retrySave() } }
                }
            }
            ZStack(alignment: .topLeading) {
                if state.prompt.isEmpty {
                    Text(state.mode == .chat ? "给 Astra Chat 发消息…" : "描述你想生成的画面…")
                        .font(.body).foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 8)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $state.prompt)
                    .font(.body).scrollContentBackground(.hidden)
                    .frame(height: 80).focused($composing)
                    .accessibilityLabel("输入消息")
            }
            HStack(spacing: 10) {
                if state.mode == .image {
                    Picker("比例", selection: $state.size) {
                        Text("正方形").tag("1024x1024")
                        Text("横图").tag("1536x1024")
                        Text("竖图").tag("1024x1536")
                    }.fixedSize()
                    Picker("画质", selection: $state.quality) {
                        Text("快速").tag("low")
                        Text("标准").tag("medium")
                        Text("细节").tag("high")
                    }.fixedSize()
                } else {
                    Text("⌘↩ 发送").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    state.send()
                } label: {
                    Label(state.mode == .chat ? "发送" : "生成", systemImage: "arrow.up")
                        .padding(.horizontal, 8)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(state.busy || state.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .disabled(state.busy)
        }
        .padding(11)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.secondary.opacity(0.23)))
        .padding(.horizontal, 22).padding(.bottom, 18).padding(.top, 5)
    }
}

struct Preferences: View {
    @ObservedObject var state: ChatState
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var destination = ""
    @State private var feedback = ""
    @State private var connected = false
    @State private var checking = false
    @State private var confirmArchive = false
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("设置", systemImage: "slider.horizontal.3").font(.title2.weight(.semibold))
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    Text(connected ? "本机钥匙串中已有密钥" : "尚未添加密钥").font(.callout)
                    SecureField("输入新的 OpenAI API 密钥", text: $key)
                        .textFieldStyle(.roundedBorder)
                    HStack {
                        Button("保存密钥") {
                            do {
                                try APIKeyStore.save(key)
                                key = ""
                                connected = true
                                feedback = "密钥已保存到 macOS 钥匙串。"
                                verifyKey()
                            } catch { feedback = error.localizedDescription }
                        }.disabled(key.isEmpty || checking)
                        Button("测试连接") { verifyKey() }.disabled(!connected || checking)
                        Spacer()
                        Button("移除", role: .destructive) { confirmRemove = true }.disabled(!connected || checking)
                    }
                }.padding(6)
            } label: { Label("OpenAI", systemImage: "key") }
            GroupBox {
                VStack(alignment: .leading, spacing: 9) {
                    TextField("私有仓库：owner/repository", text: $destination).textFieldStyle(.roundedBorder)
                    Text("通过已登录的 GitHub CLI 同步到私有仓库的 raw/astra-chat。启用后会上传已有和新建对话；PNG 原件仅留在本机。")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("启用自动同步") { confirmArchive = true }
                            .disabled(destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("停止同步") {
                            do {
                                try state.setRepository("")
                                destination = ""
                                feedback = "已停用 GitHub 同步，本地记录保留。"
                            } catch { feedback = error.localizedDescription }
                        }.disabled(state.configuredRepo == nil)
                    }
                }.padding(6)
            } label: { Label("GitHub 归档", systemImage: "archivebox") }
            if !feedback.isEmpty { Text(feedback).font(.caption).textSelection(.enabled) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(23)
        .frame(width: 510)
        .onAppear {
            destination = state.configuredRepo ?? ""
            do { connected = try APIKeyStore.load() != nil }
            catch { feedback = error.localizedDescription }
        }
        .confirmationDialog("将聊天同步到此私有仓库？", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("授权并同步") {
                do {
                    try state.setRepository(destination)
                    feedback = "已启用。查看主窗口的同步状态，确认 GitHub 收到记录。"
                } catch { feedback = error.localizedDescription }
            }
        } message: {
            Text("将向 \(destination) 上传本机已有对话和以后新增的对话。")
        }
        .confirmationDialog("移除此应用保存的 API 密钥？", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("移除密钥", role: .destructive) {
                do {
                    try APIKeyStore.remove()
                    connected = false
                    state.modelIDs = nil
                    feedback = "此应用已移除密钥。"
                } catch { feedback = error.localizedDescription }
            }
        }
    }

    private func verifyKey() {
        checking = true
        feedback = "正在检查 OpenAI 连接…"
        Task {
            defer { checking = false }
            do { feedback = "连接成功。此项目列出了 \(try await state.refreshModels()) 个内置模型。" }
            catch { feedback = error.localizedDescription }
        }
    }
}
