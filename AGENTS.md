# Repository Guidelines

## Project Structure & Module Organization
- `Input Source Pro.xcodeproj` is the Xcode project; open it to build and run.
- `Input Source Pro/` holds the app source code.
  - `Controllers/`, `Models/`, `Persistence/`, `System/`, `UI/`, `Utilities/`, `Window/` group the core logic and UI.
  - `Resources/` contains `Info.plist`, `Signing.entitlements`, localized strings (`*.lproj`), and assets in `Resources/Assets.xcassets`.
  - `Preview Content/` includes SwiftUI preview assets.
- `imgs/` is used for README media.

## Build, Test, and Development Commands
- Open `Input Source Pro.xcodeproj` in Xcode and use:
  - `Cmd+B` to build, `Cmd+R` to run, `Cmd+U` to run tests.
- CLI builds use the shared scheme name:
  - `xcodebuild -scheme "Input Source Pro" -configuration Debug build`
  - `xcodebuild -scheme "Input Source Pro" -configuration Debug test`

## Coding Style & Naming Conventions
- Swift-only codebase; follow Swift API Design Guidelines and existing conventions.
- Indentation is 4 spaces; keep declarations and SwiftUI views formatted like nearby files.
- Naming:
  - Types use `UpperCamelCase` (e.g., `IndicatorWindowController`).
  - Files follow type names, and extensions use `Type+Feature.swift` (e.g., `IndicatorWindowController+Activation.swift`).
- No repo-wide formatter or linter config is present; do not introduce reformatting-only diffs.

## Testing Guidelines
- The Xcode scheme includes a `Tests` target; add new tests there as `*Tests.swift` using XCTest.
- If you add tests, ensure they run via `Cmd+U` or `xcodebuild test` before opening a PR.

## Commit & Pull Request Guidelines
- Commit messages follow conventional commits with optional scopes, e.g., `feat(UI): add indicator toggle` or `fix: handle nil input source`.
- Branch names are descriptive and prefixed (e.g., `feature/add-xyz-support`, `fix/indicator-crash`).
- PRs should include: purpose, linked issues (e.g., `Closes #123`), summary of changes, and testing notes. Add screenshots or screen recordings for UI changes.
