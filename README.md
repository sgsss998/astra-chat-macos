# Astra Chat for macOS

Astra Chat 是一个原生 macOS 客户端，把 OpenAI API 的文字对话、图片生成和聊天归档放在同一个窗口。它独立使用你的 OpenAI API 项目，无需登录 Codex，适合需要随时切换模型、保留对话原文，又希望自己控制归档去向的人。

## 适合哪些工作

- **一个窗口切换模型。** 文字对话支持 Astra、Sol、Terra 和 Luna；生图支持 GPT Image 2.6 Flare、Sunburst 及较早版本，可选横图、竖图或方图，并调整画质。
- **关掉应用也能接着聊。** 应用在本机保留已发送的消息、模型回复和生成的 PNG。重开后在侧栏选回原对话，也可中途切换文字模型继续追问。
- **给聊天留一份可读的备份。** 绑定自己的私有仓库后，应用自动把原文按会话写成 Markdown，带上时间、模型和图片索引。上传失败时本机记录仍可用，应用运行期间会重试，下次打开也会继续。

## 构建和打开

需要 macOS 13 或更新版本、Xcode 15 或更新版本的 Command Line Tools，以及有相应模型权限的 OpenAI API 项目。构建脚本按当前终端的架构编译，原生终端下会为 Apple 芯片构建 `arm64`，为 Intel 芯片构建 `x86_64`。构建产物使用本机签名。

1. 如果 Mac 尚未安装 Xcode Command Line Tools，在终端运行 `xcode-select --install`，等待安装完成。
2. 下载或克隆源码，在终端进入 `astra-chat-macos` 项目目录。
3. 构建并打开应用。

   ```sh
   bash build.sh
   open 'dist/Astra Chat.app'
   ```

4. 打开应用的设置，输入并保存 OpenAI API 密钥。应用将密钥保存在 macOS 钥匙串中。
5. 选择文字模型并发送一条消息。要生成图片，切换到图片模式，选择图片模型并输入描述。API 可用模型取决于你的 OpenAI 项目权限，调用费用记在该项目下。

发送时，应用会把生成回复所需的内容提交给 OpenAI API。会话保存在当前用户的 `~/Library/Application Support/` 下，生成的 PNG 保存在本机。

## 开启 GitHub 私有归档（可选）

1. 在 GitHub 创建可写的 **Private** 仓库。创建时添加 README，以便仓库已有默认分支。
2. 通过 Homebrew 安装 GitHub CLI，并登录有该仓库写入权限的 GitHub 账号。

   ```sh
   brew install gh
   gh auth login --hostname github.com --git-protocol https --web
   gh auth status --hostname github.com
   ```

3. 在应用设置里填入私有仓库名，格式为 `owner/repository`，点击「启用自动同步」并确认。应用会同步本机待归档的会话，包括开启前保存的记录。
4. 在该私有仓库的默认分支下查看 `raw/astra-chat/`。会话记录按年、月存为 Markdown，PNG 原件保存在本机。

应用会通过 GitHub 核验仓库身份和私有状态，不会把会话推到公开仓库。同步失败时，可检查登录状态、私有仓库名和账号的写入权限。本机仍可查看会话。在设置里点击「停止同步」即可停用后续上传。

## 数据存放

- OpenAI 密钥保存在 macOS 钥匙串，不随聊天归档上传。
- 本地数据位于 `~/Library/Application Support/app.astrachat.desktop/`；`Conversations/` 是可恢复的会话，`Images/` 是 PNG 原件。
- GitHub 只收取话题原文及图片索引；如果需要异地备份 PNG，请另外备份本机的 `Images/`。绑定的归档仓库与这个公开源码仓库是两回事。

## 排查常见问题

- **构建时找不到 Swift 或 macOS SDK。** 确认已经安装并选用 Xcode 或 Command Line Tools，然后重新运行 `bash build.sh`。
- **某个模型无法调用。** 查看应用返回的提示，检查密钥所属项目的模型权限和 API 额度。
- **应用找不到 GitHub CLI。** 确认 `gh` 安装在 `/opt/homebrew/bin/gh` 或 `/usr/local/bin/gh`，再运行 `gh auth status --hostname github.com` 检查登录状态。

## 许可

源码采用 [MIT 许可证](LICENSE)。
