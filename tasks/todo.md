- [x] Capture Splash process arguments and status; trace detection and display.
- [x] Reproduce the observed issue in a regression test and apply a focused fix.
- [x] Run tests, inspect the diff against main, and verify with the running server.

Verification: regression failed before the fix; all 41 tests pass afterward. Live probe results are recorded in /tmp/token-bar-splash-live.log. Diff against main passes whitespace checks.

- [x] Build the release app, install to ~/Applications/TokenBar.app, and relaunch with user-approved installer.

## llama.cpp support
- [x] Verify llama-server endpoints and existing integration points.
- [x] Add detection, status parsing, presentation, and regression coverage.
- [x] Run tests/build and inspect the final diff.

llama.cpp verification: all 43 tests pass; app builds; live probe discovered llama-server and read model, context, slots, and process footprint. Initial full-suite CPU-sampling failure passed in isolation and on the full rerun. Existing Splash edits preserved.

## llama.cpp alias and budget
- [x] Cover alias and MiB budget parsing with regression tests.
- [x] Carry process settings into readings and update tooltip/docs.
- [x] Run tests, build, and inspect diff against main.

Verification: all 44 tests pass; swift build succeeds; live probe reads qwen3.8-27b-local and 19,327,352,832 bytes (18 GiB) budget. Diff against main checked.

## Faster start and per-tool progress
- [x] Make readings Codable and add a ReadingCache that saves and loads them as JSON in Application Support.
- [x] Load cached readings in LimitsStore at launch and save after each refresh that got new data.
- [x] Add an isFetching flag to ProviderState, set while that tool's fetch is in flight.
- [x] Show the flag: a spinner in the popover row, a spinning arc on the dock ring, "Updating..." in the hover card.
- [x] Read local servers concurrently, keeping their order, through a testable readAll helper.
- [x] Add tests (cache round trip, cached readings at launch, isFetching during a fetch, concurrent ordered reads), run the suite and build, inspect the diff.

- [ ] Manual visual check: rings show at once on relaunch, Codex does not blink on the 30 s tick, and the Antigravity arc spins and stops. Installation and readings.json existence verified with v0.3.0.

Verification: all 48 tests pass and swift build succeeds. The "Internal Error: DecodingError" build line also appears without this change.

## oMLX monitoring and dashboard
- [x] Verify process discovery, configuration, stats fields, and authentication against oMLX.
- [x] Add oMLX detection, stats polling, credentials, and dashboard action; preserve existing changes.
- [x] Add regression coverage, run tests/build, inspect diff against main, and verify runtime where available.

Verification: all 56 tests pass, including kernel socket discovery and successful/rejected oMLX polling; swift build passes; diff against main passes whitespace checks. Live probe discovered omlx-server on port 8766, reported authentication required, and read process memory. Live full metrics require the main API key (enter via Set oMLX API Key); current server is headless (/admin returns 404), so the dashboard requires enabling its web UI. Evidence: /tmp/token-bar-omlx-tests.log, /tmp/token-bar-omlx-build.log, /tmp/token-bar-omlx-live.log. Existing unrelated edits preserved.

## Release and install
- [x] Inspect changes and release history, choose version, and update release metadata.
- [x] Run checks, commit the release changes, and publish the tagged release with app archive.
- [x] Install the released build and verify its version and running process.

Verification: 56 tests pass; release commit 23c4a29 tagged v0.3.0 and published at https://github.com/thawee/TokenBar/releases/tag/v0.3.0 with the Apple Silicon app archive. Installed ~/Applications/TokenBar.app reports 0.3.0 (build 4), passes signature verification, matches the release binary, and is running. Reading cache exists. Evidence: /tmp/token-bar-release-tests.log, /tmp/token-bar-release-build.log, /tmp/token-bar-release-install.log, /tmp/token-bar-release-state.json.
