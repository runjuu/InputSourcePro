#!/bin/bash
set -euo pipefail
source_dir="$(cd "$(dirname "$0")" && pwd)"
output_dir="${1:-/tmp/isp-zed-palette-build}"
work_dir="${DERIVED_FILE_DIR:-$output_dir}/CaretPaletteBuild"
app="$output_dir/ISP Palette Control.app"
mkdir -p "$app/Contents/MacOS" "$work_dir"
cp "$source_dir/Info.plist" "$app/Contents/Info.plist"
fingerprint=$(cat "$source_dir/main.swift" "$source_dir/CaretChannel.swift" "$source_dir/CaretPollingSchedule.swift" "$source_dir/CaretGeometryFilter.swift" "$source_dir/Info.plist" "$source_dir/GenerateMenuIcon.swift" "$source_dir/build.sh" | shasum -a 256 | cut -d ' ' -f 1)
/usr/libexec/PlistBuddy -c "Add :ISPCaretBuild string $fingerprint" "$app/Contents/Info.plist"
xcrun swift -module-cache-path "$work_dir/ModuleCache" "$source_dir/GenerateMenuIcon.swift" "$app/Contents/Resources"
helper_binaries=()
setup_binaries=()
for architecture in ${ARCHS:-$(uname -m)}; do
    target="$architecture-apple-macosx${MACOSX_DEPLOYMENT_TARGET:-12.0}"
    common=(-module-cache-path "$work_dir/ModuleCache" -swift-version 5 -target "$target" -O)
    xcrun swiftc "${common[@]}" "$source_dir/main.swift" "$source_dir/CaretChannel.swift" "$source_dir/CaretPollingSchedule.swift" "$source_dir/CaretGeometryFilter.swift" -o "$work_dir/CaretControl-$architecture" -framework Cocoa -framework Carbon -framework InputMethodKit -framework Security
    xcrun swiftc "${common[@]}" "$source_dir/Setup.swift" "$source_dir/CaretHelperFiles.swift" "$source_dir/CaretInputSource.swift" -o "$work_dir/setup-$architecture" -framework Cocoa -framework Carbon
    helper_binaries+=("$work_dir/CaretControl-$architecture")
    setup_binaries+=("$work_dir/setup-$architecture")
done
xcrun lipo -create "${helper_binaries[@]}" -output "$app/Contents/MacOS/CaretControl"
xcrun lipo -create "${setup_binaries[@]}" -output "$output_dir/setup"
identity="${EXPANDED_CODE_SIGN_IDENTITY:--}"
sign_options=(--force --sign "$identity" --options runtime)
if [[ "$identity" != "-" && "${CONFIGURATION:-Debug}" == "Release" ]]; then
    sign_options+=(--timestamp)
fi
codesign "${sign_options[@]}" "$app"
codesign "${sign_options[@]}" "$output_dir/setup"
printf '%s\n' "$app"
