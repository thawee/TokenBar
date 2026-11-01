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
