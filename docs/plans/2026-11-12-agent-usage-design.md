# Agent quota and context usage

Place a compact horizontal quota progress bar and a 28-point context ring at the upper right of the composer, on the existing context row. The quota control is 112 × 28 points, with remaining percentage above a four-point track; the ring remains beside it. Do not add another toolbar, panel, setting, or row. Both controls open the same small details menu.

- Quota means the remaining percentage in the most constrained reported account window. The bar shrinks as quota is consumed, becoming orange at 25% remaining and red at 10%; unknown or stale data uses a neutral dashed track. The menu shows each period, reset time, plan when reported, and observation time. A passed reset time or five-minute-old snapshot is stale, not a fabricated 100% recovery. Missing quota is unknown, not zero.
- Context means the latest model request's token footprint divided by its reported capacity. Never divide accumulated turn/session billing tokens by a model limit. The ring shows the percentage used; its track stays neutral with a dash when the capacity or usage is missing. Warn at 75% and 90%, and expose the meaning and percentage to accessibility.
- Codex quota uses a short-lived local `codex app-server` connection with initialize/initialized followed only by `account/rateLimits/read`. Refresh at most once per minute while visible or on explicit refresh. Do not read credentials, trigger a login, start model turns, or use private HTTP endpoints.
- Codex context reads only the active thread's bounded rollout tail off the main thread. Use `last_token_usage.total_tokens` and `model_context_window`; clear on a compaction event until a new count arrives. Reuse the log's timestamped quota if it is newer. Poll during a running turn and once after it ends, and refresh on history resume.
- Claude context uses the latest top-level assistant request's input, cache-read and cache-write counts, matching its status-line formula. Use `modelUsage[actualModel].contextWindow` only for capacity; its accumulated token counts and subagent usage do not feed the ring. Handle compaction and model switches without keeping mismatched capacities.
- Claude quota comes from `rate_limit_event`. Handle utilization, reset time and rejection without inventing missing numbers. Where the CLI only reports status or has not emitted a quota event, explain the unavailable data in the details menu. No background model call is made to obtain it.
- New sessions clear context. Project changes cancel background reads. Codex and Claude displays remain independent; Shell and Output hide the composer as before. Background failures stay inside usage details rather than interrupting editing.

Primary references, checked against the locally installed CLI schema on 2026-11-12:

- [Codex app-server protocol](https://developers.openai.com/codex/app-server)
- [Claude Code status-line data and context calculation](https://code.claude.com/docs/en/statusline)
- [Claude SDK message types and model usage](https://code.claude.com/docs/en/agent-sdk/typescript)

Validation: protocol fixtures for quota refresh/timeout/cancellation, current-vs-cumulative token counts, caches/subagents, compaction/model changes, expiry/unknown data; AppKit tests for provider changes, refresh actions and narrow composer layout. A read-only Codex quota integration test is opt-in; no model request is needed.
