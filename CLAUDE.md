# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Input Source Pro is a macOS application that provides visual indicators for input source (keyboard layout) switching. It automatically switches input sources based on the active application or browser URL, significantly improving productivity for multilingual users.

## Development Environment

### Building the Project
- **Xcode**: Use the latest stable version of Xcode
- **Build**: Open `Input Source Pro.xcodeproj` in Xcode and build with Cmd+B
- **Run**: Use Cmd+R to run the project
- **Dependencies**: Swift Package Manager (SPM) handles dependencies automatically

### Key Dependencies
- **SwiftUI**: Modern UI framework
- **Combine**: Reactive programming framework
- **Core Data**: Data persistence
- **AXSwift**: Accessibility API wrapper
- **SnapKit**: Auto Layout DSL
- **Sparkle**: App update framework
- **LaunchAtLogin**: Login item management

## Architecture Overview

### Pattern: MVVM with Combine
The application follows MVVM architecture with reactive programming using Combine:

- **Models**: Data structures and Core Data entities in `/Models/` and `/Persistence/`
- **Views**: SwiftUI views in `/UI/` (Components, Screens, Utilities)
- **ViewModels**: Observable objects managing state and business logic
- **Controllers**: AppKit controllers for window management in `/Controllers/`

### Key ViewModels
- `ApplicationVM`: Active application detection and accessibility monitoring
- `PreferencesVM`: Central preferences management and Core Data integration
- `IndicatorVM`: Visual indicator display logic and triggers
- `InputSourceVM`: Input source switching and detection
- `PermissionsVM`: Accessibility permissions and system access

### Data Flow
```
System Events → ApplicationVM → IndicatorVM → UI Updates
                     ↓
              PreferencesVM ← Core Data
                     ↓
              InputSourceVM → Input Source Switching
```

## Core Components

### Input Source Management (`/Utilities/InputSource/`)
- Real-time input source monitoring
- Automatic switching based on app/browser rules
- CJKV (Chinese/Japanese/Korean/Vietnamese) layout handling

### Application Detection (`/Utilities/`)
- Enhanced mode with deep accessibility integration
- Browser-specific URL detection for rule-based switching
- Floating application support (Spotlight-like apps)

### Rule System (`/Persistence/`)
- **App Rules**: Per-application keyboard preferences
- **Browser Rules**: URL-based keyboard switching for browsers
- **Keyboard Configs**: User-defined keyboard configurations

### Indicator System (`/UI/Components/`)
- Multiple trigger types (app switch, input source change, mouse events)
- Configurable positioning (near cursor, fixed position)
- Customizable appearance (colors, sizes, display modes)

## File Structure

```
Input Source Pro/
├── Controllers/          # AppKit window controllers
├── Models/              # ViewModels and business logic
├── Persistence/         # Core Data models and storage
├── Resources/           # Assets, localizations
├── System/              # App lifecycle and menu management
├── UI/                  # SwiftUI views and components
├── Utilities/           # Helper classes and extensions
└── Window/              # Window management utilities
```

## Common Development Tasks

### Adding New Features
1. Create or modify ViewModels in `/Models/`
2. Update Core Data models in `/Persistence/` if needed
3. Add UI components in `/UI/Components/` or screens in `/UI/Screens/`
4. Update localizations in `/Resources/`

### Working with Accessibility
- Use `AXSwift` extensions in `/Utilities/Accessibility/`
- Application detection logic in `ApplicationVM`
- Browser URL detection in `QueryWebAreaService`

### Managing State
- Use `@Published` properties in ViewModels
- Leverage `CancelBag` for Combine subscription management
- Core Data reactive updates via `NSFetchedResultsController`

## Localization

The app supports multiple languages:
- English (base)
- Japanese (`ja.lproj`)
- Korean (`ko.lproj`)
- Simplified Chinese (`zh-Hans.lproj`)
- Traditional Chinese (`zh-Hant.lproj`)

Localization files are in `/Resources/` with key-value pairs in `Localizable.strings`.

## Testing and Debugging

### Accessibility Testing
- The app requires accessibility permissions for full functionality
- Test with various applications to ensure proper input source detection
- Browser testing requires specific URL patterns

### Performance Considerations
- Accessibility event monitoring can impact performance
- Use `Enhanced Mode` toggle for deeper system integration
- Monitor memory usage with floating windows

## Code Style Guidelines

- Follow Swift API Design Guidelines
- Use existing architectural patterns (MVVM + Combine)
- Maintain clear separation of concerns
- Document accessibility-related code thoroughly
- Use descriptive variable names for UI state