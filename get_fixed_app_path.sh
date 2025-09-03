#!/bin/bash

# Script to show the fixed app path for permissions configuration
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXED_APP_PATH="${PROJECT_DIR}/DerivedData/Input_Source_Pro/Build/Products/Debug/Input Source Pro.app"

echo "🎯 Fixed Application Path for Permissions:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "${FIXED_APP_PATH}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Setup Instructions:"
echo "1. Open 'Input Source Pro.xcworkspace' (not .xcodeproj)"
echo "2. Build the project (Cmd+B)"
echo "3. Add the above path to System Settings → Privacy & Security → Accessibility"
echo "4. Add the above path to System Settings → Privacy & Security → Input Monitoring"
echo "5. Future builds will use the same path - no more re-authorization needed!"
echo ""
echo "📁 Workspace Location: ${PROJECT_DIR}/Input Source Pro.xcworkspace"

# Make the script executable
chmod +x "${BASH_SOURCE[0]}"