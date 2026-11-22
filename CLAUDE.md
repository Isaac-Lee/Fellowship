# Fellowship

Offline Mandarin ↔ Korean interpreter iOS app. Design: `docs/design.md` (source of truth).

## Role split (must follow)
- **Main session (Opus)**: design, task breakdown, code review, build/test verification, reporting to the user. The main session does NOT write product code.
- **Implementation subagent (Sonnet)**: all code writing and edits go to an Agent with `model: "sonnet"`. Each task gets a self-contained brief: goal, files to change, done criteria, build command.
- **Verification**: after a subagent finishes, the main session reads the diff, builds with `xcodebuild`, and judges. Problems go back to a Sonnet subagent with concrete fix instructions. At the end of each major stage, spawn one `model: "opus"` review subagent that has not seen the implementation and checks code against `docs/design.md`.

## Rules
- Apple frameworks only. No external packages.
- iOS 26 minimum. SwiftUI.
- Ask the user before deviating from `docs/design.md`.
- Stage 1 (UI with mock data) must be approved by the user before stage 2 starts.
- Debug menu only in `#if DEBUG`.

## Build
```bash
xcodebuild -project Fellowship.xcodeproj -scheme Fellowship -destination 'generic/platform=iOS Simulator' build
```
"BUILD SUCCEEDED" alone is not proof: also confirm the log has `SwiftCompile` lines and the built `.app` contains the `Fellowship` executable (a target with no build phases "succeeds" while compiling nothing).
