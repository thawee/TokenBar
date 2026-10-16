# Changelog

## 0.2.0 (2026-10-16)

### Features
- **Antigravity CLI (`agy`) support:** `AntigravityProvider` now queries `agy -p "/quota" --output-format json` when the standalone Antigravity IDE is not running, supporting `Gemini`, `Claude/GPT`, and `Gemini Argon` quota windows without needing the IDE open.
- **Side dock context menu:** Right-clicking the side dock provides quick actions to Refresh Limits, switch between Used % and Remaining %, Hide Side Dock, or Quit TokenBar.
- **User Applications install default:** `scripts/install.sh` now defaults to `~/Applications` (overridable via `DEST=/Applications`).

### UI/UX Fixes
- **Expired window reset handling:** Added `LimitWindow.currentUsedPercent(now:)` so windows past their `resetsAt` timestamp display `0% used` (`100% left`) across the menu bar, dock rings, hover cards, and popover instead of showing stale pre-reset percentages alongside `"Resetting now"`.
- **Dock error badge & unified alert coloring:** Added an error indicator badge (`exclamationmark.circle.fill`) on dock rings when a provider has a fetch or auth error, and unified `alertRed` coloring across dock ring strokes and hover card usage bars at $\ge 90\%$ used ($\le 10\%$ left).
- **Flicker-free dock hover & stable process list height:** Updated `DockController.pointerMoved(to:)` to pick the closest ring vertically across the full width of the rail (eliminating Fitts's law edge dead zones and inter-ring hover card flicker), and reserved 5-row height in `ProcessList` while measuring so CPU/Memory hover cards do not jump vertically when process results arrive.
- **Scrollable menu bar popover & refresh indicator:** Wrapped `LimitsPanel` content in `ViewThatFits(in: .vertical)` with a `ScrollView` fallback (480 pt max height), added a refresh spinner, and preserved the 30-second forced-refresh floor for manual **Refresh** button clicks.

## 0.1.0 (2026-10-14)

- Initial release of TokenBar with menu bar popover and floating side dock.
- Plan limit providers for Claude Code, Codex, GitHub Copilot, and Antigravity IDE.
- Whole-Mac system load rings and hover cards for CPU, Memory, GPU, and Apple Silicon SMC die temperatures, plus top 5 CPU and memory processes.
- Customizable dock size slider, Used/Remaining display toggle, menu bar mode picker, and Open at login (`SMAppService`).
