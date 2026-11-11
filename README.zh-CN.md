<div align="center">

<img src="docs/images/icon.png" width="112" alt="BetterTeX 图标">

# BetterTeX

**原生的 macOS LaTeX 工作区。**<br>
在一个窗口里写作、编译和预览，内置 Overleaf 同步和你的编程 Agent。

[![Release](https://img.shields.io/badge/release-v0.1.0--alpha.2-0A84FF?style=flat-square)](https://github.com/tangshunpu/BetterTeX/releases)
[![Platform](https://img.shields.io/badge/macOS-13%2B-1C1C1E?style=flat-square&logo=apple&logoColor=white)](#安装)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-8E8E93?style=flat-square)](#安装)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-30D158?style=flat-square)](LICENSE)

[**下载**](https://github.com/tangshunpu/BetterTeX/releases) · [English](README.md) · [使用说明](docs/guide.zh-CN.md)

<img src="docs/images/workspace.png" alt="BetterTeX 工作区：边栏、LaTeX 编辑器、PDF 预览和 Agent 面板">

</div>

## 功能

| | |
| --- | --- |
| ✍️ **编辑器** | 语法着色、文档大纲，命令、文献、标签和路径的自动补全 |
| ⚡ **实时预览** | latexmk、pdfLaTeX、XeLaTeX、LuaLaTeX 自动编译，SyncTeX 双向定位 |
| 🗂️ **项目主页** | 本机和 Overleaf 项目在同一张可搜索的列表里，点一下就打开 |
| 🍃 **Overleaf 同步** | 实时或定时同步，协作者光标与评论 |
| 🤖 **Agent** | Codex 和 Claude Code 的原生对话界面，带 diff 和会话历史 |
| 🔀 **Git** | 不离开窗口就能拉取、提交和推送 |
| 🖼️ **快速插入** | 拖入或粘贴图片，自动生成 `figure` 环境 |
| 🪶 **原生** | Swift + AppKit + PDFKit，没有 Electron |

## 安装

1. 在 [Releases](https://github.com/tangshunpu/BetterTeX/releases) 下载 `.dmg`，把 **BetterTeX** 拖到「应用程序」。
2. 第一次打开：右键应用选「打开」。alpha 版还没有经过 Apple 公证。

还需要本机装有 TeX 发行版，例如 [MacTeX](https://www.tug.org/mactex/) 或 [TinyTeX](https://yihui.org/tinytex/)。Agent 面板是可选的，使用你 Mac 上已登录的 [Codex CLI](https://github.com/openai/codex) 和 [Claude Code](https://claude.com/claude-code)。

## 从源码构建

```sh
git clone https://github.com/tangshunpu/BetterTeX.git && cd BetterTeX
./script/build_and_run.sh    # 构建并启动（Swift 6 / Xcode 16+）
./script/test.sh             # 运行测试
```

## 须知

- **Alpha 版。** 还有不少粗糙的地方。
- **账号始终是你的。** Agent 通过你自己的命令行运行，Overleaf 只保留会话 cookie，BetterTeX 不接触密码或 API key。
- **Overleaf 没有公开 API。** 同步使用的是 Overleaf 网页编辑器自己的接口，Overleaf 改版后可能需要跟进。

每项功能的详细说明见 [使用说明](docs/guide.zh-CN.md)。

## 参与贡献

欢迎提 issue 和 pull request，请以 `dev` 分支为目标。

## 许可证

[MIT](LICENSE) © Shunpu Tang。第三方声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

<sub>BetterTeX 是独立项目，与 Overleaf、OpenAI、Anthropic 没有关联。</sub>
