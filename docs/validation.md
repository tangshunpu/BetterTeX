# BetterTeX 0.1.0 验证记录

日期：2026-11-11。环境：Apple Silicon、macOS 27.3、Apple Swift 6.4。

## 构建与测试

- Debug 与 Release 构建成功，Release 应用约 4.7 MB，ZIP 约 2.2 MB。
- `./script/test.sh`：13 项 XCTest 全部通过，0 跳过、0 失败。
- 实际调用 pdfLaTeX、XeLaTeX、LuaLaTeX 与 latexmk，验证编译失败后保留成功预览。
- 实际 SyncTeX 正反向往返，包括带空格的路径、子文件与主文件关系。
- 临时本地 bare Git 远端完成提交、Push、快进 Pull、重命名以及从子目录调用。未向用户远程仓库推送。
- 模型参数与本机模型缓存解析测试通过；真实 Codex 进程参数包含所选模型和思考强度，CLI 内显示相应配置。
- ZIP 解压到系统临时目录后通过 `codesign --verify --deep --strict`。源码位于 FileProvider 目录时，它可能重新附加 FinderInfo；分发应使用从干净暂存目录生成的 ZIP。
- `git diff --check` 与脚本语法检查通过。

## 窗口操作验证

- 示例文件树、源码标签、PDF 实际渲染；界面深浅色分别检查。
- PDF 与 Agent 标题栏分别拖动停靠；Move Left、Move Right、Move Bottom 菜单切换；恢复默认布局。
- 分隔线拖动改变源码 / PDF 宽度。
- Codex 在面板移动后保持同一个进程和会话。
- 模型与思考强度弹窗、模型能力联动、保存配置、恢复 CLI 默认。
- Shell 在项目目录运行，Codex 显示真实交互提示，Claude 显示真实目录信任提示。未发送模型推理请求，未替用户确认 Claude 信任提示。
- 优化版 Cmd 点击 PDF 跳到 `introduction.tex:5`，⇧⌘J 返回 PDF 第一页并高亮。

## 内存测量与范围

Release、示例单页 PDF、两个源码标签、无运行中的 Agent：`vmmap -summary` 记录物理内存占用约 138.5 MB。该次启动和 PDF / UI 操作过程的峰值约 504.4 MB，不能把空闲值视为内存上限。其他一次多次布局切换后的空闲测量约 191 MB。TeX 与 Agent 子进程不包含在应用进程数值内。

尚未进行大规模 PDF、超长 Agent 会话或长时间运行压力测试。当前为本机开发签名，未进行 Apple 公证，也未在 Intel 或 macOS 13 真机验证。

## Overleaf 集成（2026-11-11）

- `./script/test.sh`：28 项 XCTest 全部通过，其中 14 项针对 Overleaf：socket.io 帧、项目树、文本操作（含中文与 emoji）、三方合并（含随机用例）、同步规划、文件扫描与忽略规则、关联信息持久化、zip 往返。
- `BETTERTEX_OVERLEAF_LIVE=1 ./script/test.sh --filter testLiveService`：匿名连接 overleaf.com，确认握手格式、WebSocket 帧、CSRF 接口与未登录时的拒绝响应和实现一致。该测试默认跳过。
- 接口路径、参数与实时事件已对照 Overleaf 开源仓库（services/web、services/real-time）核对；评论线程接口不在开源部分，按网页版的已知行为实现。
- Debug 构建启动正常，无崩溃。

**尚未验证**：需要真实账户登录的全部流程——登录窗口、项目列表、导入、上传、文件同步、实时编辑、协作者光标、评论、邀请——均未在已登录状态下运行过；新增界面也未经目测。首次使用建议先在一个不重要的项目上试用。

## 编辑器右键菜单（2026-11-12）

- 全量回归：96 项，94 通过、2 项环境跳过（Overleaf 在线检查、需要前台 GUI 的更新焦点检查），无失败。
- 最终定向回归：14 项全部通过，包含 9 项新增的选区上下文 / AppKit 交互测试与 5 项本地化测试。覆盖中文与 emoji、CR/LF/CRLF 行号、代码围栏、选区快照、插入及撤销、取消附件、切换文件后发送、Codex / Claude 路由、只读校对、忙碌和工具缺失时保留草稿。
- Agent 派发通过临时本地 CLI 替身检查真实进程参数和提示内容；没有发送真实模型请求。
- 实际窗口验证：选中时保留选区并显示两个 Agent 操作；十个插入命令统一收在子菜单；没有系统追加的 AutoFill / Services；附加上下文后切换文件仍保留原文件与行号；修正 `/var` 与 `/private/var` 路径别名下的文件名显示。最后的手动插入 / 撤销检查因 Mac 锁屏中断，对应 AppKit 自动化测试通过。
- Debug 构建成功，缓存中的 Staging 应用签名验证通过并启动。项目位于 FileProvider 目录，最后复制到 `dist` 时 FinderInfo 被重新附加，分发副本签名检查未通过；验证运行使用的是缓存中的已签名 Staging 应用。

## Agent 额度与上下文圆环（2026-11-12）

- 全量回归：112 项，109 通过、3 项环境跳过（Overleaf 在线检查、默认关闭的 Codex 额度在线检查、需要前台 GUI 的更新焦点检查），无失败。
- 新增 15 项测试，覆盖只读额度握手、超时与取消、周期过期与未知值、当前请求与累计 token 区分、缓存与子 Agent、上下文压缩、模型切换、历史会话恢复、清空时取消旧数据、Provider 切换、手动刷新及 380 点窄面板布局。
- 单独启用 `BETTERTEX_CODEX_USAGE_LIVE=1` 的真实 Codex 额度测试通过；仅执行 `account/rateLimits/read`，没有发送模型请求。Claude 事件解析与面板联动使用本地 CLI 替身验证，未调用真实 Claude 模型。
- AppKit 位图检查确认额度文字与上下文圆环布局正常；未知值显示横线，高占用圆环显示提醒色。实窗检查因 Mac 锁屏未能完成。
- Debug 构建成功，缓存中的 Staging 应用通过 `verify_bundle.sh`（资源完整性与深度签名检查）。`dist` 副本仍因 FileProvider 重新附加 FinderInfo 未通过签名验证，本次没有将其视为可分发构建。
- 额度改为输入框上缘右侧的短进度条后，定向回归 16 项全部通过（用量界面、编辑器上下文、本地化）。完整面板位图确认 380 点宽度下进度条与圆环对齐，长文件名单行居中省略，不额外占行。该调整已重新编译，未重新生成应用分发包。
