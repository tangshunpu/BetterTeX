# Focused editor context menu

Keep the existing toolbar and Agent composer. Add no permanent controls, secondary chat surface, or settings.

- With nonblank selected text, show **Add to Agent Context** and **Proofread Selection** first. Hide those actions without a selection; never silently expand proofreading to the whole document.
- Group the existing ten insertion commands under one **Insert** submenu, followed by standard Cut, Copy, Paste and Select All. Reuse the existing snippet/image handlers and undo behavior.
- Right-click within the selection preserves it. Right-click elsewhere moves the insertion point to the clicked position. Dismiss completion before showing the menu.
- Explicit context attachment captures the source text, relative path and line range. Reuse the existing context chip, preserve the draft, and focus the last used Codex/Claude conversation. The chip stays pinned across edits and file switches; clicking it cancels attachment. A successful send consumes the snapshot, while failed/busy sends retain it. The existing + button uses the same attachment path.
- Proofreading sends the selected snapshot immediately through the current provider using read-only permissions for that turn. Ask for corrected LaTeX plus brief notes, preserving language, meaning, commands, math, references and labels. Show results in the existing conversation without changing source, a pending message or its attachment. Busy/unavailable agents use existing feedback and do not start duplicate requests.
- Closing/switching a project clears the pending draft and attachment. Menu labels, hints and the proofreading instruction support English and Simplified Chinese.

Validate selection/caret behavior, shared snippet insertion, Unicode and newline ranges, snapshot stability, provider routing, read-only dispatch, draft preservation and failure handling. Use a local CLI fixture rather than a paid model request for dispatch tests, then inspect the built app.
