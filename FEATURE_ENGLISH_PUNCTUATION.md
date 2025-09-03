# App-Aware English Punctuation Mode

## Overview

This feature automatically replaces Chinese punctuation marks with English punctuation marks based on per-application rules, significantly improving productivity for multilingual users who frequently switch between languages while coding or writing.

## How It Works

### User Experience
1. **Set App Rules**: In preferences, enable "Force English Punctuation" for specific apps (e.g., VS Code, WeChat)
2. **Automatic Detection**: App automatically detects when you switch to a configured app
3. **Real-time Replacement**: While using a Chinese/CJKV input method:
   - Comma key (,) → English comma `,` instead of Chinese comma `，`
   - Period key (.) → English period `.` instead of Chinese period `。`
   - Semicolon key (;) → English semicolon `;` instead of Chinese semicolon `；`
   - And other punctuation marks...

### Technical Implementation

#### Core Components
- **PunctuationService**: Handles keyboard event interception and character replacement
- **AppRule Extension**: Adds `forceEnglishPunctuation` field to existing app customization system
- **PermissionsVM**: Multi-strategy permission checking for Input Monitoring access
- **InputMonitoringRequiredBadge**: UI component for permission status indication

#### Key Technologies
- **CGEvent API**: Low-level keyboard event interception and modification
- **IOHIDCheckAccess**: Reliable Input Monitoring permission detection
- **TISInputSource**: Real-time input method detection (CJKV vs ASCII)
- **Core Data**: Persistent storage of per-app punctuation preferences

## Development Setup

### Using the Fixed Development Environment
To avoid repeated permission authorization during development:

1. **Open Workspace**: Always use `Input Source Pro.xcworkspace` (not .xcodeproj)
2. **Fixed App Path**: App builds to consistent location:
   ```
   /path/to/project/DerivedData/Input_Source_Pro/Build/Products/Debug/Input Source Pro.app
   ```
3. **One-time Permission Setup**: Add this path to:
   - System Settings → Privacy & Security → Accessibility
   - System Settings → Privacy & Security → Input Monitoring
4. **Helper Script**: Run `./get_fixed_app_path.sh` to see the exact path

### Required Permissions
- **Input Monitoring**: Required for keyboard event interception
- **Accessibility**: Required for CGEvent.tapCreate with modification capabilities

## Architecture Details

### Event Flow
```
Keyboard Input → CGEvent Detection → CJKV Check → App Rule Check → Character Replacement → System Output
```

### Key Code Mappings (macOS)
```swift
43: ",",    // 0x2B - Comma key
47: ".",    // 0x2F - Period key  
41: ";",    // 0x29 - Semicolon key
39: "'",    // 0x27 - Single Quote key
42: "\"",   // 0x2A - Double Quote key
```

### Critical Implementation Notes
1. **Must use `.defaultTap`**: `.listenOnly` cannot modify events, only observe them
2. **Use `.privateState`**: Avoids modifier key pollution in generated events
3. **Clear event flags**: Ensures clean character input without unwanted modifiers

## Troubleshooting

### Common Issues
1. **No character replacement**: Check Input Monitoring permissions
2. **Wrong characters**: Verify keyCode mappings in PunctuationService.swift
3. **Permission dialogs**: Use the workspace configuration for fixed paths

### Debug Logging
The service provides comprehensive logging:
```
🎯 Intercepting punctuation key: 43 (',') in CJKV input method: Pinyin - Simplified
✅ Successfully created replacement event, returning new event
```

## Future Enhancements
- Support for additional punctuation marks
- Configurable key mappings per user
- Support for other language pairs
- Integration with system input source switching

---

*This feature was implemented through collaborative development between human developers and Claude AI, demonstrating effective AI-assisted software engineering.*