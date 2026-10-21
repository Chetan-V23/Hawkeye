#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
cd "$task_root"
case "${1:-}" in
    "")
        task_configuration=release
        task_bundle_name="Hawkeye 2"
        task_bundle_id=com.hawkeye2.mac
        ;;
    --development)
        task_configuration=debug
        task_bundle_name="Hawkeye 2 Dev"
        task_bundle_id=com.hawkeye2.mac.development
        ;;
    *) print -u2 "Usage: $0 [--development]"; exit 1 ;;
esac
source "$task_root/scripts/signing.zsh"
task_signing_identity="$(hawkeye_signing_identity "$task_root")"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$task_root/.build/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$task_root/.build/swift-module-cache}"
task_build_options=(--disable-sandbox --cache-path "$task_root/.build/cache" --config-path "$task_root/.build/config" --security-path "$task_root/.build/security")
swift build -c "$task_configuration" "${task_build_options[@]}"
task_bin_dir="$(swift build -c "$task_configuration" --show-bin-path "${task_build_options[@]}")"
task_bundle="$task_root/dist/$task_bundle_name.app"
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"
cp "$task_bin_dir/Hawkeye2" "$task_bundle/Contents/MacOS/Hawkeye2"
ditto "$task_bin_dir/Hawkeye2_Hawkeye2.bundle" "$task_bundle/Contents/Resources/Hawkeye2_Hawkeye2.bundle"
cat > "$task_bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleExecutable</key><string>Hawkeye2</string>
    <key>CFBundleIdentifier</key><string>com.hawkeye2.mac</string>
    <key>CFBundleName</key><string>Hawkeye 2</string>
    <key>CFBundleDisplayName</key><string>Hawkeye 2</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $task_bundle_id" "$task_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $task_bundle_name" "$task_bundle/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $task_bundle_name" "$task_bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$task_bundle/Contents/Resources/AppIcon.icns"
hawkeye_sign_app "$task_bundle" "$task_signing_identity"
task_pin_file="$(mktemp "$task_root/.signing-identity.XXXXXX")"
print -r -- "$task_signing_identity" > "$task_pin_file"
mv -f -- "$task_pin_file" "$task_root/.signing-identity"
print "Built $task_bundle"
