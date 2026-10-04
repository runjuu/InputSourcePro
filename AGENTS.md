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

## Release Changelog Review
- Before creating or updating release notes or publishing a release, send a draft changelog message in chat for the user to review. Wait for approval of the wording before saving it to release-note files, updating the website changelog, or publishing. Approval already given in the conversation counts; incorporate requested revisions and show the revised draft when approval is still pending.
- Draft from changes since the preceding published stable release. Describe user-facing changes, verify contributor GitHub usernames, and credit each change with relevant pull request links, following the 2.12.0 release style.
- After approval, save the changelog as `docs/release-notes/<version>.md` (for example, `2.13.0.md`, without a `v` prefix) and include it in the commit to be tagged. The release script uses it for GitHub and Sparkle notes. See `docs/releases.md` for the release workflow.
- For a stable release, create the version tag locally and push `main` and that tag together with `git push --atomic origin main refs/tags/<version>`. Do not push `main` first: the beta check must see the stable tag to skip the duplicate build.
