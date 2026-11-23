# UltraNote — notes for coding agents

Local-first macOS notes app: a native Swift shell (SwiftUI + AppKit, Swift 6, macOS 26+, arm64
only) around a web editor (TipTap) that runs in a `WKWebView`. The working plan, including the
bridge contract both halves follow, is the gitignored `docs/plan.md`.

## Commands

Run from the repo root.

- `make gen` — generate `UltraNote.xcodeproj` from `project.yml`.
- `make editor` — `pnpm install` and `pnpm build` in `Editor/`; the Vite bundle goes to `build/editor`.
- `make build` — `editor`, `gen`, then a signed Debug build into `build/DerivedData`.
- `make run` — `build`, quit the running copy, open the built app.
- `make test` — `swift test` in `Packages/UltraNoteKit`, then the editor's `vitest`.
- `make lint` — `swiftlint lint --strict`, then the editor's `tsc --noEmit`.
- `make release VERSION=x.y.z` — Developer ID signed, notarized DMG + zip in `build/release/dist`.
- `make publish VERSION=x.y.z [DRY_RUN=1]` — release, Sparkle appcast, tag and GitHub Release (owner only).
- `make sparkle-key` — print the Sparkle EdDSA public key (private key in the login keychain).
- `make clean` — remove `build/`, the generated project and the package's `.build`.

Before calling work done: `make build`, `make test` and `make lint` all pass, then a real run when
the change is user-visible.

Self-test (Debug builds only): loads the editor, round-trips a fixture note, exports every format
and writes `report.json`; exits 0 or 1.

    build/DerivedData/Build/Products/Debug/UltraNote.app/Contents/MacOS/UltraNote --self-test <dir>

In Debug builds `ULTRANOTE_NOTES_DIR=<folder>` uses that notes folder instead of
`~/Documents/UltraNote` (use it for every scratch run), and the app listens for the
`dev.christiancuri.ultranote.debug` distributed notification (see `UltraNote/App/DebugAutomation.swift`)
to create, type, select, trash and dump its state from a script.

In Debug builds `ULTRANOTE_EDITOR_DIR=<folder>` serves the editor from that folder instead of the
app bundle (for example `build/editor` right after `make editor`, without rebuilding the app).

## Layout

- `project.yml` — XcodeGen spec, the single source of truth for targets, build settings,
  Info.plist keys and entitlements. It bundles `build/editor/` as `Contents/Resources/editor/`.
- `UltraNote/` — the app target. Thin: `App/` (app, delegate, model), `MainWindow/` (the window
  hosting the editor), `SelfTest/` (Debug only). `Info.plist` and `UltraNote.entitlements` in it
  are written by `make gen` from `project.yml`.
- `Packages/UltraNoteKit/` — local Swift package holding all logic and all tests.
  - `Sources/EditorBridge/` — the bridge contract without WebKit: message envelope and codec,
    Swift → JS calls, `app://editor/…` URL resolution and MIME types, navigation policy.
  - `Sources/EditorHost/` — `EditorWebView`, the `app` scheme handler and `EditorController`
    (async Swift API over the contract).
  - `Sources/ExportKit/` — `ExportRenderer` (hidden window + export-mode web view): paginated
    PDF, continuous PDF, PNG, TXT, Markdown.
  - `Sources/NotesCore/` — notes on disk, no WebKit: `NoteStore` (actor over the notes folder,
    conflict copies), title and file name derivation, search, `FolderWatcher` (FSEvents).
  - `Tests/<Module>Tests/` — their tests. `Tests/EditorTestSupport/` is a stand-in editor
    bundle that follows the contract, so the web view suites need no editor build. They need a
    window server; `ULTRANOTE_SKIP_WEBVIEW_TESTS=1` skips them.
- `Editor/` — the web bundle (Vite + TypeScript + React + TipTap), built into `build/editor`.

## Rules

- Edit `project.yml`, never the generated project (nor the generated `Info.plist` and
  entitlements file). Run `make gen` after adding, moving or removing files.
- The bridge contract ("Contract details" in `docs/plan.md`) is shared by Swift and TypeScript:
  change both sides together, never one alone.
- Swift 6 language mode with complete strict concurrency. A closure or callback that runs off
  the main thread must not be main-actor isolated (it traps at runtime): the print operation's
  `didRun` callback is one.
- WebKit: use the async delegate variants, read files off the main actor, register script
  message handlers through a weak proxy, and stay on public API.
- Decode enums leniently where a bad value should not drop the whole message or document.
- Files stay at or under 600 lines. Split a growing type as `Type+Feature.swift`.
- Tests are Swift Testing only (`import Testing`, no XCTest) and live in the package. Logic
  that needs a test belongs in the package, not in the app target. Tests never use the network.
- Code, comments, docs and commit messages are in English.
- Never print or commit secrets or signing identifiers (team ids, certificate names or
  hashes, keys). The team id lives only in the gitignored `.team-id` or in `$TEAM_ID`.
- No commits unless the owner asks.
