# Changelog

## Unreleased

- Local model servers: a LOCAL section in the dock shows Kapitsa and Splash while they run, one ring each for the memory the server holds out of its limit. Kapitsa: the server process's footprint against `--mem-budget` (or the GPU memory macOS allows, its default), plus model, context and slots from `/v1/models`. Splash: memory, average read and write speed, tokens, requests and queue from `/status`. Found by process every 5 s while the dock is visible; turn either off under Customize > Local models.
- Add a Storage ring (sky blue) and card for the boot disk: used of total, and available as Finder reports it (purgeable space counts as free). Read every 30 s. It is turned on for existing installs too: settings now remember which metrics they have seen, so later metrics start on.
- Add "Combine CPU and GPU in one ring" (off by default) to save a slot on the rail: CPU on the outer ring, GPU on the inner ring, the busier of the two as the number, and both in the hover card.
- App icon: the side dock as a bar of three gauges, drawn by `scripts/make-icon.swift` and packed by `scripts/make-icon.sh`. Shown wherever macOS shows the app's icon.
- The menu bar shows the app icon as a one-color glyph (the rail with three rings) where it showed a generic gauge: in Icon only mode, and when no tool has a reading.
- An alert ring now also fills with faint red, so it does not rest on arc color alone. Claude's brand color is close to the alert red, and a healthy Claude ring looked like an alert.
- GPU uses a solid cube icon, which stays distinct from the memory chip at small sizes. Ring icons are at least 10 pt.
- VoiceOver reads each ring as a name and value: tools give the headline window, used or left, reset time and any error; the combined ring gives CPU and GPU.
- Contrast: the alert red is lighter (4.64:1 on the rail), and the card's "Updated", "TOP PROCESSES" and CPU footnote text is 10 pt at 4.5:1 or better.
- Reduce Motion turns off the hover zoom, the ring fill animation and the rail's animated resize.
- Order system metrics CPU, GPU, Memory, Storage, Temperature: processors, then capacity, then the slow sensor.

## 0.2.1 (2026-10-18)

- Show AI tools A–Z by name in the dock, popover, menu bar picker, and settings.

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
