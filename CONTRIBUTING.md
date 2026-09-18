# Contributing to Mariner

Thanks for your interest in contributing! This guide covers how to set up
your environment, where things live, and the conventions to follow.

## Prerequisites

- Xcode 26 or later
- macOS 26.0 (Tahoe) or later

## Getting Started

1. Clone the repository:

   ```
   git clone https://github.com/subpop/Mariner.git
   cd Mariner
   ```

2. Create your local signing configuration from the template:

   ```
   cp Secrets.xcconfig.example Secrets.xcconfig
   ```

   Open `Secrets.xcconfig` and fill in your values:

   - **`DEVELOPMENT_TEAM`** -- Your Apple Developer Team ID. Find it in
     Xcode under **Settings > Accounts**, or at
     <https://developer.apple.com/account>.

   `Secrets.xcconfig` is gitignored and will not be committed.

3. Open `Mariner.xcodeproj` in Xcode.
4. Xcode will automatically resolve Swift Package dependencies.
5. Select the **Mariner** scheme and build (`Cmd+B`) or run (`Cmd+R`).

## Testing

- Run the app test suite with `Cmd+U`, or from the command line:

  ```
  xcodebuild -scheme Mariner test
  ```

- [GeminiKit](https://github.com/subpop/GeminiKit) (the transport layer)
  has its own suite: run `swift test` in a GeminiKit checkout.

## Project Structure

| Directory | Description |
|---|---|
| `Mariner/App/` | App entry point, commands, Settings scene, `AppSettings` |
| `Mariner/Browser/` | `BrowserState` (fetch orchestrator), browser chrome, gemtext rendering, dialogs |
| `Mariner/Stores/` | Bookmarks, history, per-host settings (JSON persistence) |
| `Mariner/Identities/` | PKCS#12 client-identity import (Keychain-backed) |
| `Mariner/Settings/` | Settings tabs |
| `MarinerTests/` | Unit tests |
| GeminiKit | Remote Swift package -- Gemini transport, TOFU pins, gemtext parser. Transport-only; UI and persistence live here in Mariner. |

## Architecture Conventions

Mariner layers as model/service, view model, view:

- **Model/service**: GeminiKit (transport), `Stores/` (JSON persistence),
  `ClientIdentityStore` (Keychain), `AppSettings` (UserDefaults).
- **View model**: `BrowserState` (the window's view model and fetch
  orchestrator), `FindModel`, `PageState`.
- **View**: `BrowserView`, `GemtextView`, dialogs, settings -- rendering
  and callbacks only, no engine logic.

Key invariants:

- `BrowserState` is the only fetch orchestrator. It takes injectable
  `FetchFn`/`TrustFn` closures and an `AppSettings` so engine tests run
  without the network, Keychain, or UserDefaults; keep it that way.
- Do not add UI or persistence to GeminiKit -- extend its `fetch`
  overloads instead.
- Only `text/gemini` is parsed as gemtext; other `text/*` renders as
  plain text; non-text shows a download page with Save.
- Previews must work without the network. Use the stub fetcher and
  in-memory stores (`persistenceURL: nil`).

## Code Style

- **Swift 6** with strict concurrency (`SWIFT_DEFAULT_ACTOR_ISOLATION =
  MainActor`). Respect `Sendable` and actor-isolation rules.
- Use `@Observable` and `@Environment` for state management. Avoid
  `ObservableObject` / `@Published` / `@StateObject` / `@ObservedObject`.
- Prefer `Task @MainActor` over `DispatchQueue.main.async`.
- Prefer modern Foundation APIs (`URL.documentsDirectory`,
  `appending(path:)`, `FormatStyle`) over legacy equivalents
  (`FileManager` path strings, `DateFormatter` / `NumberFormatter`,
  C-style `String(format:)`).
- Follow standard SwiftUI conventions: `foregroundStyle()` over
  `foregroundColor()`, `NavigationStack` + `navigationDestination(for:)`,
  no hard-coded font sizes or padding unless needed. New views go in
  their own `View` structs, not computed properties.
- Check UI changes against the [Apple Human Interface
  Guidelines](https://developer.apple.com/design/human-interface-guidelines/).
  Mariner should feel like a first-class macOS app.
- Keep changes surgical: touch only what the task requires, match
  existing style, and remove only the dead code your own changes create.

## Submitting Changes

1. Fork the repository and create a branch for your work.
2. Keep commits focused and atomic. Use imperative mood, sentence-case
   messages (e.g. "Add thread support to timeline view").
3. Make sure the project builds and tests pass before opening a pull
   request.
4. Open a pull request against the main repository with a summary of
   what changed.

Never push directly to the main repository -- all changes go through
reviewed pull requests.
