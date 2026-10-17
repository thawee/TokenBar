# TokenBar design

Status: implemented (v0.2.1). Last updated 2026-10-18.

## 1. Goals

1. Show how close each AI coding tool is to its plan limit (5-hour, weekly, monthly) without opening each tool.
2. Show the system load that matters when running local models: CPU, memory, GPU, temperature.
3. Stay lightweight: under 1 MB on disk, under about 30 MB of memory, well under 1% CPU at steady state.
4. Never put the user's accounts at risk: read credentials only, never refresh or write them.

### Non-goals

- Token counting and cost. This was the main feature of [Token Monitor](https://github.com/Javis603/token-monitor), deliberately left out.
- Multi-device sync, history and charts.
- Per-process attribution of GPU or memory to a specific local LLM runtime.

## 2. Architecture

```
TokenBarApp (SwiftUI App, LSUIElement)
 ├─ MenuBarExtra (.window)
 │   ├─ label: headline percent
 │   └─ LimitsPanel: provider sections, Customize
 ├─ LimitsStore ──── providers: Claude, Codex, Copilot, Antigravity
 ├─ SystemStore ──── SystemSampler (actor) ── Mach, IOKit, SMC
 ├─ DockSettings ─── UserDefaults
 └─ DockController
     ├─ NSPanel (rail)  ── DockHostingView<DockView>
     └─ NSPanel (card)  ── NSHostingView<HoverCard>
```

There are two targets:

- **TokenBarCore** (library, no UI): models, parsers, providers, the stores, the system sampler and the SMC reader. Everything with logic lives here so it can be unit-tested.
- **TokenBar** (executable): SwiftUI views, the AppKit panels and settings.

There are no package dependencies. `scripts/bundle.sh` wraps the release binary in an `.app` with `LSUIElement` (no Dock icon) and signs it ad hoc.

### State and observation

All UI state is `@Observable` and `@MainActor`:

| Object | Owns |
|---|---|
| `LimitsStore` | per-provider `ProviderState` (last reading, last error, last attempt), the `enabled` set |
| `SystemStore` | latest `SystemSnapshot`, plus `availableMetrics`, which is assigned only when it changes |
| `DockSettings` | size, enabled tools, enabled metrics, used/remaining. Persisted on every change. |
| `DockState` | dock side, hovered item, ring frames (frames are `@ObservationIgnored`) |

SwiftUI views read these directly. AppKit code (`DockController`) uses `withObservationTracking` chains, guarded so that only one chain runs at a time, to relayout the panel or reposition the card.

## 3. AI plan limits

### Providers

Each provider implements `LimitsProvider { id; minInterval; fetch() async throws -> LimitsReading }`. Parsing is separate and pure (`Parsers`), and is tested against sanitized fixtures captured from live responses.

| Provider | Credential | Request | Interval |
|---|---|---|---|
| Claude Code | Keychain `Claude Code-credentials`, through `/usr/bin/security`; falls back to `~/.claude/.credentials.json` | `GET api.anthropic.com/api/oauth/usage`, `anthropic-beta: oauth-2025-04-20` | 300 s |
| Codex | none | tail (512 KB) of the newest session file from the last 8 days' `YYYY/MM/DD` folders; last `rate_limits` event | 30 s |
| Copilot | `~/.config/github-copilot/apps.json` or `hosts.json`, `oauth_token` | `GET api.github.com/copilot_internal/user` | 300 s |
| Antigravity | CSRF token from the IDE language server's command line (`ps`) + port (`lsof`), or the `agy` CLI's existing login | `POST 127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` when IDE runs; otherwise `agy -p "/quota" --output-format json` | 120 s |

Response fields, as verified against live data:

- **Claude:** `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet`, each with `utilization` (percent) and `resets_at` (ISO 8601 with microseconds, so the fractional part is stripped before parsing).
- **Codex:** `payload.rate_limits.primary` / `secondary` with `used_percent`, `window_minutes` (300 = 5-hour, 10080 = weekly) and `resets_at` (epoch seconds). A window whose reset time has already passed is shown as 0%, because the event is a snapshot from the last turn.
- **Copilot:** `quota_snapshots.{premium_interactions,chat,completions}.percent_remaining`. Windows marked `unlimited` are skipped. Resets on `quota_reset_date` (`YYYY-MM-DD`).
- **Antigravity:** `groups[].buckets[]` (either at top-level `response`/`summary` from the IDE language server or `command.data` from `agy -p "/quota" --output-format json`) with `remainingFraction` / `remaining_fraction`, `resetTime` / `reset_time` and bucket ids (`gemini-5h`, `gemini-weekly`, `3p-5h`, `3p-weekly`, `gemini-argon-wtu-weekly`).

### Scheduling (`LimitsStore`)

- A loop ticks every 30 s and fetches every enabled provider whose interval has elapsed.
- Opening the popover runs a normal due-check refresh; pressing Refresh forces a fetch, keeping network providers at least 30 s apart.
- After a `failed` or `unauthorized` error, a provider retries after 60 s instead of waiting a full interval.
- A failed fetch keeps the last good reading, so the UI shows stale numbers, not nothing. `notConfigured` clears the reading.
- Only one refresh runs at a time. A request that arrives during a refresh runs once that refresh finishes.
- Disabled tools are filtered before fetching, their state is cleared, and a result that arrives for a tool just turned off is dropped. Re-enabling a tool fetches it right away.

### Display

The used percentage is stored. `LimitWindow.currentUsedPercent(now:)` returns `0` when a window's `resetsAt` time has passed so pre-reset usage is never shown alongside `"Resetting now"`. `LimitDisplay` converts it to "used" or "left" in one place, so the dock, card, popover and menu bar always agree. The alert threshold is symmetric: 90% used or 10% left.

Each tool is represented by its headline window (`LimitsReading.headlineWindow`): the 5-hour window, or its first window if it has none, as with Copilot's monthly quota. The dock rings and the menu bar both use it. `LimitsStore.mostUrgent()` picks the visible tool with the highest headline usage, skipping windows whose reset time has passed.

The menu bar (`MenuBarMode`) shows the most urgent tool's logo and number by default, a pinned tool, or just the gauge icon until a limit passes 70% used. Logos are drawn as 16 pt template images, so they follow the menu bar's light or dark appearance. Antigravity's multicolor logo becomes a silhouette.

`ProviderID.displayOrder` sorts tools by display name. The dock, popover, menu bar picker, and settings use this order.

The menu bar popover (`LimitsPanel`) uses `ViewThatFits(in: .vertical)` to size intrinsically to its content up to 480 pt and scroll cleanly when multiple providers and the Customize section are expanded.

## 4. System metrics

`SystemSampler` is an actor. All handles are opened once: the host port, the `IOAccelerator` service and the SMC connection.

| Metric | Method | Cost per read |
|---|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)`, busy/total tick delta between samples | under 0.01 ms |
| Memory | `host_statistics64(HOST_VM_INFO64)`: (internal − purgeable + wired + compressor) × page size | under 0.01 ms |
| GPU | `IORegistryEntryCreateCFProperty(PerformanceStatistics)["Device Utilization %"]` | about 0.003 ms |
| Temperature | SMC, refreshed every 10 s (see below) | a few ms |

`SystemStore` samples every 2 s, and only while the dock is visible and at least one metric is enabled. The loop uses throwing sleeps, so stopping it never publishes a stale sample.

### Top processes

The CPU and Memory cards list the 5 heaviest processes. `SystemStore.setProcessFocus` starts a 2 s scan loop when one of those cards opens and stops it when the card closes, so the scan costs nothing the rest of the time. Scans run detached at utility priority, and `ProcessList` reserves 5 rows while measuring so the hover card does not jump vertically when the first scan completes.

| List | Source | Why |
|---|---|---|
| CPU | `/bin/ps -axo pid=,%cpu=,comm=`, about 30 ms | `proc_pid_rusage` and `PROC_PIDTASKINFO` fail for root and system processes without root (244 of 541 here), which would hide WindowServer |
| Memory | `proc_pid_rusage` `ri_phys_footprint` for readable (own) processes, about 1.3 ms for all | The footprint includes GPU and compressed memory. `ps` RSS showed a local model server at 0.2 GB while its footprint was 22.5 GB |

### Temperature

Apple documents no temperature API for Apple Silicon. `DieTemperatures` picks a source once per machine:

1. If SMC key `TCMb` reads as a plausible temperature, use `TCMb` (CPU-die average) and `TCMz` (CPU-die hottest point).
2. Otherwise walk the SMC key table once and average every `Tp*` / `Te*` key, the approach Stats and macmon use.
3. GPU: the average of all `Tg*` keys.

Readings outside 15–130 °C are dropped. Idle, power-gated clusters report sentinel values of about −4 to 5 °C, and some `T` keys are not temperatures.

The SMC is read through the `AppleSMC` user client (selector 2), which needs no root. `SMCKeyData` must match the kernel's 80-byte layout. `KeyInfo` carries explicit tail padding, because Swift would otherwise place the following fields into it. A unit test pins the offsets: this exact bug made the first version return no temperatures.

## 5. Side dock

### Panel

- A borderless, `.nonactivatingPanel` `NSPanel` at `.statusBar` level, with `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.stationary` and `.ignoresCycle`. It floats over full-screen apps and never takes focus.
- The rail shape (`DockShape`) is a rounded body with concave fillets where it meets the screen edge, drawn for the right edge and mirrored for the left.
- Size comes from one scale factor (`DockScale`, 0.6 to 1.0, default 0.85). Every dimension in `DockMetrics` is derived from it: width (46 to 76 pt), ring, stroke, logo, text, spacing, edge fillet and corner radius. Section headings show from 0.8 up.
- Provider rings show an error badge (`exclamationmark.circle.fill`) when a fetch fails, and ring strokes / card progress bars turn `alertRed` when in the alert threshold.
- Right-clicking the dock opens a context menu with Refresh Limits, Used/Remaining toggle, Hide Side Dock and Quit.

### Drag and snap

The panel is moved with `NSEvent.mouseLocation` deltas, in AppKit screen coordinates. On release:

- The target is the screen under the pointer, not `panel.screen`, which is the screen with the largest overlap.
- The side is whichever half of that screen the pointer is in.
- The vertical center is saved as a fraction of the visible height. The display ID, side and fraction go to UserDefaults.

### Hover

SwiftUI `onHover` does not fire in an inactive app, and the dock's app is almost always inactive. So `DockHostingView` adds an `NSTrackingArea` with `.activeAlways`, `.mouseMoved` and `.inVisibleRect`, converts pointer positions to SwiftUI coordinates, and hit-tests the ring frames by picking the closest ring vertically across the rail width (so Fitts's law edge hovering and vertical scrubbing between rings never drop hover).

The card is a second, click-through panel (`ignoresMouseEvents`), so it never takes hover away from the rail:

- It sits on the screen-interior side, vertically centered on the ring and clamped to the visible frame.
- It is re-measured and repositioned when its data changes, after rail animations, and when ring frames move.
- It closes when hover clears, when right-clicking or dragging starts, when the dock hides, and when its item leaves the rail.

## 6. Settings

**Open at login** uses `SMAppService.mainApp`. The system registration is the source of truth: the toggle reads `status` instead of a saved flag, so it reflects changes made in System Settings. The first launch registers once (tracked by `loginItem.configured`), and after that only the toggle changes it, so turning it off sticks. `requiresApproval` shows a link to System Settings > Login Items. Verified on macOS 26: an ad-hoc-signed build in `~/Applications` registered as `enabled` with no prompt.

`DockSettings` is backed by UserDefaults (`dock.scale`, `dock.tools`, `dock.metrics`, `limits.display`, `menubar.mode`, plus `dock.visible`, `dock.side`, `dock.center` and `dock.display`). The enabled tools feed `LimitsStore.enabled`, so turning a tool off also stops it being fetched.

## 7. Decisions and rejected alternatives

| Decision | Alternative rejected | Why |
|---|---|---|
| Native SwiftUI + AppKit | Electron (as in Token Monitor) | The size and memory goals. Measured: 668 KB bundle, 23 to 47 MB of memory. |
| Read the Claude token, never refresh it | Refresh it with `console.anthropic.com/v1/oauth/token` | Refreshing can rotate the token Claude Code holds and sign it out. On macOS, Token Monitor refreshes but does not write back to the Keychain. |
| `/usr/bin/security` for the Keychain read | `SecItemCopyMatching` | The item's access list already trusts `security`. A native read from an ad-hoc-signed app prompts again after every rebuild. |
| Codex from local session logs | `chatgpt.com/backend-api/wham/usage` | The same numbers with no network and no credentials. |
| Copilot token from `apps.json` | GitHub device-flow login | Verified accepted by `copilot_internal/user` (HTTP 200) on 2026-10-14, so no login UI is needed. |
| Antigravity through the local IDE language server or `agy -p /quota` | Google OAuth with embedded client secret | No sign-in UI and no embedded secrets; works whether the user runs the Antigravity IDE or the `agy` CLI. |
| SMC `TCMb`/`TCMz` for temperature | HID `PMU tdie` sensors (first implementation) | On an M3 Pro under load, `PMU tdie` stayed flat at 66.8–67.0 °C while `TCMb` read 98–105 °C and followed the load. The HID sensors probably measure the power-management chip. |
| SMC `TCMb`/`TCMz` | hagimi-monitor's fixed M1 key list (`Tp09`, `Tp0T`, …) | Only 5 of those 10 keys exist on the M3 Pro, and their meanings vary by chip. `TCMb` is the SMC's own aggregate. |
| Temperature every 10 s, read only the needed keys | Reading every sensor every 2 s | The first build read 36 HID sensors per sample: 39 ms per sample and about 5% CPU in its first minute. |
| No animation on system rings | Animating every value change | Values change every 2 s. Animating each change keeps SwiftUI rendering at display rate. |
| GPU card shows utilization only | Showing "In use system memory" as GPU memory | That value (about 24 GB here) includes window-server surfaces. Labeling it "GPU" or "LLM memory" would mislead. |
| Polling | FSEvents watching of session logs | Plan limits change slowly, and polling Codex every 30 s reads one file tail. |

## 8. Performance

Measured on an M3 Pro (36 GB) running macOS 26:

| | Value |
|---|---|
| Bundle size | 684 KB |
| Memory (physical footprint) | 19 MB menu bar only; 23 to 47 MB with the dock and all metrics, varying between runs. Flat at 47 MB over 4 minutes in the latest run, so not growing. |
| Steady CPU with the dock and all metrics | 0.29 s per 60 s, about 0.5% |
| First sample | 0.32 s, once, off the main thread (SMC key walk for the GPU keys) |
| Steady sample | 0.03 ms |

The first minute after launch costs more (about 1 s of CPU), for the initial fetches and the first render.

## 9. Testing

- **Unit tests** (`swift test`, 29): the parsers for all four tools (including Antigravity CLI `/quota` JSON) against fixtures, Codex and window reset expiry handling, ISO dates with microseconds, store intervals, retry after failure, the force floor, enabled tools, display order, headline staleness, CPU tick math, the memory formula, SMC struct layout and decoders, and sampler stop.
- **Live tests** (`LIVE=1`): call the real providers and sampler on this machine, printing values, never tokens.
- **Visual checks:** the dock and cards were rendered off-screen with `ImageRenderer` (both sizes, both sides, used and remaining).

## 10. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Claude or Copilot changes the undocumented endpoint | That tool shows an error | The error appears per tool, and the last good reading stays |
| SMC keys differ on other chips | Temperature is missing or off | The 15–130 °C filter, the per-core fallback, and hiding the metric when unavailable |
| Antigravity language-server or CLI `/quota` format changes | Antigravity shows an error | Error badge on the dock ring and error message in the popover/card |
| The Keychain prompt is denied | Claude shows "not configured" | Documented in the README |

## 11. Future work

- Gemini CLI (`gemini`) quotas.
- Optional token and cost totals for today (the "TODAY" header in the original mockup).
- Per-process GPU attribution, to name the app behind sustained GPU load (the memory list already shows a local model server's footprint).
- A tool-agnostic way to verify hover and drag in CI.
