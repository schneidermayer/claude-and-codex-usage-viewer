# Claude and Codex Usage Viewer

- Native macOS SwiftUI/WidgetKit, one to three accounts in any mix of Claude and Codex, Liquid Glass, semantic colors, system type, accessible controls. No menu bar tray icon.
- Each Codex account uses a private app-owned `CODEX_HOME`; each Claude account uses a private app-owned `CLAUDE_CONFIG_DIR` and directory-scoped CLI credential storage. Never copy, log, or commit credentials. Widgets receive only sanitized snapshots.
- Use Codex app-server account methods, without inference. Read the default local identity through read-only `account/read`; never login, logout, or refresh its tokens.
- Full names: app-owned logins only, matched to the official account email; email fallback. Never read normal Codex tokens for names.
- Missing, stale, or expired limits are unknown. A reset timestamp does not prove quota recovery.
- Widgets: Small (square), Large (wide), with one to three configured account columns and provider labels. Weekly usage, seven-day reset bar, numeric countdown; no header or "left" text. Subscription badge before the bar; icon-only Codex resources. Earned resets are centered within Small columns and right-aligned in Large. Computer icon for the local Codex account.
- Show subscription and **Logged In** together in the app. For Codex map Prolite → 100, Pro → 200, Promax → 500; preserve Claude plans, other names, and missing values.
- Validate code with Swift tests, a native build, and UI/visual checks. Distinguish fixture renders from live-account and desktop widget checks.
- Finish every task involving code changes by building the current source, stopping all existing app/widget instances and their child workers, installing in `/Applications`, restarting, and verifying the running executable and version match the new build.
- `VERSION` is the release number. Tagged builds display it alone; development builds append commits since the nearest numeric release tag. Use `scripts/release.py`; never move a published tag.
