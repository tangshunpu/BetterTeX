# BetterTeX 使用说明

[← 返回 README](../README.zh-CN.md)

本文是各项功能的详细说明。

一个原生、轻量的 macOS LaTeX 工作区。Swift + AppKit + PDFKit，终端使用 [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm)。没有 Electron 或常驻语言服务器；唯一的 WebView 是 Overleaf 登录窗口，登录后即关闭。界面跟随系统深浅色。

## 运行

发布版本请到 [Releases](https://github.com/tangshunpu/BetterTeX/releases) 下载 `.dmg`，打开后把应用拖到「Applications」（同时提供内容相同的 `.zip`）。自行构建的应用位于 `dist/BetterTeX.app`；推荐解压 `dist/BetterTeX.zip` 后拖到「应用程序」，或用 `./script/make_dmg.sh` 生成 `dist/BetterTeX.dmg`。本地开发构建采用 ad-hoc 签名，尚未经过 Apple 公证。当前构建架构取决于本机（开发验证为 Apple Silicon）。打包脚本会额外生成 ZIP，避免 iCloud / FileProvider 给源码目录中的应用附加 FinderInfo，影响严格签名校验。

```sh
./script/build_and_run.sh             # 构建并启动，Codex 的 Run 按钮也调用此脚本
./script/build_and_run.sh --verify    # 启动并检查进程
CONFIGURATION=release ./script/build_and_run.sh
./script/test.sh                     # 单元测试 + 真实 TeX / SyncTeX / 本地 Git 集成测试
```

开发需要 Swift 6 / Xcode 16 或更新版本。运行最低版本为 macOS 13；本次实测在 macOS 27.3。首次构建需要网络下载锁定的 Swift 包。为避免 Documents / iCloud 附加属性影响代码签名，构建缓存默认放在 `~/Library/Caches/BetterTeX/Build`；可通过 `BETTERTEX_BUILD_CACHE` 更改。

Swift 6.4 优化器在 PDFKit 高亮桥接函数上存在编译崩溃；`PDFPane.goTo` 单独关闭优化以避开，其余 Release 代码保持优化。构建与实测结果见 [验证记录](validation.md)。

## 工作区

- 默认从左到右为文件边栏（含当前文档大纲）、TeX 编辑器、PDF、Agent / Terminal。界面采用 iOS 风格：分组深色表面、半透明灰色填充、胶囊按钮、文件类型徽标和 iOS 分段控件，并提供对应的浅色外观。
- 自绘标题栏包含边栏开关、搜索（⌘K，搜索文件与当前文档章节）、引擎选择、编译、标注为 GitHub 的拉取 / 推送组（远端不是 GitHub 时显示 Git）、Agent 面板开关和布局菜单。「自动预览」开关在 PDF 标题栏。
- 编辑器上方的快速插入栏（也在「插入」菜单）提供图片、列表、编号、公式、表格、章节、粗体、斜体、引用和交叉引用；有选区时包裹选区，否则选中占位文字。图片可通过按钮（⇧⌘I）、拖入编辑器或粘贴（含截图）插入：项目外的文件会拷贝到 `figures/`，自动生成 figure 环境，并在主文档缺少时加入 `\usepackage{graphicx}`。在 `\item` 行末按回车自动续写下一条，在空 `\item` 上按回车结束列表。
- 拖动 PDF 或 Agent 的标题栏可停靠到左侧、右侧或底部；右键标题栏或标题栏「布局」菜单也提供停靠在左侧 / 右侧 / 底部。Agent 相对整个编辑区移动，PDF 相对源码移动。位置和分栏尺寸会记住，移动与收起面板保留终端会话。「布局 → 恢复默认布局」恢复 PDF 在中间、Agent 在右的排列。
- 自动补全：输入 `\` 加字母补全命令（含项目里用 `\newcommand` 等定义的宏，带参数的命令会补上花括号）；`\cite{` 列出 `.bib` 和 `\bibitem` 里的文献（可按作者、年份、标题筛选）；`\ref{` 等列出全项目的 `\label`；`\begin{` 补全环境并自动配上 `\end`；`\includegraphics{`、`\input{`、`\bibliography{`、`\usepackage{` 补全路径和宏包名。↑↓ 选择，↩ 或 ⇥ 确认，esc 关闭。
- UTF-8 文本、LaTeX 语法着色、行号、撤销、原生查找、自动缩进与中文输入法。为控制内存，单文件上限为 12 MB。
- 停止输入约 0.9 秒自动保存，再等待约 0.6 秒启动编译；取消「自动编译」后仍然自动保存。编译工作在后台执行，持续编辑时合并后续编译请求。自动编译只在源文件、主文档或引擎确实变化时才运行，保存、文件监控和 Overleaf 同步不会各触发一遍。编译时 PDF 标题栏下方显示进度条，状态标签显示当前步骤（如「第 2 步 · 整理参考文献」）；带参考文献的文档首次编译依次是排版、BibTeX / Biber、再排版两遍，属于同一次编译。0.3 秒内结束的编译不显示忙碌状态，PDF 内容未变时不重新载入。
- 外部修改通过 FSEvents 检测。干净缓冲区自动重载；未保存内容与磁盘冲突时提供明确选择，暂停自动保存与编译。
- **项目主页**：没有打开项目时显示，仿照 Overleaf 首页。一张可搜索的列表里是所有打开过的本机项目，以及登录后你在 Overleaf 上的全部项目，默认按修改时间从新到旧排序（本机项目取文件最后修改时间，Overleaf 项目取它在 Overleaf 上的最后修改时间，已关联的取两者中较新的），点列标题可改按名称、位置或修改时间排序并反转，选择会被记住；左侧可切换「全部 / 本机 / Overleaf」，并显示 Overleaf 登录状态。点一行就进入项目：本机项目直接打开；尚未下载的 Overleaf 项目会下载到 `~/BetterTeX/`（可用偏好 `projectsFolder` 更改）、建立同步关联后打开，已下载过的只显示为本机那一行并带叶子标记。搜索框里按回车打开第一条结果，右键可在访达中显示或从列表移除。「打开或新建」提供打开文件夹、从 GitHub 克隆和创建示例项目。
- 第一次启动直接进入项目主页；一个项目都没有时，页面中央会请你登录 Overleaf 或打开已有项目。之后启动会回到上次打开的项目。在项目里点标题栏的九宫格按钮、文件边栏标题行最右的按钮或「文件 → 所有项目」（⇧⌘P）回到主页：先保存文件，有终端会话在运行时会先确认。
- 「创建示例项目」会在 `~/Library/Application Support/BetterTeX/First Paper` 生成一个可编辑的示例。

## 编译与 PDF

自动读取登录 Shell 的 PATH，并补充 MacTeX、Homebrew、TinyTeX 和常见 CLI 路径。**本机需要已安装 TeX 发行版**；应用不捆绑或自动下载安装 TeX。

支持 Auto、latexmk、pdfLaTeX、XeLaTeX、LuaLaTeX。已安装 latexmk 时由它管理增量编译、多轮引用与参考文献；缺少 latexmk 时使用所选引擎，按需运行 BibTeX / Biber，再进行两轮编译。显式选择 latexmk 但没有安装时会提示缺失。

主文件依次通过 `% !TeX root`、当前文件的 `\documentclass`、项目中的 `main.tex` 或唯一主文件识别。多个主文件存在歧义时会提示。Auto 尊重 `% !TeX program`；检测到 ctex、xeCJK 或 fontspec 时选择 XeLaTeX，否则选择 pdfLaTeX。

```tex
% !TeX root = ../main.tex
% !TeX program = xelatex
```

编译产物写入主文件旁的 `.bettertex/`。成功的 PDF 与同步文件保存到 `.bettertex/preview/`，失败编译不会替换它们。建议把 `.bettertex/` 加入项目 `.gitignore`。自定义 latexmkrc 会由本机 latexmk 按自身规则读取；特殊编译链、minted 的 shell-escape、非 UTF-8 文档与自定义 jobname 暂无专门配置界面。

按住 Command 点击源码正文或 PDF 内容即可双向定位。源码也可以通过 **⇧⌘J** 定位到 PDF。映射来自最近一次成功编译，修改后应等待编译完成。PDF 支持连续阅读、缩放和用「预览」打开。Output 中双击 `文件.tex:行号:错误` 可打开对应行。

## Codex / Claude / Shell

Agent 面板的「Codex」标签就是与 Codex 的原生对话界面（Codex 不再另有终端标签）：消息时间线、每条命令一张卡片（可展开输出）、文件改动列表（点按打开）、计划清单，以及底部的输入框、模型、思考强度和权限模式（只读 / 可改项目 / 完全访问，对应 Codex 自己的沙盒模式）。每条消息通过 Codex 官方的非交互接口 `codex exec --json` 运行一轮，后续消息用 `codex exec resume` 接在同一会话上；使用的是本机 `codex` 命令行自己的登录，BetterTeX 不读取、不保存任何凭据，也不直接调用模型接口。历史按钮里的 Codex 会话可以在对话里接着聊（之前的消息不回显）。

「Claude」标签是同一套对话界面，背后运行的是你本机安装并登录的 Claude Code 命令行的非交互模式：每条消息执行一次 `claude -p --output-format stream-json`，后续消息用 `--resume` 接在同一会话上，界面参照 Claude Code 扩展：回复随生成实时出现（`--include-partial-messages`），每个工具是一条带状态圆点的时间线条目（工具名加参数，结果挂在下方），Edit / Write 显示红绿 diff 并可点文件名打开，Bash 输出、长 diff 和思考过程可展开，待办清单标出进行中和已完成，回复里的代码块单独成框；工作中显示已用时间。权限选择对应 Claude Code 的权限模式：只读 = `plan`，可改项目 = `acceptEdits`，完全访问 = `bypassPermissions`；非交互模式下没人能回答确认，所以需要确认的操作会被拒绝并在卡片上标红。BetterTeX 不读取、不保存 Claude 的凭据，也没有内置 claude.ai 登录或 Agent SDK。如果要把这个应用分发给别人，请先确认 Anthropic 关于第三方产品使用订阅登录的条款。需要完整的交互式 Claude Code 时，在 Shell 标签里运行 `claude`。

Agent 面板可用标题栏的 » 按钮或 ⌘J 折叠成一条窄条，窄条上的图标可直接展开到对应标签；Codex 与 Claude 的图标在运行时取自本机已安装的应用，未安装时显示通用符号。会话运行时下方的输入卡片只保留上下文一行，因为 CLI 自带输入行。

真正的本地 PTY 终端，支持交互输入、ANSI 色彩、窗口大小变化与 CLI 自己的权限流程。首次点击标签才启动进程，切换标签保留会话，停止按钮结束当前会话。滚动历史限制为 2,000 行，编译输出保留约 300,000 字符。收起面板不会终止会话，切换工作区或退出应用会结束会话。

需自行安装并登录 Codex CLI 或 Claude Code。应用直接使用现有配置，不提供 API 代理、不接管账户、不自动同意目录信任提示或 Agent 操作。未安装时可在「工作区 → 本机工具」查看状态，安装后点「重新检测」。

Agent 输入区参考 VS Code 的 Claude Code / Codex 插件：一张卡片里依次是上下文标签、可自动增高的多行输入框（↩ 发送，⇧↩ 换行），以及「+」、模型菜单、思考强度菜单和发送按钮。模型与强度直接从向上弹出的菜单里选，也可输入自定义模型 ID；有会话在运行时菜单里提供「用当前配置新建会话」。Codex 从本机 `models_cache.json` 读取可见模型和支持的强度；Claude 提供 CLI 的 `opus`、`sonnet`、`haiku` 别名。具体可用模型、额度和强度仍由当前 CLI 与账户决定。保留「CLI 默认」时不覆盖原有配置。

Agent 标题栏的时钟按钮列出当前项目最近的 Codex 与 Claude 会话（各 12 条，按时间倒序，标题取首条提示），选择后以 `codex resume <id>` 或 `claude --resume <id>` 恢复；已有会话在运行时会先确认。历史只读取 CLI 自己保存在 `~/.codex/sessions` 与 `~/.claude/projects` 下的日志开头，不写入也不上传。

上下文标签显示当前文件；在编辑器里选中源码后变为 `@文件:起-止行`，发送时附带所选源码，否则只用 `@路径` 提及文件。点按标签可切换是否附带。

设置保存于 BetterTeX 的偏好，不改写 CLI 配置文件。新会话通过 Codex 的 `--model` / `-c model_reasoning_effort`，或 Claude 的 `--model` / `--effort` 生效；运行中的会话可用 CLI 自带命令修改。「用当前配置新建会话」会先确认是否结束已有会话。「+」将当前文件与选区加入 Agent 输入，仍由用户在 CLI 中发送。底部输入框可直接把一句话发给当前 Agent：会话未启动时以该提示启动 CLI，已启动时粘贴并回车；发送时会用 `@路径` 提及当前文件。终端显示真实 CLI 内容，没有单独的云端聊天后端。

## Git

**Pull** 直接执行 `git pull --ff-only`。**Push** 在干净工作区执行 `git push`；有修改时先显示文件选择和提交说明，也可只推送已有提交。未跟踪文件默认不勾选，生成的 `.bettertex/` 不列入提交选择。

现有 Git 远端、上游分支和身份配置会复用。不会自动初始化你的论文仓库、添加远端或强制推送。需要登录、建立上游分支或解决冲突时，使用 Shell 标签。网络 Push 失败时本地提交可能已成功，可再次 Push；具体输出可在 Output 查看。

## Overleaf

标题栏的 **Overleaf** 按钮把本地文件夹与一个 Overleaf 项目关联起来。Overleaf 没有公开 API，这里使用的是其网页编辑器自己的接口，Overleaf 改版后可能需要跟进。

- **登录**：首次使用时弹出一个登录窗口（支持账号密码与 SSO），到达项目列表后自动关闭。BetterTeX 只保留会话 cookie，不接触密码；此后所有请求都由原生网络层发出，不再显示任何网页。「退出 Overleaf 登录」会清除这些 cookie。
- **新建项目**（文件 → 新建项目）：从本地文件夹、从 GitHub 克隆（`owner/repo` 或任意 Git 地址，使用本机凭据），或从 Overleaf 导入（下载整个项目到新文件夹并保持关联）。
- **上传到 Overleaf**：把当前文件夹作为新项目上传并关联。隐藏文件、`.bettertex/` 和编译产物（aux、log、synctex 等）不会上传。
- **同步方式**：实时、每 1 / 5 / 15 / 60 分钟，或仅手动（⇧⌘Y）。同步以上次一致的内容为基准做三方比较：只有一侧修改就直接传过去；两侧都改了文本文件则按行合并，无法自动合并时在本地文件写入 `<<<<<<< BetterTeX（本地）` / `>>>>>>> Overleaf` 标记，处理完之前不会上传该文件。二进制文件两侧都改时以本地为准。Overleaf 删除的文件移到废纸篓；本地删除的文件在从 Overleaf 删除前会询问。
- **实时模式**：当前标签页的文档通过 Overleaf 的实时通道逐字同步，协作者的修改直接出现在编辑器里（保留光标与撤销历史）；其他文件在检测到变化后数秒内整体同步，并每 3 分钟兜底检查一次。
- **协作者**：在线协作者的头像显示在标题栏；他们在当前文件中的光标以各自的颜色和名字标出。Overleaf 本身没有头像图片，这里和网页版一样使用彩色首字母。
- **评论**：实时模式下，带评论的文字以黄色底标出；「协作者与评论」面板可以跳转、回复、解决评论，或为选中的文字添加评论。
- **邀请合作者**：输入邮箱并选择可编辑 / 仅查看 / 审阅，由 Overleaf 发出邀请邮件；同时列出现有成员和待接受的邀请。

关联信息与合并基准保存在项目的 `.bettertex/overleaf.json` 和 `.bettertex/overleaf-base/`。已开启「修订」的项目中，从 BetterTeX 做的修改不会被记录为修订；只读或审阅权限下只接收不上传。自建 Overleaf 可通过 `defaults write dev.bettertex.app overleaf.host https://你的地址` 指定。

## 快捷键

| 快捷键 | 操作 |
| --- | --- |
| ⇧⌘O | 打开文件夹 |
| ⌘N | 新建文件 |
| ⌘S | 保存全部 / 处理外部修改冲突 |
| ⌘W | 关闭当前标签 |
| ⌘F | 查找 |
| ⌘↩ | 编译 / 停止 |
| ⇧⌘J | 在 PDF 中定位源码光标 |
| ⇧⌘Y | 与 Overleaf 同步 |
| ⌘J | 折叠 / 展开 Agent 面板（折叠后保留一条带标签图标的窄条，会话继续运行） |
| ⌘ 点击 | TeX ↔ PDF 双向定位 |

## 代码

- `Sources/BetterTeXCore/`：工具检测、进程执行、TeX 项目识别、编译、SyncTeX、Git，以及 Overleaf 的协议、三方合并、同步规划和网络客户端。
- `Sources/BetterTeX/`：AppKit 工作区、编辑器、PDFKit、SwiftTerm、文件监控，以及 Overleaf 登录窗口、同步控制器和协作界面。
- `Tests/BetterTeXCoreTests/`：核心与集成测试。Git 测试只使用临时本地仓库；没有安装 TeX 时对应测试明确跳过。
- `script/`：构建、图标和测试脚本。

内存随 PDF 页数、打开文件和终端数量变化，Agent 与 TeX 子进程占用单独计算。当前版本未提供 LSP、扩展市场、多窗口工作区或完整的 PDF 注释编辑。

UI 参考：[Overleaf 编辑器设计](https://docs.overleaf.com/getting-started/how-do-i-use-overleaf/redesigned-overleaf-editor)、[编辑器与 PDF 布局](https://docs.overleaf.com/navigating-in-the-editor/working-with-the-pdf-viewer/editor-and-pdf-layout-and-sizing)。未复制 Overleaf 源码或品牌资源。

## 许可证

BetterTeX 以 [MIT 许可证](../LICENSE) 发布：可以自由使用、修改和再分发（包括商业用途），只需保留版权声明和许可证全文。

第三方组件沿用各自的许可证，见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
