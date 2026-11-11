# Interface language

Add English alongside Simplified Chinese after bringing `origin/main` into `dev`.

- A dedicated AppKit settings window, available from BetterTeX → Settings… and `⌘,`, offers System Default, 简体中文, and English.
- Store the choice in `interface.language`. System Default resolves the first supported system preference and falls back to English. Set the app's `AppleLanguages` override for native panels; remove it when returning to System Default.
- Resolve a single immutable language at launch. Settings take effect after reopening, preserving active editor buffers and terminal sessions while the preference is changed.
- Bundle matching `en` and `zh-Hans` string tables in BetterTeXCore so views and core error messages share one lookup path. Interpolation uses numbered string placeholders, keeping user values separate from translation keys.
- Localize menu commands, dashboard, editor controls, PDF, agents, Overleaf, dialogs, accessibility labels, and relative dates. Keep protocol identifiers, conflict markers, existing documents, and external output stable.
- Verify preference persistence, system fallback, string-table coverage and format placeholders, both languages, existing core tests, packaged resource lookup, and the settings UI.
