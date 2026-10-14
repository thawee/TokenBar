# TokenBar

A lightweight native macOS menu bar app and side dock that shows how much of your AI coding plan limits you have used, next to CPU, memory, GPU and temperature for the whole Mac.

- **AI plan limits** for Claude Code, Codex, GitHub Copilot and Antigravity: 5-hour, weekly and monthly windows with reset times.
- **System load** for running local models: CPU, memory, GPU and CPU/GPU die temperature.
- **Native and small**: SwiftUI + AppKit, no dependencies, about 590 KB on disk, about 23 MB of memory and about 0.5% CPU while sampling.

It was built as a lightweight alternative to [Token Monitor](https://github.com/Javis603/token-monitor), covering only plan limits and system load.

## Features

**Menu bar.** By default it shows the logo and number of the tool closest to its limit (each tool counts its 5-hour window, or its monthly one if it has no 5-hour window). Customize > Menu bar can pin one tool instead, or show only the gauge icon until any limit passes 70% used. Click it for every tool's windows, reset times and errors, a Refresh button and the Customize section.

**Open at login.** On by default from the first launch. Turn it off with the "Open at login" switch in the popover. It uses the system login-item service (`SMAppService`), so it also appears in System Settings > General > Login Items.

**Side dock.** A floating rail on the left or right screen edge, above all apps and Spaces:

- One ring per item: system metrics on top, AI tools below.
- Hover a ring for a card with details: every limit window and its reset time, or the metric's breakdown.
- Drag it anywhere. It snaps to the nearer edge of the screen you drop it on and remembers the screen, side and height.
- Any size from 46 to 76 pt wide with the Dock size slider. Everything scales together, and section headings show from 80% up.

**Customize** (in the menu bar popover):

| Setting | Options |
|---|---|
| Show side dock | on / off |
| Dock size | slider, 60% to 100% (46 to 76 pt wide), default 85% |
| AI limits | Used / Remaining. Applies to the dock, cards, popover and menu bar. Red at 90% used or 10% left. |
| Menu bar | Most urgent tool / a specific tool / Icon only, number from 70% |
| AI tools | Claude Code, Codex, GitHub Copilot, Antigravity. A tool you turn off is never checked: no Keychain read, no network call. |
| System | CPU, Memory, GPU, Temperature |

## Data sources

| Tool | Source | Network |
|---|---|---|
| Claude Code | OAuth token from the Keychain item `Claude Code-credentials`, then `GET api.anthropic.com/api/oauth/usage` | every 5 min |
| Codex | `rate_limits` in the newest `~/.codex/sessions/YYYY/MM/DD/*.jsonl` | none |
| GitHub Copilot | `oauth_token` from `~/.config/github-copilot/apps.json`, then `GET api.github.com/copilot_internal/user` | every 5 min |
| Antigravity | the running IDE's local language server (`RetrieveUserQuotaSummary`) | loopback only, every 2 min |

| Metric | Source | Interval |
|---|---|---|
| CPU | `host_statistics(HOST_CPU_LOAD_INFO)` tick deltas, all cores combined | 2 s |
| Memory | app + wired + compressed pages, the same formula as Activity Monitor's "Memory Used" | 2 s |
| GPU | `IOAccelerator` "Device Utilization %", which includes drawing the screen | 2 s |
| Temperature | SMC CPU-die average `TCMb` (hottest point `TCMz`), or the average of the `Tp*`/`Te*` keys; GPU is the average of the `Tg*` keys | 10 s |

System metrics are sampled only while the dock is visible and at least one metric is turned on.

The CPU and Memory cards also list the **top 5 processes**, scanned every 2 s only while that card is open:

- CPU: from `ps`, so system processes such as WindowServer are included. Percent of one core, like Activity Monitor.
- Memory: physical footprint (Activity Monitor's "Memory" column) from `proc_pid_rusage`. Only your own processes can be read without root, so the list is labeled "yours". This is where a local model server shows up: its footprint includes the model held in GPU memory, which `ps` does not show.

## Privacy and safety

- TokenBar never refreshes, rotates or writes any credential. If the Claude token has expired, it asks you to run Claude Code, which refreshes it. Refreshing it from a second app could sign Claude Code out.
- Tokens are sent only to their own provider. Nothing else leaves the Mac: no telemetry, no update check.
- The Claude Keychain item is read through `/usr/bin/security`. The first read may show a Keychain prompt; choose Always Allow.

## Requirements

- macOS 14 or later. Tested on an M3 Pro running macOS 26.
- Swift 6 toolchain (Xcode 16 or later) to build.
- Temperature needs Apple Silicon. Intel Macs show no temperature.

## Build and run

```sh
./scripts/install.sh            # build, copy to /Applications (or ~/Applications), launch
```

For development:

```sh
swift test                      # 25 unit tests: parsers, store, system math, SMC decoding, processes
LIVE=1 swift test --filter live # print what each provider and the sampler return on this machine
./scripts/bundle.sh             # builds build/TokenBar.app (release, ad-hoc signed)
open build/TokenBar.app
```

Install with `install.sh` before relying on Open at login. The login item points at the app's location, and `bundle.sh` deletes and recreates `build/TokenBar.app` on every build.

## Project layout

```
Package.swift
Sources/
  TokenBarCore/        no UI; everything here is unit-tested
    Models.swift       ProviderID, LimitWindow, LimitsReading, ProviderError
    Parsers.swift      response parsers for the four tools
    Providers.swift    credential reads and fetches per tool
    Store.swift        LimitsStore: polling, intervals, enabled tools
    System.swift       SystemSampler (CPU, memory, GPU, temperature), SystemStore
    Processes.swift    top processes by CPU (ps) and memory (footprint)
    SMC.swift          AppleSMC reader and die-temperature selection
  TokenBar/            the app
    TokenBarApp.swift  menu bar extra, popover, Customize section
    MenuBarLabel.swift menu bar logo and number for the chosen mode
    DockController.swift  floating panel, drag and snap, hover tracking, hover card
    DockView.swift     rail, rings, hover cards
    DockSettings.swift persisted settings, sizes, used/remaining
    LoginItem.swift    open at login (SMAppService)
Tests/TokenBarCoreTests/   tests and sanitized response fixtures
Resources/Icons/       tool logos (see NOTICE.md)
scripts/bundle.sh      release build to .app
scripts/install.sh     bundle, copy to Applications, launch
docs/DESIGN.md         design and decisions
```

## Limitations

- The Claude and Copilot usage endpoints are undocumented and may change without notice.
- Temperature relies on undocumented SMC keys that differ between chips. On chips without `TCMb`, the per-core average may include keys that are not core temperatures.
- Antigravity limits appear only while the Antigravity IDE is running. Gemini CLI quotas are not supported.
- Hover cards depend on mouse tracking that was verified in code, but not with a real pointer on every macOS version.

## License

MIT, see [LICENSE](LICENSE). The tool logos are not covered by it; see Credits.

## Credits

Tool logos come from [Lobe Icons](https://github.com/lobehub/lobe-icons) (MIT) via Token Monitor (MIT). They are trademarks of their owners. See `Resources/Icons/NOTICE.md`.
