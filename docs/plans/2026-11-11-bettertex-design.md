# BetterTeX — native macOS LaTeX workspace

## Scope and architecture

Build a standalone macOS 13+ app in Swift and AppKit, with PDFKit for preview and SwiftTerm for a real PTY. The only runtime dependency is SwiftTerm; TeX distributions and agent CLIs stay on the user's machine. SwiftPM produces a local .app via one build script. No web engine, language server, remote service or polling loop is required.

The window uses a narrow activity rail, lazy directory tree, tabbed NSTextView editor, PDF preview, collapsible agent/log panel, and compact status bar. Follow the system appearance, as requested by the user; keep the PDF page white. Native resizable split views keep the layout useful on laptops. Terminal sessions start only when requested and have bounded scrollback. Text highlighting is debounced and bounded to visible text.

The confirmed default is file tree → source → PDF → Agent/Terminal. Both PDF and Agent headers drag to left, right or bottom and offer equivalent move menus. Persist panel order and splitter sizes without replacing live terminal sessions. Reference Overleaf's compact controls and PDF compilation toolbar; implement the interface independently in AppKit.

## Functional behavior

- Resolve the login-shell PATH plus standard MacTeX, Homebrew, TinyTeX and agent installation locations. Report missing tools without pretending to install them.
- Auto-select the root through `% !TeX root`, the active document's `documentclass`, or a project main file. Honor `% !TeX program`; offer Auto, pdfLaTeX, XeLaTeX, LuaLaTeX and latexmk. Prefer latexmk for dependency-aware multi-pass compilation; provide direct engine passes and bibliography support when absent.
- Save after an editing debounce and compile when enabled. Preserve a known-good preview on failure, show logs and clickable file/line errors. Use `.bettertex` for build products and enable SyncTeX.
- Command-click or shortcut sends the TeX cursor to the PDF. Command-click PDF calls `synctex edit` and opens the relevant source line. Use PDF media-box coordinates with correct vertical inversion.
- Codex, Claude and shell run in genuine PTYs in the project directory; authentication and approvals remain in the CLI. Switching workspaces stops old sessions.
- The user clarified that Agent is a polished CLI surface. Native model/effort controls pass real CLI arguments for new sessions, with defaults preserving existing CLI configuration. Codex model metadata comes from its local model cache. No API proxy, synthetic conversation transcript or hidden approval bypass. Current file/selection insertion uses bracketed paste and does not submit the prompt.
- Pull uses `--ff-only`; Push sends existing commits, or first shows a review/commit sheet for working-tree changes. Do not add a remote or force-push automatically.
- Detect external source changes with file-system events, reload clean buffers and require a choice for dirty conflicts. Save atomically; never silently overwrite an externally modified file.

## Validation

Unit tests cover root/engine selection, arguments with spaces, SyncTeX parsing/coordinate transforms, disk conflict detection and Git porcelain parsing. Integration checks compile an actual TeX fixture and exercise both SyncTeX directions; use temporary local Git repositories for pull/commit/push. Build and launch the staged app, inspect actual UI, and measure idle resident memory separately from child TeX/agent processes.

## Deliberate boundaries

No TeX distribution is bundled. Agent subscriptions/login remain prerequisites. This local development build is ad-hoc signed, not notarized for public distribution. It is an editor, not a complete TeX language server or extension marketplace.
