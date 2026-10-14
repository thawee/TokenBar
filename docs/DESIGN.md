# TokenBar design

Status: implemented (v0.1.0). Last updated 2026-10-14.

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
| Antigravity | CSRF token from the language server's command line (`ps`); port from `lsof` | `POST 127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary` (https, then http) | 120 s |

Response fields, as verified against live data on 2026-10-14:

- **Claude:** `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet`, each with `utilization` (percent) and `resets_at` (ISO 8601 with microseconds, so the fractional part is stripped before parsing).
- **Codex:** `payload.rate_limits.primary` / `secondary` with `used_percent`, `window_minutes` (300 = 5-hour, 10080 = weekly) and `resets_at` (epoch seconds). A window whose reset time has already passed is shown as 0%, because the event is a snapshot from the last turn.
- **Copilot:** `quota_snapshots.{premium_interactions,chat,completions}.percent_remaining`. Windows marked `unlimited` are skipped. Resets on `quota_reset_date` (`YYYY-MM-DD`).
- **Antigravity:** `groups[].buckets[]` with `remainingFraction` (in one of three shapes), `resetTime` and bucket ids such as `gemini-5h` / `3p-weekly`.

### Scheduling (`LimitsStore`)

- A loop ticks every 30 s and fetches every enabled provider whose interval has elapsed.
- Opening the popover or pressing Refresh forces a fetch, but network providers are still kept at least 30 s apart.
- After a `failed` or `unauthorized` error, a provider retries after 60 s instead of waiting a full interval.
- A failed fetch keeps the last good reading, so the UI shows stale numbers, not nothing. `notConfigured` clears the reading.
- Only one refresh runs at a time. A request that arrives during a refresh runs once that refresh finishes.
- Disabled tools are filtered before fetching, their state is cleared, and a result that arrives for a tool just turned off is dropped. Re-enabling a tool fetches it right away.

### Display

The used percentage is stored. `LimitDisplay` converts it to "used" or "left" in one place, so the dock, card, popover and menu bar always agree. The alert threshold is symmetric: 90% used or 10% left. The headline is the highest 5-hour usage, skipping windows whose reset time has passed.

## 4. System metrics

`SystemSampler` is an actor. All handles are opened once: the host port, the `IOAccelerator` service and the SMC connection.

| Metric | Method | Cost per read |
|---|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)`, busy/total tick delta between samples | under 0.01 ms |
| Memory | `host_statistics64(HOST_VM_INFO64)`: (internal − purgeable + wired + compressor) × page size | under 0.01 ms |
| GPU | `IORegistryEntryCreateCFProperty(PerformanceStatistics)["Device Utilization %"]` | about 0.003 ms |
| Temperature | SMC, refreshed every 10 s (see below) | a few ms |

`SystemStore` samples every 2 s, and only while the dock is visible and at least one metric is enabled. The loop uses throwing sleeps, so stopping it never publishes a stale sample.

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
- Size comes from `DockMetrics`: Normal is 76 pt wide with 42 pt rings and headings; Mini is 50 pt with 30 pt rings and no headings. Height comes from the SwiftUI content (`fittingSize`, measured after `layoutSubtreeIfNeeded`).
- The panel relayouts when the visible tools, the size, the enabled metrics or the available metrics change, when the screen configuration changes, and when ring frames change after SwiftUI has applied an update.

### Drag and snap

The panel is moved with `NSEvent.mouseLocation` deltas, in AppKit screen coordinates. On release:

- The target is the screen under the pointer, not `panel.screen`, which is the screen with the largest overlap.
- The side is whichever half of that screen the pointer is in.
- The vertical center is saved as a fraction of the visible height. The display ID, side and fraction go to UserDefaults.

### Hover

SwiftUI `onHover` does not fire in an inactive app, and the dock's app is almost always inactive. So `DockHostingView` adds an `NSTrackingArea` with `.activeAlways`, `.mouseMoved` and `.inVisibleRect`, converts pointer positions to SwiftUI coordinates, and hit-tests the ring frames.

Ring frames come from a `PreferenceKey` in a named `"dock"` coordinate space. They are keyed by `DockItem` (`.provider` or `.metric`).

The card is a second, click-through panel (`ignoresMouseEvents`), so it never takes hover away from the rail:

- It sits on the screen-interior side, vertically centered on the ring and clamped to the visible frame.
- It is re-measured and repositioned when its data changes, after rail animations, and when ring frames move.
- It closes when hover clears, when a drag starts, when the dock hides, and when its item leaves the rail.

## 6. Settings

**Open at login** uses `SMAppService.mainApp`. The system registration is the source of truth: the toggle reads `status` instead of a saved flag, so it reflects changes made in System Settings. The first launch registers once (tracked by `loginItem.configured`), and after that only the toggle changes it, so turning it off sticks. `requiresApproval` shows a link to System Settings > Login Items. Verified on macOS 26: an ad-hoc-signed build in `~/Applications` registered as `enabled` with no prompt.

`DockSettings` is backed by UserDefaults (`dock.size`, `dock.tools`, `dock.metrics`, `limits.display`, plus `dock.visible`, `dock.side`, `dock.center` and `dock.display`). The enabled tools feed `LimitsStore.enabled`, so turning a tool off also stops it being fetched.

## 7. Decisions and rejected alternatives

| Decision | Alternative rejected | Why |
|---|---|---|
| Native SwiftUI + AppKit | Electron (as in Token Monitor) | The size and memory goals. Measured: 588 KB bundle, about 23 MB of memory. |
| Read the Claude token, never refresh it | Refresh it with `console.anthropic.com/v1/oauth/token` | Refreshing can rotate the token Claude Code holds and sign it out. On macOS, Token Monitor refreshes but does not write back to the Keychain. |
| `/usr/bin/security` for the Keychain read | `SecItemCopyMatching` | The item's access list already trusts `security`. A native read from an ad-hoc-signed app prompts again after every rebuild. |
| Codex from local session logs | `chatgpt.com/backend-api/wham/usage` | The same numbers with no network and no credentials. |
| Copilot token from `apps.json` | GitHub device-flow login | Verified accepted by `copilot_internal/user` (HTTP 200) on 2026-10-14, so no login UI is needed. |
| Antigravity through the local language server | Google OAuth with the IDE's client secret | No sign-in and no embedded secrets. The cost: it works only while the IDE runs. |
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
| Bundle size | 588 KB |
| Memory (physical footprint) | 19 MB menu bar only; about 23 MB with the dock and all metrics (other runs read up to 42 MB) |
| Steady CPU with the dock and all metrics | 0.29 s per 60 s, about 0.5% |
| First sample | 0.32 s, once, off the main thread (SMC key walk for the GPU keys) |
| Steady sample | 0.03 ms |

The first minute after launch costs more (about 1 s of CPU), for the initial fetches and the first render.

## 9. Testing

- **Unit tests** (`swift test`, 22): the parsers for all four tools against fixtures, Codex reset handling, ISO dates with microseconds, store intervals, retry after failure, the force floor, enabled tools, headline staleness, CPU tick math, the memory formula, SMC struct layout and decoders, and sampler stop.
- **Live tests** (`LIVE=1`): call the real providers and sampler on this machine, printing values, never tokens.
- **Visual checks:** the dock and cards were rendered off-screen with `ImageRenderer` (both sizes, both sides, used and remaining).
- **Not automated:** real pointer hover and drag, because the development terminal has no Accessibility permission to send synthetic mouse events. A temporary debug hook confirmed the hover hit-testing and the card placement in the running app.

## 10. Risks

| Risk | Effect | Mitigation |
|---|---|---|
| Claude or Copilot changes the undocumented endpoint | That tool shows an error | The error appears per tool, and the last good reading stays |
| SMC keys differ on other chips | Temperature is missing or off | The 15–130 °C filter, the per-core fallback, and hiding the metric when unavailable |
| Antigravity language-server API changes | Antigravity shows an error | Only matters when the IDE is installed |
| The Keychain prompt is denied | Claude shows "not configured" | Documented in the README |

## 11. Future work

- Gemini CLI quotas.
- Optional token and cost totals for today (the "TODAY" header in the original mockup).
- Per-process GPU attribution, to name the app behind sustained GPU load.
- A tool-agnostic way to verify hover and drag in CI.
